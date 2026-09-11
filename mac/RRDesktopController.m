/*
 * rdp-retina – Desktop-Modus (Stufe 1)
 *
 * Ein Fenster, dessen Inhalt in Punkten genau Sitzungspixel / backingScaleFactor groß ist.
 * P3: Mit /dynamic-resolution bestimmt das Fenster die Sitzung (Größenmeldung an den
 * Server), ohne ist das Fenster auf die Sitzungsgröße festgelegt. Umgerechnet wird nie.
 *
 * W3: /f /multimon verteilt die Sitzung auf alle Bildschirme – je Bildschirm ein randloses
 * Fenster, das seinen Ausschnitt des gemeinsamen Desktoppuffers zeigt. Der Puffer beginnt
 * an der linken oberen Ecke aller Bildschirme (gemessen, siehe README).
 */
#import "RRDesktopController.h"
#import "RRKeyboard.h"
#import "RRMetalView.h"
#import "RRRenderer.h"
#import "RRSession.h"

#include <freerdp/settings.h>

const NSWindowStyleMask RRDesktopWindowStyle = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable |
                                               NSWindowStyleMaskResizable;

@interface RRDesktopWindow : NSWindow
@end

@implementation RRDesktopWindow

- (BOOL)canBecomeKeyWindow
{
	return YES;
}

- (BOOL)canBecomeMainWindow
{
	return YES;
}

/* Größer als die nutzbare Fläche darf sein: lieber abschneiden als skalieren. */
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen
{
	return frameRect;
}

@end

@interface RRDesktopController () <NSWindowDelegate, RRMetalViewInput>
/* Einmal vor dem Verbinden gesetzt, danach nur gelesen (auch aus dem RDP-Thread) */
@property (atomic, copy) NSArray<RRMetalView *> *views;
@property (atomic, copy) NSArray<RRDesktopWindow *> *windows;
@end

@implementation RRDesktopController
{
	__weak RRSession *_session;
	RRDesktopWindow *_window; /* Hauptfenster (primärer Bildschirm) */
	RRMetalView *_view;
	NSTimer *_resizeTimer;
	BOOL _fullscreen;
	BOOL _dynamic;
}

- (instancetype)initWithSession:(RRSession *)session
{
	self = [super init];
	if (self)
	{
		_session = session;
		_views = @[];
		_windows = @[];
	}
	return self;
}

- (NSString *)windowTitle
{
	rdpSettings *settings = rr_settings(_session.rr);
	const char *title = freerdp_settings_get_string(settings, FreeRDP_WindowTitle);
	if (title && *title)
		return [NSString stringWithUTF8String:title];

	const char *host = freerdp_settings_get_string(settings, FreeRDP_ServerHostname);
	return [NSString stringWithFormat:@"%s – rdp-retina", host ? host : "?"];
}

- (RRDesktopWindow *)newWindowWithContentRect:(NSRect)contentRect
                                    styleMask:(NSWindowStyleMask)style
                                       screen:(NSScreen *)screen
{
	RRDesktopWindow *window = [[RRDesktopWindow alloc] initWithContentRect:contentRect
	                                                             styleMask:style
	                                                               backing:NSBackingStoreBuffered
	                                                                 defer:NO
	                                                                screen:screen];
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.acceptsMouseMovedEvents = YES;
	window.backgroundColor = NSColor.blackColor;
	window.title = [self windowTitle];
	return window;
}

- (RRMetalView *)newViewWithSize:(NSSize)size
{
	RRSession *session = _session;
	RRMetalView *view = [[RRMetalView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)
	                                              renderer:session.renderer];
	view.input = self;
	view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	view.texture = session.desktopTexture;
	return view;
}

- (void)activate
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	[NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
}

- (void)showWithPixelSize:(NSSize)pixels fullscreen:(BOOL)fullscreen
{
	RRSession *session = _session;

	if (fullscreen && rr_multimon(session.rr))
	{
		[self showAcrossScreens];
		return;
	}

	NSScreen *screen = session.primaryScreen;
	const CGFloat scale = screen.backingScaleFactor;

	_fullscreen = fullscreen;
	_dynamic = freerdp_settings_get_bool(rr_settings(session.rr), FreeRDP_DynamicResolutionUpdate);

	const NSSize points = NSMakeSize(pixels.width / scale, pixels.height / scale);
	NSWindowStyleMask style = RRDesktopWindowStyle;
	NSRect contentRect = NSMakeRect(0, 0, points.width, points.height);

	if (fullscreen)
	{
		style = NSWindowStyleMaskBorderless;
		contentRect = screen.frame;
	}
	else if (!_dynamic)
		style &= ~NSWindowStyleMaskResizable;

	_window = [self newWindowWithContentRect:contentRect styleMask:style screen:screen];
	_view = [self newViewWithSize:contentRect.size];
	_window.contentView = _view;
	[_window makeFirstResponder:_view];
	self.windows = @[ _window ];
	self.views = @[ _view ];

	[self activate];

	if (fullscreen)
	{
		NSApp.presentationOptions =
		    NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
		[_window setFrame:screen.frame display:NO];
	}
	else
	{
		if (!_dynamic)
		{
			_window.contentMinSize = points;
			_window.contentMaxSize = points;
		}
		const NSRect visible = screen.visibleFrame;
		[_window setFrameTopLeftPoint:NSMakePoint(visible.origin.x, NSMaxY(visible))];
	}

	[_window makeKeyAndOrderFront:nil];
}

- (void)showAcrossScreens
{
	RRSession *session = _session;
	const NSRect primary = session.primaryScreen.frame;
	const CGFloat scale = session.scale;
	INT32 originX = 0;
	INT32 originY = 0;
	rr_desktop_origin(session.rr, &originX, &originY);

	_fullscreen = YES;
	_dynamic = NO;

	NSMutableArray<RRDesktopWindow *> *windows = [NSMutableArray new];
	NSMutableArray<RRMetalView *> *views = [NSMutableArray new];

	for (NSScreen *screen in NSScreen.screens)
	{
		const NSRect frame = screen.frame;
		RRDesktopWindow *window = [self newWindowWithContentRect:frame
		                                               styleMask:NSWindowStyleMaskBorderless
		                                                  screen:screen];
		RRMetalView *view = [self newViewWithSize:frame.size];

		/* Lage im virtuellen Bildschirm (primärer bei 0,0); der Puffer beginnt an der linken
		 * oberen Ecke aller Bildschirme. Eingaben verschiebt der Kern selbst. */
		const NSInteger x = lround((frame.origin.x - primary.origin.x) * scale);
		const NSInteger y = lround((NSMaxY(primary) - NSMaxY(frame)) * scale);
		view.textureOriginX = x - originX;
		view.textureOriginY = y - originY;
		view.serverOriginX = x;
		view.serverOriginY = y;

		window.contentView = view;
		[window makeFirstResponder:view];
		[window setFrame:frame display:NO];

		if (screen == session.primaryScreen)
		{
			_window = window;
			_view = view;
		}
		[windows addObject:window];
		[views addObject:view];
	}

	self.windows = windows;
	self.views = views;

	[self activate];
	NSApp.presentationOptions =
	    NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
	for (RRDesktopWindow *window in windows)
		[window orderFront:nil];
	[_window makeKeyAndOrderFront:nil];
}

- (void)desktopResized:(NSSize)pixels texture:(RRTexture *)texture
{
	for (RRMetalView *view in self.views)
		view.texture = texture;

	if (_window && !_fullscreen && !_dynamic)
	{
		const CGFloat scale = _window.backingScaleFactor;
		const NSSize points = NSMakeSize(pixels.width / scale, pixels.height / scale);
		_window.contentMinSize = points;
		_window.contentMaxSize = points;
		[_window setContentSize:points];
	}

	for (RRMetalView *view in self.views)
		[view setNeedsRender];
}

- (void)desktopUpdated
{
	for (RRMetalView *view in self.views)
		[view setNeedsRender];
}

- (void)cursorChanged
{
	NSCursor *cursor = _session.cursor;
	const NSPoint mouse = NSEvent.mouseLocation;

	for (RRDesktopWindow *window in self.windows)
	{
		[window invalidateCursorRectsForView:window.contentView];
		if (NSApp.isActive && NSPointInRect(mouse, window.frame))
			[cursor set];
	}
}

- (void)close
{
	[_resizeTimer invalidate];
	_resizeTimer = nil;
	for (RRDesktopWindow *window in self.windows)
	{
		window.delegate = nil;
		[window close];
	}
}

- (void)runSelfTest
{
	NSUInteger index = 0;
	for (RRMetalView *view in self.views)
	{
		const NSUInteger number = ++index;
		[view verifyPixelExact:^(NSString *report, BOOL exact) {
			fprintf(stderr, "rdp-retina: Selbsttest Desktop %lu %s – %s\n", (unsigned long)number,
			        exact ? "1:1" : "NICHT 1:1", report.UTF8String);
		}];
	}
}

/* ---- Größe (P3) ------------------------------------------------------------------------ */

- (void)scheduleResize
{
	[_resizeTimer invalidate];
	_resizeTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
	                                                target:self
	                                              selector:@selector(sendResize)
	                                              userInfo:nil
	                                               repeats:NO];
}

- (void)sendResize
{
	[_resizeTimer invalidate];
	_resizeTimer = nil;

	const CGFloat scale = _window.backingScaleFactor;
	const NSSize size = _view.bounds.size;
	(void)rr_request_size(_session.rr, (UINT32)lround(size.width * scale),
	                      (UINT32)lround(size.height * scale));
}

/* ---- NSWindowDelegate ------------------------------------------------------------------ */

- (void)windowWillClose:(NSNotification *)notification
{
	[NSApp terminate:nil];
}

- (void)windowDidResize:(NSNotification *)notification
{
	if (_dynamic && !_fullscreen)
		[self scheduleResize];
}

- (void)windowDidEndLiveResize:(NSNotification *)notification
{
	if (_dynamic)
		[self sendResize];
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification
{
	if (_dynamic)
		[self scheduleResize];
}

- (void)windowDidMiniaturize:(NSNotification *)notification
{
	(void)rr_suppress_output(_session.rr, YES);
}

- (void)windowDidDeminiaturize:(NSNotification *)notification
{
	(void)rr_suppress_output(_session.rr, NO);
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
	[_session.keyboard syncLockStates];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
	[_session.keyboard releaseAll];
}

/* ---- RRMetalViewInput ------------------------------------------------------------------ */

- (void)metalView:(RRMetalView *)view mouseMovedTo:(NSPoint)point
{
	(void)rr_mouse_move(_session.rr, (INT32)point.x, (INT32)point.y);
}

- (void)metalView:(RRMetalView *)view button:(NSUInteger)button down:(BOOL)down at:(NSPoint)point
{
	(void)rr_mouse_button(_session.rr, (UINT32)button, down, (INT32)point.x, (INT32)point.y);
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

- (void)metalViewDidChangeBacking:(RRMetalView *)view
{
	if (!_dynamic && (fabs(view.window.backingScaleFactor - _session.scale) > 0.01))
		fprintf(stderr, "rdp-retina: Fenster auf Bildschirm mit anderem Faktor – ohne "
		                "/dynamic-resolution wird beschnitten, nicht skaliert\n");
}

@end
