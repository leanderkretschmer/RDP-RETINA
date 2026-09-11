/*
 * rdp-retina – RemoteApp-Fenster (Stufen 2 bis 4)
 *
 * P5: Je entferntem Fenster ein randloses NSWindow. Rahmen, Titelleiste und Knöpfe
 * zeichnet Windows selbst; der Mac liefert Lage, Fokus, Reihenfolge und Eingabe.
 *
 *   Fokus         Fenster wird key    <->  ClientActivate / ACTIVE_WND
 *   Reihenfolge   orderWindow:...     <-   ZORDER
 *   Minimieren    miniaturize         <->  SC_MINIMIZE, SC_RESTORE / showState
 *   Verschieben   lokal nachgeführt   <->  LocalMoveSize; am Ende WindowMove + Taste los
 */
#import "RRRailController.h"
#import "RRKeyboard.h"
#import "RRMetalView.h"
#import "RRRenderer.h"
#import "RRSession.h"

#include <os/lock.h>

#include <freerdp/rail.h>
#include <freerdp/window.h>

/* ---- Fenster --------------------------------------------------------------------------- */

@interface RRRailWindow : NSWindow
@property (nonatomic) UINT32 windowId;
@property (nonatomic) BOOL activatable;
@end

@implementation RRRailWindow

- (BOOL)canBecomeKeyWindow
{
	return self.activatable;
}

- (BOOL)canBecomeMainWindow
{
	return self.activatable;
}

/* Windows darf Fenster auch teilweise außerhalb des Bildschirms ablegen. */
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen
{
	return frameRect;
}

@end

/* Zustand eines entfernten Fensters, nur im Hauptthread */
@interface RRRailEntry : NSObject
@property (nonatomic) UINT32 windowId;
@property (nonatomic) UINT32 ownerId;
@property (nonatomic) UINT32 style;
@property (nonatomic) UINT32 exStyle;
@property (nonatomic) UINT32 showState;
@property (nonatomic) rrRect rect;
@property (nonatomic) UINT32 marginLeft;
@property (nonatomic) UINT32 marginTop;
@property (nonatomic) UINT32 marginRight;
@property (nonatomic) UINT32 marginBottom;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL cloaked;
@property (nonatomic) BOOL hasMinMax;
@property (nonatomic) RAIL_MINMAXINFO_ORDER minMax;
@property (nonatomic) BOOL serverMinimizing;
@property (nonatomic, strong, nullable) RRRailWindow *window;
@property (nonatomic, strong, nullable) RRMetalView *view;
@end

@implementation RRRailEntry
@end

/* Eigene GFX-Fläche eines Fensters; RDP-Thread und Hauptthread */
@interface RRRailSurface : NSObject
@property (atomic, strong, nullable) RRTexture *texture;
@property (atomic, weak, nullable) RRMetalView *view;
@property (atomic) BOOL alpha;
@end

@implementation RRRailSurface
@end

typedef struct
{
	BOOL active;
	UINT32 windowId;
	UINT16 type;
	INT32 x;
	INT32 y;
	rrRect start;
} RRLocalMove;

@interface RRRailController () <NSWindowDelegate, RRMetalViewInput>
@end

@implementation RRRailController
{
	__weak RRSession *_session;
	rrContext *_rr;
	NSMutableDictionary<NSNumber *, RRRailEntry *> *_entries;
	NSArray<NSNumber *> *_zorder;
	UINT32 _activeWindowId;
	UINT32 _activationEcho;
	BOOL _activatedOnce;
	BOOL _iconSet;
	RRLocalMove _move;
	os_unfair_lock _surfaceLock;
	NSMutableDictionary<NSNumber *, RRRailSurface *> *_surfaces;
	NSMutableSet<NSNumber *> *_verified;
}

- (instancetype)initWithSession:(RRSession *)session
{
	self = [super init];
	if (self)
	{
		_session = session;
		_rr = session.rr;
		_entries = [NSMutableDictionary new];
		_surfaces = [NSMutableDictionary new];
		_surfaceLock = OS_UNFAIR_LOCK_INIT;
		_verified = [NSMutableSet new];
	}
	return self;
}

- (RRRailSurface *)surfaceFor:(UINT32)windowId create:(BOOL)create
{
	os_unfair_lock_lock(&_surfaceLock);
	RRRailSurface *surface = _surfaces[@(windowId)];
	if (!surface && create)
	{
		surface = [RRRailSurface new];
		_surfaces[@(windowId)] = surface;
	}
	os_unfair_lock_unlock(&_surfaceLock);
	return surface;
}

/* ---- Fensterzustand -------------------------------------------------------------------- */

- (void)windowChanged:(const rrWindow *)window fields:(UINT32)fields created:(BOOL)created
{
	RRRailEntry *snapshot = [RRRailEntry new];
	snapshot.windowId = window->id;
	snapshot.ownerId = window->ownerId;
	snapshot.style = window->style;
	snapshot.exStyle = window->exStyle;
	snapshot.showState = window->showState;
	snapshot.rect = window->rect;
	snapshot.marginLeft = window->marginLeft;
	snapshot.marginTop = window->marginTop;
	snapshot.marginRight = window->marginRight;
	snapshot.marginBottom = window->marginBottom;
	snapshot.title = [NSString stringWithUTF8String:window->title] ?: @"";

	dispatch_async(dispatch_get_main_queue(), ^{
		[self applySnapshot:snapshot];
	});
}

- (void)applySnapshot:(RRRailEntry *)snapshot
{
	RRRailEntry *entry = _entries[@(snapshot.windowId)];

	if (!entry)
	{
		entry = snapshot;
		_entries[@(snapshot.windowId)] = entry;
	}
	else
	{
		const BOOL moving = _move.active && (_move.windowId == entry.windowId);

		entry.ownerId = snapshot.ownerId;
		entry.style = snapshot.style;
		entry.exStyle = snapshot.exStyle;
		entry.showState = snapshot.showState;
		entry.marginLeft = snapshot.marginLeft;
		entry.marginTop = snapshot.marginTop;
		entry.marginRight = snapshot.marginRight;
		entry.marginBottom = snapshot.marginBottom;
		entry.title = snapshot.title;

		/* Minimierte Fenster parkt Windows bei -32000; die letzte echte Lage behalten. */
		if (!moving && (snapshot.showState != WINDOW_SHOW_MINIMIZED))
			entry.rect = snapshot.rect;
	}

	[self updateEntry:entry];
}

- (BOOL)isShown:(RRRailEntry *)entry
{
	return (entry.rect.width > 0) && (entry.rect.height > 0) &&
	       (entry.showState != WINDOW_HIDE) && (entry.showState != WINDOW_SHOW_MINIMIZED) &&
	       !entry.cloaked;
}

- (void)updateEntry:(RRRailEntry *)entry
{
	const BOOL minimized = entry.showState == WINDOW_SHOW_MINIMIZED;
	const BOOL shown = [self isShown:entry];

	if (!entry.window)
	{
		if (!shown)
			return;
		[self createWindowForEntry:entry];
	}

	RRRailWindow *window = entry.window;
	[self applyStyle:entry];
	if (![window.title isEqualToString:entry.title])
		window.title = entry.title;

	const BOOL moving = _move.active && (_move.windowId == entry.windowId);
	if (!moving && !minimized)
		[self applyFrame:entry];

	if (minimized)
	{
		if (window.isVisible && !window.isMiniaturized)
		{
			entry.serverMinimizing = YES;
			[window miniaturize:nil];
		}
	}
	else if (shown)
	{
		if (window.isMiniaturized)
			[window deminiaturize:nil];
		else if (!window.isVisible)
		{
			[window orderFront:nil];
			[self applyZOrder];
			[self applyActiveWindow];
		}
	}
	else if (window.isVisible || window.isMiniaturized)
		[window orderOut:nil];

	[entry.view setNeedsRender];
}

- (void)createWindowForEntry:(RRRailEntry *)entry
{
	RRSession *session = _session;
	const NSRect frame = [session screenFrameForServerRect:entry.rect];

	RRRailWindow *window = [[RRRailWindow alloc]
	    initWithContentRect:frame
	              styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskMiniaturizable)
	                backing:NSBackingStoreBuffered
	                  defer:NO];
	window.windowId = entry.windowId;
	window.releasedWhenClosed = NO;
	window.opaque = NO;
	window.backgroundColor = NSColor.clearColor;
	window.hasShadow = YES;
	window.acceptsMouseMovedEvents = YES;
	window.delegate = self;
	window.title = entry.title;

	RRMetalView *view =
	    [[RRMetalView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)
	                              renderer:session.renderer];
	view.input = self;
	view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	window.contentView = view;
	[window makeFirstResponder:view];

	entry.window = window;
	entry.view = view;

	RRRailSurface *surface = [self surfaceFor:entry.windowId create:YES];
	surface.view = view;
	[self configureSource:entry surface:surface];

	if (session.verbose)
		fprintf(stderr,
		        "rdp-retina: Fenster 0x%08X \"%s\" angelegt: Server %d,%d %ux%u -> %.1f,%.1f "
		        "%.1fx%.1f pt, Stil 0x%08X/0x%08X\n",
		        entry.windowId, entry.title.UTF8String, entry.rect.x, entry.rect.y,
		        entry.rect.width, entry.rect.height, frame.origin.x, frame.origin.y,
		        frame.size.width, frame.size.height, entry.style, entry.exStyle);
	[self scheduleSelfTest:entry];
}

- (void)scheduleSelfTest:(RRRailEntry *)entry
{
	if (!_session.selfTest || !entry.view || [_verified containsObject:@(entry.windowId)])
		return;

	[_verified addObject:@(entry.windowId)];
	const UINT32 windowId = entry.windowId;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		               RRRailEntry *current = self->_entries[@(windowId)];
		               if (!current.view || !current.window.isVisible)
			               return;
		               NSString *title = current.title;
		               [current.view verifyPixelExact:^(NSString *report, BOOL exact) {
			               fprintf(stderr, "rdp-retina: Selbsttest Fenster 0x%08X \"%s\" %s – %s\n",
			                       windowId, title.UTF8String, exact ? "1:1" : "NICHT 1:1",
			                       report.UTF8String);
		               }];
	               });
}

- (void)applyStyle:(RRRailEntry *)entry
{
	RRRailWindow *window = entry.window;
	const BOOL noActivate = (entry.exStyle & WS_EX_NOACTIVATE) != 0;
	const BOOL toolPopup = ((entry.exStyle & WS_EX_TOOLWINDOW) != 0) && ((entry.style & WS_POPUP) != 0);

	/* Menüs, Tooltips und Aufklapplisten dürfen den Fokus nicht nehmen, sonst schließt
	 * Windows sie sofort wieder. */
	window.activatable = !noActivate && !toolPopup;

	NSWindowLevel level = NSNormalWindowLevel;
	if (!window.activatable)
		level = NSPopUpMenuWindowLevel;
	else if (entry.exStyle & WS_EX_TOPMOST)
		level = NSFloatingWindowLevel;
	if (window.level != level)
		window.level = level;

	window.collectionBehavior =
	    window.activatable
	        ? (NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle)
	        : (NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle);
}

- (void)applyFrame:(RRRailEntry *)entry
{
	RRRailWindow *window = entry.window;
	if (!window)
		return;

	const NSRect frame = [_session screenFrameForServerRect:entry.rect];
	if (!NSEqualRects(window.frame, frame))
	{
		[window setFrame:frame display:NO];
		[window invalidateShadow];
	}
	[self configureSource:entry surface:[self surfaceFor:entry.windowId create:YES]];
}

/* Woher der Inhalt kommt: eigene Fläche des Fensters (HiDef) oder Ausschnitt des Desktops. */
- (void)configureSource:(RRRailEntry *)entry surface:(RRRailSurface *)surface
{
	RRMetalView *view = entry.view;
	if (!view)
		return;

	view.serverOriginX = entry.rect.x;
	view.serverOriginY = entry.rect.y;

	RRTexture *texture = surface.texture;
	if (texture)
	{
		/* Maximierte Flächen tragen die unsichtbaren Ränder mit (wie xf_rail). */
		const BOOL maximized = (entry.style & WS_MAXIMIZE) != 0;
		view.texture = texture;
		view.textureOriginX = (maximized && (texture.width > entry.rect.width)) ? entry.marginLeft : 0;
		view.textureOriginY = (maximized && (texture.height > entry.rect.height)) ? entry.marginTop : 0;
		view.alpha = surface.alpha;
	}
	else
	{
		view.texture = _session.desktopTexture;
		view.textureOriginX = entry.rect.x;
		view.textureOriginY = entry.rect.y;
		view.alpha = NO;
	}
	[view setNeedsRender];
}

- (void)closeEntry:(RRRailEntry *)entry
{
	RRRailWindow *window = entry.window;
	if (!window)
		return;

	window.delegate = nil;
	[window orderOut:nil];
	[window close];
	entry.window = nil;
	entry.view = nil;
}

- (void)windowDeleted:(UINT32)windowId
{
	/* Sofort im RDP-Thread: ein gleich danach neu angelegtes Fenster mit derselben ID
	 * darf seine Fläche nicht verlieren. */
	os_unfair_lock_lock(&_surfaceLock);
	[_surfaces removeObjectForKey:@(windowId)];
	os_unfair_lock_unlock(&_surfaceLock);

	dispatch_async(dispatch_get_main_queue(), ^{
		RRRailEntry *entry = self->_entries[@(windowId)];
		if (!entry)
			return;
		[self->_entries removeObjectForKey:@(windowId)];
		if (self->_move.active && (self->_move.windowId == windowId))
			self->_move.active = NO;
		[self closeEntry:entry];
	});
}

- (void)closeAll
{
	for (RRRailEntry *entry in _entries.allValues)
		[self closeEntry:entry];
	[_entries removeAllObjects];

	os_unfair_lock_lock(&_surfaceLock);
	[_surfaces removeAllObjects];
	os_unfair_lock_unlock(&_surfaceLock);
}

/* ---- Fokus und Reihenfolge ------------------------------------------------------------- */

- (void)desktopStateFields:(UINT32)fields
                    active:(UINT32)activeWindowId
                    zorder:(const UINT32 *)zorder
                     count:(UINT32)count
{
	NSMutableArray<NSNumber *> *order = nil;
	if ((fields & WINDOW_ORDER_FIELD_DESKTOP_ZORDER) && zorder)
	{
		order = [NSMutableArray arrayWithCapacity:count];
		for (UINT32 i = 0; i < count; i++)
			[order addObject:@(zorder[i])];
	}

	dispatch_async(dispatch_get_main_queue(), ^{
		if (order)
		{
			self->_zorder = order;
			[self applyZOrder];
		}
		if (fields & WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND)
		{
			self->_activeWindowId = activeWindowId;
			[self applyActiveWindow];
		}
	});
}

- (void)applyZOrder
{
	NSMutableArray<RRRailWindow *> *wanted = [NSMutableArray new]; /* oben zuerst */
	for (NSNumber *windowId in _zorder)
	{
		RRRailWindow *window = _entries[windowId].window;
		if (window && window.isVisible && !window.isMiniaturized)
			[wanted addObject:window];
	}
	if (wanted.count < 2)
		return;

	NSMutableArray<RRRailWindow *> *current = [NSMutableArray new];
	for (NSWindow *window in NSApp.orderedWindows)
	{
		if ([wanted containsObject:(RRRailWindow *)window])
			[current addObject:(RRRailWindow *)window];
	}
	if ([current isEqualToArray:wanted])
		return;

	if (_session.verbose)
		fprintf(stderr, "rdp-retina: Reihenfolge angepasst (%lu Fenster)\n",
		        (unsigned long)wanted.count);
	for (NSInteger i = (NSInteger)wanted.count - 2; i >= 0; i--)
		[wanted[(NSUInteger)i] orderWindow:NSWindowAbove relativeTo:wanted[(NSUInteger)i + 1].windowNumber];
}

- (void)applyActiveWindow
{
	RRRailWindow *window = _entries[@(_activeWindowId)].window;
	if (!window || !window.activatable || !window.isVisible || window.isMiniaturized ||
	    window.isKeyWindow)
		return;

	if (_session.verbose)
		fprintf(stderr, "rdp-retina: Server aktiviert Fenster 0x%08X\n", _activeWindowId);

	if (NSApp.isActive)
	{
		_activationEcho = _activeWindowId;
		[window makeKeyAndOrderFront:nil];
	}
	else if (!_activatedOnce)
	{
		/* Erstes Fenster nach dem Start aus dem Terminal nach vorn holen. */
		_activatedOnce = YES;
		_activationEcho = _activeWindowId;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		[NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
		[window makeKeyAndOrderFront:nil];
	}
	else
		[window orderFront:nil];
}

/* ---- Flächen --------------------------------------------------------------------------- */

- (BOOL)windowSurface:(UINT32)windowId
                 data:(const BYTE *)data
               stride:(UINT32)stride
                width:(UINT32)width
               height:(UINT32)height
                rects:(const rrRect *)rects
                count:(UINT32)count
                 full:(BOOL)full
                alpha:(BOOL)alpha
{
	RRRenderer *renderer = _session.renderer;
	RRRailSurface *surface = [self surfaceFor:windowId create:YES];
	RRTexture *texture = surface.texture;
	BOOL fresh = NO;

	if (!texture || (texture.width != width) || (texture.height != height))
	{
		texture = [renderer newTextureWithWidth:width height:height];
		if (!texture)
			return NO;
		fresh = YES;
	}

	const rrRect all = { 0, 0, width, height };
	dispatch_sync(renderer.queue, ^{
		if (full || fresh)
			[renderer upload:texture bytes:data stride:stride rects:&all count:1];
		else
			[renderer upload:texture bytes:data stride:stride rects:rects count:count];
	});

	const BOOL alphaChanged = surface.alpha != alpha;
	surface.alpha = alpha;

	if (fresh || alphaChanged)
	{
		surface.texture = texture;
		dispatch_async(dispatch_get_main_queue(), ^{
			RRRailEntry *entry = self->_entries[@(windowId)];
			if (!entry)
				return;
			[self configureSource:entry surface:surface];
			if (self->_session.verbose)
				fprintf(stderr, "rdp-retina: Fenster 0x%08X zeigt eigene Fläche %ux%u%s\n",
				        windowId, width, height, alpha ? " mit Alpha" : "");
			[self scheduleSelfTest:entry];
		});
	}
	else
		[surface.view setNeedsRender];
	return YES;
}

- (void)desktopUpdated
{
	os_unfair_lock_lock(&_surfaceLock);
	NSArray<RRRailSurface *> *surfaces = _surfaces.allValues;
	os_unfair_lock_unlock(&_surfaceLock);

	for (RRRailSurface *surface in surfaces)
	{
		if (!surface.texture)
			[surface.view setNeedsRender];
	}
}

/* ---- Weitere Kanalnachrichten ---------------------------------------------------------- */

- (void)minMaxInfo:(const RAIL_MINMAXINFO_ORDER *)info
{
	const RAIL_MINMAXINFO_ORDER copy = *info;
	dispatch_async(dispatch_get_main_queue(), ^{
		RRRailEntry *entry = self->_entries[@(copy.windowId)];
		if (entry)
		{
			entry.minMax = copy;
			entry.hasMinMax = YES;
		}
	});
}

- (void)windowCloak:(UINT32)windowId cloaked:(BOOL)cloaked
{
	dispatch_async(dispatch_get_main_queue(), ^{
		RRRailEntry *entry = self->_entries[@(windowId)];
		if (!entry)
			return;
		entry.cloaked = cloaked;
		[self updateEntry:entry];
	});
}

- (void)windowIcon:(UINT32)windowId big:(BOOL)big image:(NSImage *)image
{
	RRRailEntry *entry = _entries[@(windowId)];
	if (!entry)
		return;

	if (big)
		entry.window.miniwindowImage = image;

	/* Das große Symbol der ersten richtigen Anwendung wird zum Dock-Symbol. */
	if (big && !_iconSet && ((entry.exStyle & WS_EX_TOOLWINDOW) == 0))
	{
		NSApp.applicationIconImage = image;
		_iconSet = YES;
	}
}

- (void)cursorChanged
{
	NSCursor *cursor = _session.cursor;
	const NSPoint mouse = NSEvent.mouseLocation;

	for (RRRailEntry *entry in _entries.allValues)
	{
		RRRailWindow *window = entry.window;
		if (!window.isVisible)
			continue;
		[window invalidateCursorRectsForView:entry.view];
		if (NSPointInRect(mouse, window.frame))
			[cursor set];
	}
}

/* ---- Lokales Verschieben und Größeändern ----------------------------------------------- */

- (void)localMoveSize:(UINT32)windowId start:(BOOL)start type:(UINT16)type x:(INT32)x y:(INT32)y
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[self handleLocalMove:windowId start:start type:type x:x y:y];
	});
}

- (void)handleLocalMove:(UINT32)windowId start:(BOOL)start type:(UINT16)type x:(INT32)x y:(INT32)y
{
	RRRailEntry *entry = _entries[@(windowId)];

	if (!start)
	{
		/* Ende vom Server (auch bei Abbruch mit Esc) */
		if (_move.active && (_move.windowId == windowId))
			_move.active = NO;
		return;
	}

	if (!entry.window)
		return;

	if ((type == RAIL_WMSZ_KEYMOVE) || (type == RAIL_WMSZ_KEYSIZE))
	{
		/* Tastaturgesteuertes Verschieben (Alt+Leertaste): sofort beenden, Lage bleibt. */
		const rrRect rect = entry.rect;
		(void)rr_rail_end_local_move(_rr, windowId, &rect, 0, 0, YES);
		return;
	}

	if (_session.verbose)
		fprintf(stderr, "rdp-retina: lokales Verschieben 0x%08X Typ %u ab %d,%d\n", windowId,
		        type, x, y);

	_move.active = YES;
	_move.windowId = windowId;
	_move.type = type;
	_move.x = x;
	_move.y = y;
	_move.start = entry.rect;

	/* Maustaste schon los, bevor die Antwort des Servers kam */
	if ((NSEvent.pressedMouseButtons & 1) == 0)
		[self finishLocalMove];
}

- (rrRect)localMoveRectForCursor:(NSPoint)cursor
{
	rrRect rect = _move.start;
	const INT32 cx = (INT32)cursor.x;
	const INT32 cy = (INT32)cursor.y;

	/* MOVE: (x, y) ist der Griffpunkt relativ zum Fenster, sonst die Startposition. */
	if (_move.type == RAIL_WMSZ_MOVE)
	{
		rect.x = cx - _move.x;
		rect.y = cy - _move.y;
		return rect;
	}

	const INT64 dx = (INT64)cx - _move.x;
	const INT64 dy = (INT64)cy - _move.y;
	const UINT16 type = _move.type;
	const BOOL left = (type == RAIL_WMSZ_LEFT) || (type == RAIL_WMSZ_TOPLEFT) ||
	                  (type == RAIL_WMSZ_BOTTOMLEFT);
	const BOOL right = (type == RAIL_WMSZ_RIGHT) || (type == RAIL_WMSZ_TOPRIGHT) ||
	                   (type == RAIL_WMSZ_BOTTOMRIGHT);
	const BOOL top =
	    (type == RAIL_WMSZ_TOP) || (type == RAIL_WMSZ_TOPLEFT) || (type == RAIL_WMSZ_TOPRIGHT);
	const BOOL bottom = (type == RAIL_WMSZ_BOTTOM) || (type == RAIL_WMSZ_BOTTOMLEFT) ||
	                    (type == RAIL_WMSZ_BOTTOMRIGHT);

	INT64 minWidth = 64;
	INT64 minHeight = 32;
	INT64 maxWidth = 32767;
	INT64 maxHeight = 32767;
	RRRailEntry *entry = _entries[@(_move.windowId)];
	if (entry.hasMinMax)
	{
		/* MINMAXINFO zählt die unsichtbaren Ränder mit. */
		const RAIL_MINMAXINFO_ORDER m = entry.minMax;
		const INT64 marginsX = (INT64)entry.marginLeft + entry.marginRight;
		const INT64 marginsY = (INT64)entry.marginTop + entry.marginBottom;
		minWidth = MAX((INT64)m.minTrackWidth - marginsX, 1);
		minHeight = MAX((INT64)m.minTrackHeight - marginsY, 1);
		if (m.maxTrackWidth > 0)
			maxWidth = MAX((INT64)m.maxTrackWidth - marginsX, minWidth);
		if (m.maxTrackHeight > 0)
			maxHeight = MAX((INT64)m.maxTrackHeight - marginsY, minHeight);
	}

	INT64 x0 = rect.x;
	INT64 y0 = rect.y;
	INT64 x1 = (INT64)rect.x + rect.width;
	INT64 y1 = (INT64)rect.y + rect.height;

	if (left)
		x0 = MIN(MAX(x0 + dx, x1 - maxWidth), x1 - minWidth);
	if (right)
		x1 = MAX(MIN(x1 + dx, x0 + maxWidth), x0 + minWidth);
	if (top)
		y0 = MIN(MAX(y0 + dy, y1 - maxHeight), y1 - minHeight);
	if (bottom)
		y1 = MAX(MIN(y1 + dy, y0 + maxHeight), y0 + minHeight);

	rect.x = (INT32)x0;
	rect.y = (INT32)y0;
	rect.width = (UINT32)(x1 - x0);
	rect.height = (UINT32)(y1 - y0);
	return rect;
}

- (void)trackLocalMove
{
	RRRailEntry *entry = _entries[@(_move.windowId)];
	if (!entry)
	{
		_move.active = NO;
		return;
	}

	const NSPoint cursor = [_session serverPointFromScreenPoint:NSEvent.mouseLocation];
	entry.rect = [self localMoveRectForCursor:cursor];
	[self applyFrame:entry];
}

- (void)finishLocalMove
{
	if (!_move.active)
		return;

	const NSPoint cursor = [_session serverPointFromScreenPoint:NSEvent.mouseLocation];
	const rrRect rect = [self localMoveRectForCursor:cursor];
	const UINT32 windowId = _move.windowId;
	_move.active = NO;

	RRRailEntry *entry = _entries[@(windowId)];
	if (entry)
	{
		entry.rect = rect;
		[self applyFrame:entry];
	}

	if (_session.verbose)
		fprintf(stderr, "rdp-retina: lokales Verschieben 0x%08X beendet: %d,%d %ux%u\n", windowId,
		        rect.x, rect.y, rect.width, rect.height);

	/* MS-RDPERP: neue Lage melden, dann die Maustaste an der Endposition loslassen. */
	(void)rr_rail_end_local_move(_rr, windowId, &rect, (INT32)cursor.x, (INT32)cursor.y, NO);
}

/* ---- RRMetalViewInput ------------------------------------------------------------------ */

- (void)metalView:(RRMetalView *)view mouseMovedTo:(NSPoint)point
{
	if (_move.active)
	{
		[self trackLocalMove];
		return;
	}
	(void)rr_mouse_move(_rr, (INT32)point.x, (INT32)point.y);
}

- (void)metalView:(RRMetalView *)view button:(NSUInteger)button down:(BOOL)down at:(NSPoint)point
{
	if (_move.active)
	{
		if ((button == 0) && !down)
			[self finishLocalMove];
		return;
	}
	(void)rr_mouse_button(_rr, (UINT32)button, down, (INT32)point.x, (INT32)point.y);
}

- (void)metalView:(RRMetalView *)view scrollWheel:(NSEvent *)event
{
	[_session sendScrollWheel:event];
}

- (void)metalView:(RRMetalView *)view keyEvent:(NSEvent *)event
{
	[_session.keyboard handleEvent:event];
}

- (NSCursor *)cursorForMetalView:(RRMetalView *)view
{
	return _session.cursor;
}

/* ---- NSWindowDelegate ------------------------------------------------------------------ */

- (void)windowDidBecomeKey:(NSNotification *)notification
{
	RRRailWindow *window = notification.object;

	if (_session.verbose)
		fprintf(stderr, "rdp-retina: Fenster 0x%08X hat den Fokus%s\n", window.windowId,
		        (_activationEcho == window.windowId) ? " (vom Server)" : ", melde es dem Server");

	if (_activationEcho == window.windowId)
		_activationEcho = 0;
	else
		(void)rr_rail_activate(_rr, window.windowId, YES);

	[_session.keyboard syncLockStates];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
	RRRailWindow *window = notification.object;

	[_session.keyboard releaseAll];
	if (_entries[@(window.windowId)])
		(void)rr_rail_activate(_rr, window.windowId, NO);
}

- (void)windowDidMiniaturize:(NSNotification *)notification
{
	RRRailWindow *window = notification.object;
	RRRailEntry *entry = _entries[@(window.windowId)];

	if (!entry)
		return;
	if (entry.serverMinimizing)
	{
		entry.serverMinimizing = NO;
		return;
	}
	(void)rr_rail_command(_rr, window.windowId, SC_MINIMIZE);
}

- (void)windowDidDeminiaturize:(NSNotification *)notification
{
	RRRailWindow *window = notification.object;
	RRRailEntry *entry = _entries[@(window.windowId)];

	if (entry && (entry.showState == WINDOW_SHOW_MINIMIZED))
		(void)rr_rail_command(_rr, window.windowId, SC_RESTORE);
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)rr_rail_command(_rr, ((RRRailWindow *)sender).windowId, SC_CLOSE);
	return NO;
}

@end
