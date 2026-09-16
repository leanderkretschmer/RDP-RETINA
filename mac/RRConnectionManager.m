/*
 * rdp-retina – Sitzungen der Oberfläche
 *
 * Ablauf einer RemoteApp:
 *   1. Sitzung zum Server anlegen, falls keine läuft (RemoteApp-Modus ohne erstes Programm).
 *   2. Warten, bis der RemoteApp-Kanal steht und die offenen Fenster ihre App-ID gemeldet haben.
 *   3. Gehört ein offenes Fenster zur RemoteApp: nach vorn holen. Sonst starten.
 *   4. Das neue Fenster bestätigt den Start. Passt es zu keiner RemoteApp (etwa der Task-Manager
 *      mit einer App-ID ohne .exe), lernt die RemoteApp dessen App-ID.
 *
 * Der Arbeitsbereich merkt sich je Fenster RemoteApp, Lage und Zustand. Beim Wiederherstellen
 * bekommen zuerst die schon offenen Fenster ihren Platz; nur für die übrigen Einträge startet ein
 * Programm, dessen Fenster beim Erscheinen platziert wird.
 */
#import "RRConnectionManager.h"
#import "RRConfig.h"
#import "RRLinkInstaller.h"
#import "RRRailController.h"
#import "RRSession.h"

#include <freerdp/error.h>

NSNotificationName const RRConnectionsDidChangeNotification = @"RRConnectionsDidChangeNotification";

/* So lange nach einem Start gilt ein neues Fenster als dessen Fenster */
static const NSTimeInterval RRLaunchWindow = 12.0;
/* So lange wartet ein Eintrag des Arbeitsbereichs auf sein Fenster */
static const NSTimeInterval RRPlacementTimeout = 90.0;
/* Nach dem Start des RemoteApp-Kanals auf die App-IDs der offenen Fenster warten */
static const NSTimeInterval RRSettleDelay = 2.0;
/* Ohne RemoteApp-Kanal nach dieser Zeit aufgeben */
static const NSTimeInterval RRRailTimeout = 25.0;

typedef NS_ENUM(NSInteger, RRLaunchResult) {
	RRLaunchStarted,
	RRLaunchLimit,
	RRLaunchFailed,
};

@interface RRPendingLaunch : NSObject
@property (nonatomic, copy) NSString *appId;
@property (nonatomic, strong) NSDate *startedAt;
@end

@implementation RRPendingLaunch
@end

@interface RRPendingPlacement : NSObject
@property (nonatomic, strong) RRWorkspaceItem *item;
@property (nonatomic, strong) NSDate *deadline;
@property (nonatomic) BOOL launched;
@end

@implementation RRPendingPlacement
@end

@interface RRManagedSession : NSObject
@property (nonatomic, copy) NSString *serverId;
@property (nonatomic, copy) NSString *serverName;
@property (nonatomic, strong) RRSession *session;
/* Kanal steht und die App-IDs der offenen Fenster sind da */
@property (nonatomic) BOOL ready;
/* RemoteApps, die auf ready warten */
@property (nonatomic, strong) NSMutableArray<NSString *> *queuedAppIds;
@property (nonatomic, strong) NSMutableArray<RRPendingPlacement *> *placements;
@property (nonatomic, strong) NSMutableArray<RRPendingLaunch *> *launches;
/* Fenster, deren App-ID schon ausgewertet ist bzw. die ihren Platz haben */
@property (nonatomic, strong) NSMutableSet<NSNumber *> *seenWindowIds;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *placedWindowIds;
@end

@implementation RRManagedSession

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_serverId = @"";
		_serverName = @"";
		_queuedAppIds = [NSMutableArray new];
		_placements = [NSMutableArray new];
		_launches = [NSMutableArray new];
		_seenWindowIds = [NSMutableSet new];
		_placedWindowIds = [NSMutableSet new];
	}
	return self;
}

@end

@interface RRConnectionManager () <RRSessionDelegate>
@end

@implementation RRConnectionManager
{
	NSMutableDictionary<NSString *, RRManagedSession *> *_sessions;
	BOOL _workspaceRestored;
	BOOL _shuttingDown;
}

+ (RRConnectionManager *)shared
{
	static RRConnectionManager *shared = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [[RRConnectionManager alloc] init];
	});
	return shared;
}

- (instancetype)init
{
	self = [super init];
	if (self)
		_sessions = [NSMutableDictionary new];
	return self;
}

- (void)changed
{
	[NSNotificationCenter.defaultCenter postNotificationName:RRConnectionsDidChangeNotification object:self];
}

- (void)showError:(NSString *)message detail:(nullable NSString *)detail
{
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = message;
	alert.informativeText = detail ?: @"";
	[alert addButtonWithTitle:@"OK"];

	if (@available(macOS 14.0, *))
		[NSApp activate];
	else
		[NSApp activateIgnoringOtherApps:YES];
	[alert runModal];
}

- (nullable RRManagedSession *)managedForSession:(RRSession *)session
{
	for (RRManagedSession *managed in _sessions.allValues)
	{
		if (managed.session == session)
			return managed;
	}
	return nil;
}

- (nullable RRAppConfig *)appWithId:(NSString *)identifier amongApps:(NSArray<RRAppConfig *> *)apps
{
	for (RRAppConfig *app in apps)
	{
		if ([app.identifier isEqualToString:identifier])
			return app;
	}
	return nil;
}

- (nullable RRAppConfig *)appForWindow:(RRRemoteWindow *)window amongApps:(NSArray<RRAppConfig *> *)apps
{
	if (window.applicationId.length == 0)
		return nil;
	for (RRAppConfig *app in apps)
	{
		if ([app matchesApplicationId:window.applicationId])
			return app;
	}
	return nil;
}

/* ---- Sitzungen ----------------------------------------------------------------------------- */

- (nullable RRManagedSession *)sessionForServer:(RRServerConfig *)server
{
	RRManagedSession *managed = _sessions[server.identifier];
	if (managed)
		return managed;

	if (!server.complete)
	{
		[self showError:[NSString stringWithFormat:@"„%@“ hat keine Adresse.", server.displayName]
		         detail:@"Die Adresse in den Einstellungen unter „Server“ eintragen."];
		return nil;
	}

	int exitCode = 0;
	RRSession *session = [[RRSession alloc] initWithArguments:[RRConfig.shared sessionArgumentsForServer:server]
	                                                 delegate:self
	                                                 exitCode:&exitCode];
	if (!session)
	{
		[self showError:[NSString stringWithFormat:@"Die Verbindung zu „%@“ ließ sich nicht anlegen.",
		                                           server.displayName]
		         detail:@"Die Einstellungen des Servers prüfen."];
		return nil;
	}

	managed = [[RRManagedSession alloc] init];
	managed.serverId = server.identifier;
	managed.serverName = server.displayName;
	managed.session = session;
	_sessions[server.identifier] = managed;

	if (![session start])
	{
		[_sessions removeObjectForKey:server.identifier];
		[self showError:[NSString stringWithFormat:@"Die Verbindung zu „%@“ ließ sich nicht starten.",
		                                           server.displayName]
		         detail:nil];
		return nil;
	}

	[self changed];
	return managed;
}

- (RRServerState)stateForServerId:(NSString *)identifier
{
	RRManagedSession *managed = _sessions[identifier];
	if (!managed)
		return RRServerStateDisconnected;
	return managed.session.connected ? RRServerStateConnected : RRServerStateConnecting;
}

- (NSUInteger)openAppCountForServerId:(NSString *)identifier
{
	NSUInteger count = 0;

	for (RRManagedSession *managed in _sessions.allValues)
	{
		if (identifier && ![managed.serverId isEqualToString:identifier])
			continue;

		/* Programme zählen, nicht Fenster: zwei Editor-Fenster sind eine RemoteApp. */
		NSMutableSet *programs = [NSMutableSet new];
		for (RRRemoteWindow *window in managed.session.appWindows)
		{
			if (window.applicationId.length > 0)
				[programs addObject:window.applicationId.lowercaseString];
			else
				[programs addObject:@(window.windowId)];
		}
		count += programs.count;
	}
	return count;
}

- (NSUInteger)recentLaunchCount
{
	NSUInteger count = 0;
	NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:-RRLaunchWindow];

	for (RRManagedSession *managed in _sessions.allValues)
	{
		for (RRPendingLaunch *launch in managed.launches)
		{
			if ([launch.startedAt compare:limit] == NSOrderedDescending)
				count++;
		}
	}
	return count;
}

- (void)disconnectServerId:(NSString *)identifier
{
	[_sessions[identifier].session stop];
}

- (BOOL)hasSessions
{
	return _sessions.count > 0;
}

/* ---- RemoteApps öffnen ------------------------------------------------------------------- */

- (void)openApp:(RRAppConfig *)app fromLink:(BOOL)fromLink
{
	if (_shuttingDown)
		return;

	RRAppConfig *current = [RRConfig.shared appWithId:app.identifier] ?: app;
	RRServerConfig *server = [RRConfig.shared serverWithId:current.serverId];
	if (!server)
	{
		[self showError:[NSString stringWithFormat:@"„%@“ hat keinen Server.", current.name]
		         detail:@"In den Einstellungen unter „RemoteApps“ einen Server wählen."];
		return;
	}
	if (!current.complete)
	{
		[self showError:[NSString stringWithFormat:@"„%@“ hat kein Programm.", current.name]
		         detail:@"In den Einstellungen unter „RemoteApps“ das Programm eintragen."];
		return;
	}

	/* Erste Verknüpfung nach dem Start: den ganzen Arbeitsbereich zurückholen. */
	if (fromLink && !_workspaceRestored)
	{
		RRWorkspaceConfig *workspace = RRConfig.shared.workspace;
		BOOL inWorkspace = NO;
		for (RRWorkspaceItem *item in workspace.items)
			inWorkspace = inWorkspace || [item.appId isEqualToString:current.identifier];
		if (workspace.restoreFromLink && inWorkspace)
		{
			[self restoreWorkspace];
			return;
		}
	}

	RRManagedSession *managed = [self sessionForServer:server];
	if (!managed)
		return;

	if (managed.ready)
		[self launchOrShow:current inSession:managed];
	else
		[managed.queuedAppIds addObject:current.identifier];
}

- (BOOL)handleURL:(NSURL *)url
{
	NSString *identifier = [RRLinkInstaller appIdFromURL:url];
	if (!identifier)
		return NO;

	RRAppConfig *app = [RRConfig.shared appWithId:identifier];
	if (!app)
	{
		[self showError:@"Diese Verknüpfung gehört zu einer RemoteApp, die es nicht mehr gibt."
		         detail:@"Die Verknüpfung löschen und in den Einstellungen neu installieren."];
		return YES;
	}

	[self openApp:app fromLink:YES];
	return YES;
}

- (void)launchOrShow:(RRAppConfig *)app inSession:(RRManagedSession *)managed
{
	for (RRRemoteWindow *window in managed.session.appWindows)
	{
		if ((window.applicationId.length > 0) && [app matchesApplicationId:window.applicationId])
		{
			[managed.session showRemoteWindow:window.windowId];
			return;
		}
	}

	switch ([self launch:app inSession:managed])
	{
		case RRLaunchLimit:
			[self showLimitError];
			break;
		case RRLaunchFailed:
			[self showError:[NSString stringWithFormat:@"„%@“ ließ sich nicht starten.", app.name] detail:nil];
			break;
		case RRLaunchStarted:
			break;
	}
}

- (RRLaunchResult)launch:(RRAppConfig *)app inSession:(RRManagedSession *)managed
{
	const NSInteger maxApps = RRConfig.shared.transfer.maxApps;
	if ((maxApps > 0) &&
	    ([self openAppCountForServerId:nil] + [self recentLaunchCount] >= (NSUInteger)maxApps))
		return RRLaunchLimit;

	if (![managed.session launchApp:app.launchSpec])
		return RRLaunchFailed;

	RRPendingLaunch *launch = [[RRPendingLaunch alloc] init];
	launch.appId = app.identifier;
	launch.startedAt = [NSDate date];
	[managed.launches addObject:launch];
	[self changed];
	return RRLaunchStarted;
}

- (void)showLimitError
{
	const NSInteger maxApps = RRConfig.shared.transfer.maxApps;
	[self showError:[NSString stringWithFormat:@"Es sind schon %ld RemoteApps offen.", (long)maxApps]
	         detail:@"Die Höchstzahl lässt sich in den Einstellungen unter „Übertragung“ ändern."];
}

/* ---- Fenster auswerten ----------------------------------------------------------------------- */

- (void)learnFromWindows:(RRManagedSession *)managed
{
	NSArray<RRAppConfig *> *apps = [RRConfig.shared appsForServerId:managed.serverId];
	NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:-RRLaunchWindow];

	[managed.launches filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RRPendingLaunch *launch,
	                                                                           NSDictionary *bindings) {
		              return [launch.startedAt compare:limit] == NSOrderedDescending;
	              }]];

	for (RRRemoteWindow *window in managed.session.appWindows)
	{
		NSNumber *key = @(window.windowId);
		if ((window.applicationId.length == 0) || [managed.seenWindowIds containsObject:key])
			continue;
		[managed.seenWindowIds addObject:key];

		/* Fenster eines gestarteten Programms: der Start ist erledigt. */
		RRPendingLaunch *confirmed = nil;
		for (RRPendingLaunch *launch in managed.launches)
		{
			RRAppConfig *app = [self appWithId:launch.appId amongApps:apps];
			if (app && [app matchesApplicationId:window.applicationId])
			{
				confirmed = launch;
				break;
			}
		}
		if (confirmed)
		{
			[managed.launches removeObject:confirmed];
			continue;
		}

		/* Zu keiner RemoteApp passend, aber kurz nach einem Start erschienen: Die App-ID gehört
		 * zum ältesten offenen Start (z.B. Task-Manager, Einstellungen über cmd). */
		if ([self appForWindow:window amongApps:apps] || (managed.launches.count == 0))
			continue;

		RRPendingLaunch *oldest = managed.launches.firstObject;
		[managed.launches removeObject:oldest];
		RRAppConfig *app = [RRConfig.shared appWithId:oldest.appId];
		if (!app)
			continue;
		app.knownApplicationIds = [app.knownApplicationIds arrayByAddingObject:window.applicationId];
		[RRConfig.shared saveApp:app];
	}
}

- (void)placeWindows:(RRManagedSession *)managed
{
	NSDate *now = [NSDate date];
	[managed.placements filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RRPendingPlacement *placement,
	                                                                             NSDictionary *bindings) {
		                return [placement.deadline compare:now] == NSOrderedDescending;
	                }]];
	if (managed.placements.count == 0)
		return;

	for (RRRemoteWindow *window in managed.session.appWindows)
	{
		NSNumber *key = @(window.windowId);
		if ((window.applicationId.length == 0) || [managed.placedWindowIds containsObject:key])
			continue;

		RRPendingPlacement *found = nil;
		for (RRPendingPlacement *placement in managed.placements)
		{
			RRAppConfig *app = [RRConfig.shared appWithId:placement.item.appId];
			if (app && [app matchesApplicationId:window.applicationId])
			{
				found = placement;
				break;
			}
		}
		if (!found)
			continue;

		[managed.placements removeObject:found];
		[managed.placedWindowIds addObject:key];
		[self place:window item:found.item inSession:managed];
	}
}

- (void)place:(RRRemoteWindow *)window item:(RRWorkspaceItem *)item inSession:(RRManagedSession *)managed
{
	RRSession *session = managed.session;
	const UINT32 windowId = window.windowId;
	const NSRect frame = item.serverRect;
	const rrRect rect = {
		.x = (INT32)lround(frame.origin.x),
		.y = (INT32)lround(frame.origin.y),
		.width = (UINT32)MAX(lround(frame.size.width), 1L),
		.height = (UINT32)MAX(lround(frame.size.height), 1L),
	};

	if (item.maximized)
	{
		[session setRemoteWindow:windowId maximized:YES minimized:NO];
		return;
	}

	/* Aus Maximiert oder Minimiert erst wiederherstellen, sonst setzt Windows die Lage zurück. */
	NSTimeInterval delay = 0;
	if (window.maximized || window.minimized)
	{
		[session setRemoteWindow:windowId maximized:NO minimized:NO];
		delay = 0.6;
	}

	const BOOL minimize = item.minimized;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[session moveRemoteWindow:windowId toRect:rect];
		if (minimize)
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
			               dispatch_get_main_queue(), ^{
				               [session setRemoteWindow:windowId maximized:NO minimized:YES];
			               });
	});
}

/* Nach dem Start des Kanals: Arbeitsbereich und wartende RemoteApps abarbeiten */
- (void)processSession:(RRManagedSession *)managed
{
	[self learnFromWindows:managed];
	[self placeWindows:managed];

	/* Für Einträge ohne offenes Fenster das Programm starten; das Fenster platziert
	 * placeWindows:, sobald es erscheint. */
	BOOL limitReached = NO;
	for (RRPendingPlacement *placement in [managed.placements copy])
	{
		if (placement.launched)
			continue;

		RRAppConfig *app = [RRConfig.shared appWithId:placement.item.appId];
		RRLaunchResult result = RRLaunchFailed;
		if (app && !limitReached)
			result = [self launch:app inSession:managed];

		if (result == RRLaunchStarted)
			placement.launched = YES;
		else
		{
			limitReached = limitReached || (result == RRLaunchLimit);
			[managed.placements removeObject:placement];
		}
	}
	if (limitReached)
		[self showLimitError];

	NSArray<NSString *> *queued = [managed.queuedAppIds copy];
	[managed.queuedAppIds removeAllObjects];
	for (NSString *identifier in queued)
	{
		RRAppConfig *app = [RRConfig.shared appWithId:identifier];
		if (app)
			[self launchOrShow:app inSession:managed];
	}

	[self changed];
}

/* ---- Arbeitsbereich ---------------------------------------------------------------------------- */

- (NSUInteger)saveWorkspace
{
	NSMutableArray<RRWorkspaceItem *> *items = [NSMutableArray new];

	for (RRManagedSession *managed in _sessions.allValues)
	{
		NSArray<RRAppConfig *> *apps = [RRConfig.shared appsForServerId:managed.serverId];
		for (RRRemoteWindow *window in managed.session.appWindows)
		{
			RRAppConfig *app = [self appForWindow:window amongApps:apps];
			if (!app)
				continue;

			RRWorkspaceItem *item = [[RRWorkspaceItem alloc] init];
			item.appId = app.identifier;
			item.serverRect = NSMakeRect(window.rect.x, window.rect.y, window.rect.width, window.rect.height);
			item.minimized = window.minimized;
			item.maximized = window.maximized;
			[items addObject:item];
		}
	}

	/* Nichts offen: den gespeicherten Arbeitsbereich nicht mit einem leeren überschreiben. */
	if (items.count == 0)
		return 0;

	RRWorkspaceConfig *workspace = RRConfig.shared.workspace;
	workspace.items = items;
	workspace.savedAt = [NSDate date];
	[RRConfig.shared saveWorkspace:workspace];
	return items.count;
}

- (void)restoreWorkspace
{
	_workspaceRestored = YES;

	NSMutableDictionary<NSString *, NSMutableArray<RRWorkspaceItem *> *> *byServer = [NSMutableDictionary new];
	for (RRWorkspaceItem *item in RRConfig.shared.workspace.items)
	{
		RRAppConfig *app = [RRConfig.shared appWithId:item.appId];
		if (!app || ![RRConfig.shared serverWithId:app.serverId])
			continue;

		NSMutableArray<RRWorkspaceItem *> *list = byServer[app.serverId];
		if (!list)
		{
			list = [NSMutableArray new];
			byServer[app.serverId] = list;
		}
		[list addObject:item];
	}

	for (NSString *serverId in byServer)
	{
		RRServerConfig *server = [RRConfig.shared serverWithId:serverId];
		RRManagedSession *managed = server ? [self sessionForServer:server] : nil;
		if (!managed)
			continue;

		for (RRWorkspaceItem *item in byServer[serverId])
		{
			RRPendingPlacement *placement = [[RRPendingPlacement alloc] init];
			placement.item = item;
			placement.deadline = [NSDate dateWithTimeIntervalSinceNow:RRPlacementTimeout];
			[managed.placements addObject:placement];
		}
		if (managed.ready)
			[self processSession:managed];
	}
}

- (void)shutdown
{
	if (_shuttingDown)
		return;

	if (RRConfig.shared.workspace.saveOnQuit)
		(void)[self saveWorkspace];

	_shuttingDown = YES;
	for (RRManagedSession *managed in _sessions.allValues)
		[managed.session stop];
}

/* ---- RRSessionDelegate ------------------------------------------------------------------------- */

- (void)sessionDidConnect:(RRSession *)session
{
	RRManagedSession *managed = [self managedForSession:session];
	if (!managed)
		return;
	[self changed];

	/* Ein Server ohne RemoteApp-Dienst meldet den Kanal nie. */
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RRRailTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if ((self->_sessions[managed.serverId] != managed) || managed.session.railStarted)
			return;
		[managed.session stop];
		[self showError:[NSString stringWithFormat:@"„%@“ bietet keine RemoteApps an.", managed.serverName]
		         detail:@"Auf dem Server müssen die Remotedesktopdienste mit RemoteApp eingerichtet sein."];
	});
}

- (void)sessionRailDidStart:(RRSession *)session
{
	RRManagedSession *managed = [self managedForSession:session];
	if (!managed)
		return;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RRSettleDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (self->_sessions[managed.serverId] != managed)
			return;
		managed.ready = YES;
		[self processSession:managed];
	});
	[self changed];
}

- (void)sessionWindowsDidChange:(RRSession *)session
{
	RRManagedSession *managed = [self managedForSession:session];
	if (!managed)
		return;

	[self learnFromWindows:managed];
	if (managed.ready)
		[self placeWindows:managed];
	[self changed];
}

- (void)session:(RRSession *)session didEndWithError:(UINT32)error
{
	RRManagedSession *managed = [self managedForSession:session];
	if (!managed)
		return;

	[_sessions removeObjectForKey:managed.serverId];
	[self changed];

	if (_shuttingDown || (error == 0) || (error == FREERDP_ERROR_CONNECT_CANCELLED))
		return;
	/* Vom Server beendet (Abmelden, letzte RemoteApp geschlossen) ist kein Fehler. */
	if (GET_FREERDP_ERROR_CLASS(error) == FREERDP_ERROR_ERRINFO_CLASS)
		return;

	const char *text = freerdp_get_last_error_string(error);
	[self showError:[NSString stringWithFormat:@"Die Verbindung zu „%@“ wurde beendet.", managed.serverName]
	         detail:text ? [NSString stringWithUTF8String:text] : nil];
}

@end
