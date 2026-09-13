/*
 * rdp-retina – Brücke zwischen Kern und Cocoa
 */
#import "RRSession.h"
#import "RRClipboard.h"
#import "RRCursor.h"
#import "RRDesktopController.h"
#import "RRKeyboard.h"
#import "RRRailController.h"
#import "RRRenderer.h"
#import "RRShare.h"
#import "RRTray.h"

#include <os/lock.h>
#include <unistd.h>

#include <freerdp/error.h>
#include <freerdp/settings.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/cliprdr.h>

@implementation RRSession
{
	RRDesktopController *_desktop;
	RRRailController *_rail;
	RRTray *_tray;
	RRClipboard *_clipboard;
	NSRect _primaryFrame;
	os_unfair_lock _textureLock;
	RRTexture *_desktopTexture;
	double _scrollX;
	double _scrollY;
	BOOL _stopping;
	NSTimer *_statsTimer;
	BOOL _selfTestScheduled;
	NSString *_sharePath;
	RRShare *_share;
}

static RRSession *RRSessionFromContext(rrContext *rr)
{
	return (__bridge RRSession *)rr_user(rr);
}

/* ---- Rückrufe des Kerns (FreeRDP-Threads) --------------------------------------------- */

static BOOL rr_mac_desktop_ready(rrContext *rr, UINT32 width, UINT32 height)
{
	RRSession *session = RRSessionFromContext(rr);
	RRTexture *texture = [session replaceDesktopTextureWidth:width height:height];
	if (!texture)
		return NO;

	RRDesktopController *desktop = session->_desktop;
	dispatch_async(dispatch_get_main_queue(), ^{
		[desktop desktopResized:NSMakeSize(width, height) texture:texture];
	});
	return YES;
}

static void rr_mac_disconnected(rrContext *rr, UINT32 error)
{
	RRSession *session = RRSessionFromContext(rr);
	dispatch_async(dispatch_get_main_queue(), ^{
		[session handleDisconnect:error];
	});
}

static BOOL rr_mac_desktop_updated(rrContext *rr, const BYTE *buffer, UINT32 stride,
                                   const rrRect *rects, UINT32 count)
{
	RRSession *session = RRSessionFromContext(rr);
	RRTexture *texture = session.desktopTexture;
	if (!texture)
		return YES;

	RRRenderer *renderer = session->_renderer;
	dispatch_sync(renderer.queue, ^{
		[renderer upload:texture bytes:buffer stride:stride rects:rects count:count];
	});
	[session->_desktop desktopUpdated];
	[session->_rail desktopUpdated];

	if (session->_selfTest && session->_desktop && !session->_selfTestScheduled)
	{
		/* Einige Sekunden warten, bis der Desktop aufgebaut ist */
		session->_selfTestScheduled = YES;
		RRDesktopController *desktop = session->_desktop;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
		               dispatch_get_main_queue(), ^{
			               [desktop runSelfTest];
		               });
	}
	return YES;
}

static BOOL rr_mac_window_changed(rrContext *rr, const rrWindow *window, UINT32 fields,
                                  BOOL created)
{
	[RRSessionFromContext(rr)->_rail windowChanged:window fields:fields created:created];
	return YES;
}

static BOOL rr_mac_window_deleted(rrContext *rr, UINT32 windowId)
{
	[RRSessionFromContext(rr)->_rail windowDeleted:windowId];
	return YES;
}

static BOOL rr_mac_window_icon(rrContext *rr, UINT32 windowId, BOOL big, const BYTE *bgra,
                               UINT32 width, UINT32 height)
{
	RRSession *session = RRSessionFromContext(rr);
	NSImage *image = RRImageCreate(bgra, width, height, session->_scale);
	if (image)
	{
		RRRailController *rail = session->_rail;
		dispatch_async(dispatch_get_main_queue(), ^{
			[rail windowIcon:windowId big:big image:image];
		});
	}
	return YES;
}

static BOOL rr_mac_desktop_state(rrContext *rr, UINT32 fields, UINT32 activeWindowId,
                                 const UINT32 *zorder, UINT32 count)
{
	[RRSessionFromContext(rr)->_rail desktopStateFields:fields
	                                              active:activeWindowId
	                                              zorder:zorder
	                                               count:count];
	return YES;
}

static BOOL rr_mac_window_surface(rrContext *rr, UINT32 windowId, const BYTE *data, UINT32 stride,
                                  UINT32 width, UINT32 height, const rrRect *rects, UINT32 count,
                                  BOOL full, BOOL alpha)
{
	RRRailController *rail = RRSessionFromContext(rr)->_rail;
	if (!rail)
		return YES;
	return [rail windowSurface:windowId
	                      data:data
	                    stride:stride
	                     width:width
	                    height:height
	                     rects:rects
	                     count:count
	                      full:full
	                     alpha:alpha];
}

static BOOL rr_mac_local_move_size(rrContext *rr, UINT32 windowId, BOOL start, UINT16 type,
                                   INT32 x, INT32 y)
{
	[RRSessionFromContext(rr)->_rail localMoveSize:windowId start:start type:type x:x y:y];
	return YES;
}

static BOOL rr_mac_min_max_info(rrContext *rr, const RAIL_MINMAXINFO_ORDER *info)
{
	[RRSessionFromContext(rr)->_rail minMaxInfo:info];
	return YES;
}

static BOOL rr_mac_window_cloak(rrContext *rr, UINT32 windowId, BOOL cloaked)
{
	[RRSessionFromContext(rr)->_rail windowCloak:windowId cloaked:cloaked];
	return YES;
}

static BOOL rr_mac_notify_icon_changed(rrContext *rr, UINT32 windowId, UINT32 iconId,
                                       const char *tooltip, const BYTE *bgra, UINT32 width,
                                       UINT32 height)
{
	RRSession *session = RRSessionFromContext(rr);
	NSString *tip = tooltip ? [NSString stringWithUTF8String:tooltip] : nil;
	NSImage *image = bgra ? RRImageCreate(bgra, width, height, session->_scale) : nil;
	RRTray *tray = session->_tray;

	dispatch_async(dispatch_get_main_queue(), ^{
		[tray iconChanged:windowId iconId:iconId tooltip:tip image:image];
	});
	return YES;
}

static BOOL rr_mac_notify_icon_deleted(rrContext *rr, UINT32 windowId, UINT32 iconId)
{
	RRTray *tray = RRSessionFromContext(rr)->_tray;
	dispatch_async(dispatch_get_main_queue(), ^{
		[tray iconDeleted:windowId iconId:iconId];
	});
	return YES;
}

static void *rr_mac_pointer_new(rrContext *rr, const BYTE *bgra, UINT32 width, UINT32 height,
                                UINT32 hotX, UINT32 hotY)
{
	RRSession *session = RRSessionFromContext(rr);
	NSCursor *cursor = RRCursorCreate(bgra, width, height, hotX, hotY, session->_scale);
	return cursor ? (void *)CFBridgingRetain(cursor) : NULL;
}

static void rr_mac_pointer_free(rrContext *rr, void *handle)
{
	if (handle)
		CFBridgingRelease(handle);
}

static BOOL rr_mac_pointer_set(rrContext *rr, void *handle)
{
	RRSession *session = RRSessionFromContext(rr);
	NSCursor *cursor = handle ? (__bridge NSCursor *)handle : RRCursorHidden();
	dispatch_async(dispatch_get_main_queue(), ^{
		[session setCursor:cursor];
	});
	return YES;
}

static BOOL rr_mac_pointer_set_default(rrContext *rr)
{
	RRSession *session = RRSessionFromContext(rr);
	dispatch_async(dispatch_get_main_queue(), ^{
		[session setCursor:NSCursor.arrowCursor];
	});
	return YES;
}

static void rr_mac_channel_connected(rrContext *rr, const char *name, void *iface)
{
	RRSession *session = RRSessionFromContext(rr);

	if (strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		/* W2: Die Rückrufe müssen stehen, bevor der Server "Monitor Ready" schickt. */
		RRClipboard *clipboard = [[RRClipboard alloc] initWithCliprdr:(CliprdrClientContext *)iface];
		dispatch_async(dispatch_get_main_queue(), ^{
			session->_clipboard = clipboard;
			[clipboard start];
		});
	}
}

static void rr_mac_channel_disconnected(rrContext *rr, const char *name, void *iface)
{
	RRSession *session = RRSessionFromContext(rr);

	if (strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		[RRClipboard detachCliprdr:(CliprdrClientContext *)iface];
		dispatch_async(dispatch_get_main_queue(), ^{
			session->_clipboard = nil;
		});
	}
}

/* ---- Lebenszyklus ---------------------------------------------------------------------- */

- (instancetype)initWithArgc:(int)argc argv:(char **)argv exitCode:(int *)exitCode
{
	self = [super init];
	if (!self)
		return nil;

	_textureLock = OS_UNFAIR_LOCK_INIT;
	_cursor = NSCursor.arrowCursor;

	rrFrontend frontend = { 0 };
	frontend.Connected = rr_mac_desktop_ready;
	frontend.Disconnected = rr_mac_disconnected;
	frontend.DesktopResized = rr_mac_desktop_ready;
	frontend.DesktopUpdated = rr_mac_desktop_updated;
	frontend.WindowChanged = rr_mac_window_changed;
	frontend.WindowDeleted = rr_mac_window_deleted;
	frontend.WindowIcon = rr_mac_window_icon;
	frontend.DesktopState = rr_mac_desktop_state;
	frontend.WindowSurface = rr_mac_window_surface;
	frontend.LocalMoveSize = rr_mac_local_move_size;
	frontend.MinMaxInfo = rr_mac_min_max_info;
	frontend.WindowCloak = rr_mac_window_cloak;
	frontend.NotifyIconChanged = rr_mac_notify_icon_changed;
	frontend.NotifyIconDeleted = rr_mac_notify_icon_deleted;
	frontend.PointerNew = rr_mac_pointer_new;
	frontend.PointerFree = rr_mac_pointer_free;
	frontend.PointerSet = rr_mac_pointer_set;
	frontend.PointerSetDefault = rr_mac_pointer_set_default;
	frontend.ChannelConnected = rr_mac_channel_connected;
	frontend.ChannelDisconnected = rr_mac_channel_disconnected;

	_rr = rr_new(&frontend, (__bridge void *)self, argc, argv, exitCode);
	if (!_rr)
		return nil;

	/* Mehrere RemoteApps teilen sich eine Sitzung: Läuft schon eine Instanz für diesen Server
	 * und Benutzer, übernimmt sie die Programme, und dieser Aufruf endet hier. */
	rdpSettings *settings = rr_settings(_rr);
	if (freerdp_settings_get_bool(settings, FreeRDP_RemoteApplicationMode) &&
	    !rr_option(_rr, "retina-noshare"))
	{
		_sharePath = [RRShare socketPathForSettings:settings];

		NSMutableArray<NSString *> *apps = [NSMutableArray new];
		for (size_t i = 0; i < rr_app_count(_rr); i++)
		{
			NSString *app = [NSString stringWithUTF8String:rr_app(_rr, i)];
			if (app)
				[apps addObject:app];
		}

		const RRShareResult result =
		    _sharePath ? [RRShare handOffApps:apps toPath:_sharePath] : RRShareNoInstance;
		if (result == RRShareDone)
		{
			fprintf(stderr, "rdp-retina: an die laufende Sitzung übergeben\n");
			*exitCode = 0;
			return nil;
		}
		if (result == RRShareRefused)
		{
			fprintf(stderr, "rdp-retina: die laufende Sitzung hat die Programme abgelehnt\n");
			*exitCode = 1;
			return nil;
		}
	}

	_renderer = [RRRenderer new];
	if (!_renderer)
	{
		*exitCode = 1;
		return nil;
	}

	_keyboard = [[RRKeyboard alloc] initWithContext:_rr];
	return self;
}

- (void)dealloc
{
	[_share invalidate];
	if (_rr)
		rr_free(_rr);
}

- (UINT32)collectScreens:(rrScreen *)screens
{
	NSArray<NSScreen *> *all = NSScreen.screens;
	UINT32 count = 0;

	for (NSScreen *screen in all)
	{
		if (count >= RR_MAX_SCREENS)
			break;

		const CGFloat scale = screen.backingScaleFactor;
		const NSRect frame = screen.frame;
		const NSRect visible = screen.visibleFrame;
		rrScreen *s = &screens[count++];
		memset(s, 0, sizeof(*s));

		s->frame.x = (INT32)lround((frame.origin.x - _primaryFrame.origin.x) * _scale);
		s->frame.y = (INT32)lround((NSMaxY(_primaryFrame) - NSMaxY(frame)) * _scale);
		s->frame.width = (UINT32)lround(frame.size.width * scale);
		s->frame.height = (UINT32)lround(frame.size.height * scale);
		s->workArea.x = (INT32)lround((visible.origin.x - _primaryFrame.origin.x) * _scale);
		s->workArea.y = (INT32)lround((NSMaxY(_primaryFrame) - NSMaxY(visible)) * _scale);
		s->workArea.width = (UINT32)lround(visible.size.width * scale);
		s->workArea.height = (UINT32)lround(visible.size.height * scale);
		s->scalePercent = (UINT32)lround(scale * 100.0);
		s->primary = (screen == all.firstObject);

		NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
		if (number)
		{
			const CGSize mm = CGDisplayScreenSize(number.unsignedIntValue);
			s->physicalWidthMm = (UINT32)lround(mm.width);
			s->physicalHeightMm = (UINT32)lround(mm.height);
		}
	}
	return count;
}

- (BOOL)start
{
	rdpSettings *settings = rr_settings(_rr);
	NSScreen *primary = NSScreen.screens.firstObject;
	if (!primary)
	{
		fprintf(stderr, "rdp-retina: kein Bildschirm gefunden\n");
		return NO;
	}

	_primaryScreen = primary;
	_primaryFrame = primary.frame;
	_scale = primary.backingScaleFactor;

	const char *cmd = rr_option(_rr, "retina-cmd");
	_keyboard.commandAsControl = !(cmd && (strcmp(cmd, "win") == 0));

	_verbose = rr_option(_rr, "retina-verbose") != NULL;
	_selfTest = rr_option(_rr, "retina-selftest") != NULL;
	const char *stats = rr_option(_rr, "retina-stats");
	if (stats)
	{
		const double interval = (*stats != '\0') ? MAX(atof(stats), 1.0) : 5.0;
		__weak RRSession *weakSelf = self;
		_statsTimer = [NSTimer scheduledTimerWithTimeInterval:interval
		                                              repeats:YES
		                                                block:^(NSTimer *timer) {
			                                                [weakSelf printStats];
		                                                }];
	}

	if (freerdp_settings_get_uint32(settings, FreeRDP_KeyboardLayout) == 0)
	{
		const DWORD layout = [RRKeyboard currentLayoutId];
		if (layout != 0)
			(void)freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, layout);
	}

	rrScreen screens[RR_MAX_SCREENS];
	const UINT32 count = [self collectScreens:screens];
	const BOOL remoteApp = freerdp_settings_get_bool(settings, FreeRDP_RemoteApplicationMode);
	BOOL fullscreen = freerdp_settings_get_bool(settings, FreeRDP_Fullscreen);

	/* Ohne /size: das größte Fenster, das auf die nutzbare Fläche passt. */
	UINT32 defaultWidth = 0;
	UINT32 defaultHeight = 0;
	if (!remoteApp && !fullscreen)
	{
		const NSRect content = [NSWindow contentRectForFrameRect:primary.visibleFrame
		                                               styleMask:RRDesktopWindowStyle];
		defaultWidth = (UINT32)(floor(content.size.width) * _scale);
		defaultHeight = (UINT32)(floor(content.size.height) * _scale);
	}

	if (!rr_configure(_rr, screens, count, defaultWidth, defaultHeight))
		return NO;

	const UINT32 width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
	const UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);

	if (remoteApp)
	{
		_rail = [[RRRailController alloc] initWithSession:self];
		_tray = [[RRTray alloc] initWithSession:self];

		if (_sharePath)
		{
			/* Schon vor dem Verbindungsaufbau: Programme warten, bis die Sitzung steht. */
			__weak RRSession *weakSelf = self;
			_share = [[RRShare alloc] initWithPath:_sharePath
			                               handler:^BOOL(NSString *app) {
				                               return [weakSelf launchApp:app];
			                               }];
			if (!_share)
				fprintf(stderr, "rdp-retina: weitere Aufrufe können diese Sitzung nicht mitnutzen\n");
		}
	}
	else
	{
		const UINT32 screenWidth = (UINT32)lround(_primaryFrame.size.width * _scale);
		const UINT32 screenHeight = (UINT32)lround(_primaryFrame.size.height * _scale);
		if (!fullscreen && (width >= screenWidth) && (height >= screenHeight))
		{
			fprintf(stderr, "rdp-retina: %ux%u entspricht dem Bildschirm, zeige als Vollbild\n",
			        width, height);
			fullscreen = YES;
		}
		_desktop = [[RRDesktopController alloc] initWithSession:self];
		[_desktop showWithPixelSize:NSMakeSize(width, height) fullscreen:fullscreen];
	}

	return rr_start(_rr);
}

- (void)printStats
{
	rrGfxStats stats = { 0 };
	if (!rr_gfx_stats(_rr, &stats))
		return;

	NSMutableString *codecs = [NSMutableString new];
	for (UINT32 i = 0; i < 16; i++)
	{
		if (stats.codec[i] > 0)
			[codecs appendFormat:@" %s=%llu", rr_codec_name(i), (unsigned long long)stats.codec[i]];
	}
	fprintf(stderr, "rdp-retina: GFX 0x%08X/0x%08X, %llu Bilder vom Server, %llu gezeichnet;%s\n",
	        stats.capsVersion, stats.capsFlags, (unsigned long long)stats.frames,
	        (unsigned long long)_renderer.presentedFrames, codecs.UTF8String);
}

- (BOOL)launchApp:(NSString *)app
{
	if (_stopping || !rr_rail_launch(_rr, app.UTF8String))
		return NO;

	fprintf(stderr, "rdp-retina: weiteres Programm %s\n", app.UTF8String);
	if (@available(macOS 14.0, *))
		[NSApp activate];
	else
		[NSApp activateIgnoringOtherApps:YES];
	return YES;
}

- (void)stop
{
	if (_stopping)
		return;
	_stopping = YES;
	[_share invalidate];
	_share = nil;
	[_statsTimer invalidate];
	_statsTimer = nil;
	rr_stop(_rr);
}

- (void)handleDisconnect:(UINT32)error
{
	if (_stopping)
		return;

	if ((error != 0) && (error != FREERDP_ERROR_CONNECT_CANCELLED))
	{
		fprintf(stderr, "rdp-retina: Verbindung beendet: %s\n",
		        freerdp_get_last_error_string(error));
		/* Vom Server beendet (Abmelden, Anwendung geschlossen) ist kein Fehler. */
		if (GET_FREERDP_ERROR_CLASS(error) != FREERDP_ERROR_ERRINFO_CLASS)
		{
			_exitCode = 1;
			/* Ohne Terminal, z.B. aus dem Dock gestartet, sähe sonst niemand den Grund. */
			if (!isatty(STDERR_FILENO))
			{
				NSAlert *alert = [NSAlert new];
				alert.messageText = @"Verbindung beendet";
				alert.informativeText =
				    [NSString stringWithUTF8String:freerdp_get_last_error_string(error) ?: ""] ?: @"";
				[alert runModal];
			}
		}
	}

	[_share invalidate];
	_share = nil;
	[_rail closeAll];
	[_tray removeAll];
	[_desktop close];
	[NSApp terminate:nil];
}

/* ---- Desktoptextur --------------------------------------------------------------------- */

- (RRTexture *)replaceDesktopTextureWidth:(UINT32)width height:(UINT32)height
{
	RRTexture *texture = [_renderer newTextureWithWidth:width height:height];
	os_unfair_lock_lock(&_textureLock);
	_desktopTexture = texture;
	os_unfair_lock_unlock(&_textureLock);
	return texture;
}

- (RRTexture *)desktopTexture
{
	os_unfair_lock_lock(&_textureLock);
	RRTexture *texture = _desktopTexture;
	os_unfair_lock_unlock(&_textureLock);
	return texture;
}

/* ---- Zeiger ---------------------------------------------------------------------------- */

- (void)setCursor:(NSCursor *)cursor
{
	_cursor = cursor ?: NSCursor.arrowCursor;
	[_desktop cursorChanged];
	[_rail cursorChanged];
}

/* ---- Koordinaten ----------------------------------------------------------------------- */

- (NSPoint)serverPointFromScreenPoint:(NSPoint)point
{
	return NSMakePoint(floor((point.x - _primaryFrame.origin.x) * _scale),
	                   floor((NSMaxY(_primaryFrame) - point.y) * _scale));
}

- (NSRect)screenFrameForServerRect:(rrRect)rect
{
	const CGFloat width = rect.width / _scale;
	const CGFloat height = rect.height / _scale;
	const CGFloat x = _primaryFrame.origin.x + rect.x / _scale;
	const CGFloat y = NSMaxY(_primaryFrame) - rect.y / _scale - height;
	return NSMakeRect(x, y, width, height);
}

/* ---- Eingabe --------------------------------------------------------------------------- */

- (void)sendScrollWheel:(NSEvent *)event
{
	/* 120 Einheiten sind eine Rastung. Trackpad und Magic Mouse liefern Punkte. */
	const double factor = event.hasPreciseScrollingDeltas ? 2.0 : 120.0;

	_scrollY += event.scrollingDeltaY * factor;
	_scrollX -= event.scrollingDeltaX * factor;

	const INT32 vertical = (INT32)_scrollY;
	const INT32 horizontal = (INT32)_scrollX;
	if (vertical != 0)
	{
		(void)rr_mouse_wheel(_rr, NO, vertical);
		_scrollY -= vertical;
	}
	if (horizontal != 0)
	{
		(void)rr_mouse_wheel(_rr, YES, horizontal);
		_scrollX -= horizontal;
	}

	if ((event.phase == NSEventPhaseEnded) || (event.momentumPhase == NSEventPhaseEnded))
		_scrollX = _scrollY = 0;
}

- (void)appDidBecomeActive
{
	[_keyboard syncLockStates];
}

- (void)appDidResignActive
{
	[_keyboard releaseAll];
}

@end
