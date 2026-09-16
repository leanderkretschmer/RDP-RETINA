/*
 * rdp-retina – Brücke zwischen Kern und Cocoa
 */
#import "RRSession.h"
#import "RRClipboard.h"
#import "RRCredentials.h"
#import "RRCursor.h"
#import "RRDesktopController.h"
#import "RRKeyboard.h"
#import "RRRailController.h"
#import "RRRenderer.h"
#import "RRShare.h"
#import "RRTray.h"

#include <CommonCrypto/CommonDigest.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <freerdp/error.h>
#include <freerdp/settings.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/cliprdr.h>

/* Ein Dialog im Hauptthread, auf den ein FreeRDP-Thread wartet */
@interface RRWaitState : NSObject
@property (atomic) BOOL cancelled;
@end

@implementation RRWaitState
@end

/* Wartet, bis block im Hauptthread gelaufen ist. Wird die Verbindung währenddessen beendet –
 * rr_stop wartet im Hauptthread auf genau diesen Thread –, gibt es auf und liefert NO. */
static BOOL RRSessionWaitForMain(rrContext *rr, void (^block)(void))
{
	RRWaitState *state = [RRWaitState new];
	dispatch_semaphore_t done = dispatch_semaphore_create(0);

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!state.cancelled)
			block();
		dispatch_semaphore_signal(done);
	});

	while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC))) != 0)
	{
		if (freerdp_shall_disconnect_context(rr_rdp(rr)))
		{
			state.cancelled = YES;
			return NO;
		}
	}
	return !state.cancelled;
}

static NSString *RRText(const char *text)
{
	return text ? ([NSString stringWithUTF8String:text] ?: @"") : @"";
}

/* Fingerabdruck zur Anzeige; bei VERIFY_CERT_FLAG_FP_IS_PEM SHA-256 über das Zertifikat. */
static NSString *RRFingerprint(const char *value, DWORD flags)
{
	NSString *text = RRText(value);
	if ((flags & VERIFY_CERT_FLAG_FP_IS_PEM) == 0)
		return text;

	NSMutableString *base64 = [NSMutableString new];
	for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
	{
		if ([line hasPrefix:@"-----END"])
			break;
		if ((line.length > 0) && ![line hasPrefix:@"-----"])
			[base64 appendString:line];
	}

	NSData *der = [[NSData alloc] initWithBase64EncodedString:base64
	                                                  options:NSDataBase64DecodingIgnoreUnknownCharacters];
	if (der.length == 0)
		return @"";

	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(der.bytes, (CC_LONG)der.length, digest);
	NSMutableString *hex = [NSMutableString new];
	for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
		[hex appendFormat:@"%@%02X", (i > 0) ? @":" : @"", digest[i]];
	return hex;
}

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
	BOOL _managed;
	/* Im Anmeldedialog eingegeben und zum Speichern angekreuzt; nur im RDP-Thread */
	NSDictionary<NSString *, NSString *> *_pendingCredentials;
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

static BOOL rr_mac_connected(rrContext *rr, UINT32 width, UINT32 height)
{
	RRSession *session = RRSessionFromContext(rr);
	if (!rr_mac_desktop_ready(rr, width, height))
		return NO;

	/* Ein im Dialog eingegebenes Kennwort erst nach erfolgreicher Anmeldung merken. */
	NSDictionary<NSString *, NSString *> *credentials = session->_pendingCredentials;
	session->_pendingCredentials = nil;
	NSString *password = credentials[@"password"];
	if (password.length > 0)
	{
		rdpSettings *settings = rr_settings(rr);
		NSString *account =
		    RRCredentialsAccountFor(RRText(freerdp_settings_get_string(settings, FreeRDP_ServerHostname)),
		                            freerdp_settings_get_uint32(settings, FreeRDP_ServerPort),
		                            credentials[@"domain"], credentials[@"user"]);
		if (account)
			(void)RRCredentialsStore(account, password, NULL);
	}

	dispatch_async(dispatch_get_main_queue(), ^{
		session->_connected = YES;
		id<RRSessionDelegate> delegate = session.delegate;
		if ([delegate respondsToSelector:@selector(sessionDidConnect:)])
			[delegate sessionDidConnect:session];
	});
	return YES;
}

static BOOL rr_mac_rail_started(rrContext *rr)
{
	RRSession *session = RRSessionFromContext(rr);
	dispatch_async(dispatch_get_main_queue(), ^{
		session->_railStarted = YES;
		id<RRSessionDelegate> delegate = session.delegate;
		if ([delegate respondsToSelector:@selector(sessionRailDidStart:)])
			[delegate sessionRailDidStart:session];
	});
	return YES;
}

static BOOL rr_mac_window_process(rrContext *rr, UINT32 windowId, const char *applicationId,
                                  const char *processName, UINT32 processId)
{
	RRSession *session = RRSessionFromContext(rr);
	/* Pfad der .exe, wenn der Server ihn schickt, sonst die App-ID */
	const char *identifier = (processName && (*processName != '\0')) ? processName : applicationId;
	[session->_rail windowProcess:windowId applicationId:RRText(identifier)];
	return YES;
}

static BOOL rr_mac_authenticate(rrContext *rr, char **username, char **password, char **domain,
                                rdp_auth_reason reason)
{
	RRSession *session = RRSessionFromContext(rr);
	if (reason == AUTH_SMARTCARD_PIN)
		return FALSE;

	NSString *user = RRText(*username);
	NSString *domainText = RRText(*domain);
	const BOOL gateway = (reason == GW_AUTH_HTTP) || (reason == GW_AUTH_RDG) || (reason == GW_AUTH_RPC);

	__block NSDictionary<NSString *, NSString *> *answer = nil;
	const BOOL done = RRSessionWaitForMain(rr, ^{
		answer = [session askCredentialsWithUser:user domain:domainText gateway:gateway];
	});
	if (!done || !answer)
		return FALSE;

	char *newUser = strdup(answer[@"user"].UTF8String ?: "");
	char *newDomain = strdup(answer[@"domain"].UTF8String ?: "");
	char *newPassword = strdup(answer[@"password"].UTF8String ?: "");
	if (!newUser || !newDomain || !newPassword)
	{
		free(newUser);
		free(newDomain);
		free(newPassword);
		return FALSE;
	}

	free(*username);
	*username = newUser;
	free(*domain);
	*domain = newDomain;
	free(*password);
	*password = newPassword;

	if (!gateway && [answer[@"remember"] isEqualToString:@"1"])
		session->_pendingCredentials = answer;
	return TRUE;
}

static DWORD rr_mac_verify_certificate(rrContext *rr, const char *host, UINT16 port,
                                       const char *commonName, const char *subject,
                                       const char *issuer, const char *fingerprint,
                                       const char *oldFingerprint, DWORD flags)
{
	RRSession *session = RRSessionFromContext(rr);
	NSString *hostText = RRText(host);
	if ((port != 0) && (port != 3389))
		hostText = [NSString stringWithFormat:@"%@:%u", hostText, (unsigned)port];
	NSString *name = RRText(commonName);
	NSString *subjectText = RRText(subject);
	NSString *issuerText = RRText(issuer);
	NSString *print = RRFingerprint(fingerprint, flags);
	const BOOL changed = (oldFingerprint != NULL) || ((flags & VERIFY_CERT_FLAG_CHANGED) != 0);
	const BOOL mismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0;

	__block DWORD answer = 0;
	const BOOL done = RRSessionWaitForMain(rr, ^{
		answer = [session askCertificateForHost:hostText
		                             commonName:name
		                                subject:subjectText
		                                 issuer:issuerText
		                            fingerprint:print
		                                changed:changed
		                               mismatch:mismatch];
	});
	return done ? answer : 0;
}

/* ---- Lebenszyklus ---------------------------------------------------------------------- */

- (instancetype)initWithArgc:(int)argc argv:(char **)argv exitCode:(int *)exitCode
{
	return [self initWithArgc:argc argv:argv delegate:nil exitCode:exitCode];
}

- (instancetype)initWithArguments:(NSArray<NSString *> *)arguments
                         delegate:(id<RRSessionDelegate>)delegate
                         exitCode:(int *)exitCode
{
	const int argc = (int)arguments.count;
	char **argv = calloc((size_t)argc + 1, sizeof(char *));
	if (!argv)
	{
		*exitCode = 1;
		return nil;
	}
	for (int i = 0; i < argc; i++)
		argv[i] = strdup(arguments[(NSUInteger)i].UTF8String ?: "");

	self = [self initWithArgc:argc argv:argv delegate:delegate exitCode:exitCode];

	for (int i = 0; i < argc; i++)
		free(argv[i]);
	free(argv);
	return self;
}

- (instancetype)initWithArgc:(int)argc
                        argv:(char **)argv
                    delegate:(id<RRSessionDelegate>)delegate
                    exitCode:(int *)exitCode
{
	self = [super init];
	if (!self)
		return nil;

	_delegate = delegate;
	_managed = (delegate != nil);
	_textureLock = OS_UNFAIR_LOCK_INIT;
	_cursor = NSCursor.arrowCursor;
	_serverName = @"";

	rrFrontend frontend = { 0 };
	frontend.Connected = rr_mac_connected;
	frontend.RailStarted = rr_mac_rail_started;
	frontend.WindowProcess = rr_mac_window_process;
	/* Ohne Terminal (Oberfläche, Dock, Finder) fragen Dialoge nach Kennwort und Zertifikat. */
	if (_managed || !isatty(STDIN_FILENO))
	{
		frontend.Authenticate = rr_mac_authenticate;
		frontend.VerifyCertificate = rr_mac_verify_certificate;
	}
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

	_serverName = RRText(freerdp_settings_get_string(settings, FreeRDP_ServerHostname));

	/* Fokus der App: gedrückte Tasten loslassen bzw. Feststelltaste abgleichen */
	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(applicationActivityChanged:)
	                                           name:NSApplicationDidBecomeActiveNotification
	                                         object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(applicationActivityChanged:)
	                                           name:NSApplicationDidResignActiveNotification
	                                         object:nil];
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
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

	/* Ohne /p: das Kennwort aus dem Schlüsselbund nehmen (Applets geben keines mit). */
	(void)RRCredentialsApply(settings);

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
		_rail.updatesApplicationIcon = !_managed;
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

/* Aus jedem Thread: der Kern nimmt Programme unter seiner Sperre entgegen, die App holt sich
 * danach im Hauptthread nach vorn. */
- (BOOL)launchApp:(NSString *)app
{
	if (_stopping || !rr_rail_launch(_rr, app.UTF8String))
		return NO;

	fprintf(stderr, "rdp-retina: weiteres Programm %s\n", app.UTF8String);
	dispatch_async(dispatch_get_main_queue(), ^{
		[self activateApp];
	});
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
	id<RRSessionDelegate> delegate = _delegate;

	/* Die Oberfläche erfährt auch ein gewolltes Ende; die Kommandozeile beendet sich selbst. */
	if (_stopping && !delegate)
		return;

	if (!delegate && (error != 0) && (error != FREERDP_ERROR_CONNECT_CANCELLED))
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
	[_statsTimer invalidate];
	_statsTimer = nil;
	[_rail closeAll];
	[_tray removeAll];
	[_desktop close];
	_connected = NO;
	_railStarted = NO;

	if (delegate)
	{
		[delegate session:self didEndWithError:_stopping ? 0 : error];
		return;
	}
	[NSApp terminate:nil];
}

/* ---- Oberfläche ------------------------------------------------------------------------ */

- (NSArray<RRRemoteWindow *> *)appWindows
{
	return _rail ? [_rail appWindows] : @[];
}

- (void)moveRemoteWindow:(UINT32)windowId toRect:(rrRect)rect
{
	[_rail moveWindow:windowId toRect:rect];
}

- (void)showRemoteWindow:(UINT32)windowId
{
	[_rail showWindow:windowId];
}

- (void)setRemoteWindow:(UINT32)windowId maximized:(BOOL)maximized minimized:(BOOL)minimized
{
	[_rail setWindow:windowId maximized:maximized minimized:minimized];
}

- (void)remoteWindowsDidChange
{
	id<RRSessionDelegate> delegate = _delegate;
	if ([delegate respondsToSelector:@selector(sessionWindowsDidChange:)])
		[delegate sessionWindowsDidChange:self];
}

- (void)applicationActivityChanged:(NSNotification *)notification
{
	if ([notification.name isEqualToString:NSApplicationDidBecomeActiveNotification])
		[self appDidBecomeActive];
	else
		[self appDidResignActive];
}

- (void)activateApp
{
	if (@available(macOS 14.0, *))
		[NSApp activate];
	else
		[NSApp activateIgnoringOtherApps:YES];
}

- (NSDictionary<NSString *, NSString *> *)askCredentialsWithUser:(NSString *)user
                                                          domain:(NSString *)domain
                                                         gateway:(BOOL)gateway
{
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = gateway ? [NSString stringWithFormat:@"Anmeldung am Gateway für %@", _serverName]
	                            : [NSString stringWithFormat:@"Anmeldung an %@", _serverName];
	alert.informativeText = @"Benutzer und Kennwort für die Windows-Sitzung.";
	[alert addButtonWithTitle:@"Anmelden"];
	[alert addButtonWithTitle:@"Abbrechen"];

	const CGFloat width = 280;
	NSTextField *userField = [NSTextField textFieldWithString:user];
	userField.placeholderString = @"Benutzer";
	NSTextField *domainField = [NSTextField textFieldWithString:domain];
	domainField.placeholderString = @"Domäne (optional)";
	NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, width, 22)];
	passwordField.placeholderString = @"Kennwort";
	NSButton *remember = [NSButton checkboxWithTitle:@"Im Schlüsselbund speichern" target:nil action:nil];
	remember.state = gateway ? NSControlStateValueOff : NSControlStateValueOn;
	remember.enabled = !gateway;

	NSStackView *stack = [NSStackView stackViewWithViews:@[ userField, domainField, passwordField, remember ]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment = NSLayoutAttributeLeading;
	stack.spacing = 8;
	for (NSView *field in @[ userField, domainField, passwordField ])
		[field.widthAnchor constraintEqualToConstant:width].active = YES;
	stack.frame = NSMakeRect(0, 0, width, 112);
	alert.accessoryView = stack;
	[alert layout];
	alert.window.initialFirstResponder = (user.length > 0) ? passwordField : userField;

	[self activateApp];
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return nil;

	return @{
		@"user" : userField.stringValue,
		@"domain" : domainField.stringValue,
		@"password" : passwordField.stringValue,
		@"remember" : (remember.state == NSControlStateValueOn) ? @"1" : @"",
	};
}

- (DWORD)askCertificateForHost:(NSString *)host
                    commonName:(NSString *)commonName
                       subject:(NSString *)subject
                        issuer:(NSString *)issuer
                   fingerprint:(NSString *)fingerprint
                       changed:(BOOL)changed
                      mismatch:(BOOL)mismatch
{
	NSAlert *alert = [[NSAlert alloc] init];
	alert.alertStyle = changed ? NSAlertStyleCritical : NSAlertStyleWarning;
	alert.messageText = changed ? [NSString stringWithFormat:@"Das Zertifikat von %@ hat sich geändert", host]
	                            : [NSString stringWithFormat:@"Zertifikat von %@ prüfen", host];

	NSMutableString *info = [NSMutableString new];
	if (changed)
		[info appendString:@"Das kann eine Neuinstallation des Servers sein – oder jemand gibt sich als "
		                   @"der Server aus. Verbinde nur, wenn du den neuen Fingerabdruck bestätigen "
		                   @"kannst.\n\n"];
	else
		[info appendString:@"Dieser Server ist noch unbekannt. Vergleiche den Fingerabdruck mit dem "
		                   @"Zertifikat auf dem Server, bevor du ihm vertraust.\n\n"];
	if (mismatch)
		[info appendString:@"Achtung: Das Zertifikat ist nicht auf diesen Namen ausgestellt.\n\n"];
	[info appendFormat:@"Ausgestellt für: %@\nInhaber: %@\nAussteller: %@\nFingerabdruck: %@", commonName,
	                   subject, issuer, fingerprint];
	alert.informativeText = info;

	/* Abbrechen zuerst: Eingabetaste vertraut nicht aus Versehen. */
	[alert addButtonWithTitle:@"Abbrechen"];
	[alert addButtonWithTitle:@"Vertrauen"];
	[alert addButtonWithTitle:@"Nur diesmal"];

	[self activateApp];
	switch ([alert runModal])
	{
		case NSAlertSecondButtonReturn:
			return 1;
		case NSAlertThirdButtonReturn:
			return 2;
		default:
			return 0;
	}
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
