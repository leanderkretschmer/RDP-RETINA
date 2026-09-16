/*
 * rdp-retina – Einstellungen der Oberfläche
 */
#import "RRConfig.h"
#import "RRCredentials.h"

NSNotificationName const RRConfigDidChangeNotification = @"RRConfigDidChangeNotification";

static NSString *const RRDefaultsServers = @"RRServers";
static NSString *const RRDefaultsApps = @"RRApps";
static NSString *const RRDefaultsTransfer = @"RRTransfer";
static NSString *const RRDefaultsWorkspace = @"RRWorkspace";

/* ---- Lesen aus Property Lists, tolerant gegenüber fehlenden oder falschen Werten -------- */

static NSString *RRString(id value)
{
	return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static NSInteger RRInteger(id value, NSInteger fallback)
{
	return [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value integerValue] : fallback;
}

static double RRDouble(id value)
{
	return [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value doubleValue] : 0.0;
}

static BOOL RRBool(id value, BOOL fallback)
{
	return [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value boolValue] : fallback;
}

static NSString *RRTrimmed(NSString *text)
{
	return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

/* Letzter Pfadbestandteil nach \ oder / */
static NSString *RRLastComponent(NSString *text)
{
	NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"\\/"];
	const NSRange range = [text rangeOfCharacterFromSet:separators options:NSBackwardsSearch];
	return (range.location == NSNotFound) ? text : [text substringFromIndex:range.location + 1];
}

/* ---- Server ------------------------------------------------------------------------------ */

@implementation RRServerConfig

+ (instancetype)newServer
{
	RRServerConfig *server = [[RRServerConfig alloc] init];
	server.identifier = NSUUID.UUID.UUIDString;
	return server;
}

+ (instancetype)serverWithDictionary:(NSDictionary *)dictionary
{
	RRServerConfig *server = [[RRServerConfig alloc] init];
	server.identifier = RRString(dictionary[@"id"]);
	server.name = RRString(dictionary[@"name"]);
	server.host = RRString(dictionary[@"host"]);
	server.port = (NSUInteger)MAX(RRInteger(dictionary[@"port"], 0), 0);
	server.username = RRString(dictionary[@"user"]);
	server.domain = RRString(dictionary[@"domain"]);
	return server;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_identifier = @"";
		_name = @"";
		_host = @"";
		_username = @"";
		_domain = @"";
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	RRServerConfig *copy = [[RRServerConfig allocWithZone:zone] init];
	copy.identifier = _identifier;
	copy.name = _name;
	copy.host = _host;
	copy.port = _port;
	copy.username = _username;
	copy.domain = _domain;
	return copy;
}

- (NSDictionary *)dictionary
{
	return @{
		@"id" : _identifier,
		@"name" : _name,
		@"host" : _host,
		@"port" : @(_port),
		@"user" : _username,
		@"domain" : _domain,
	};
}

- (NSString *)displayName
{
	NSString *name = RRTrimmed(_name);
	if (name.length > 0)
		return name;
	if (_host.length == 0)
		return @"Neuer Server";
	return (_port != 0) ? [NSString stringWithFormat:@"%@:%lu", _host, (unsigned long)_port] : _host;
}

- (void)setAddress:(NSString *)address
{
	NSString *text = RRTrimmed(address);
	NSUInteger port = 0;

	if ([text hasPrefix:@"["])
	{
		/* IPv6 mit Port: [fe80::1]:3390 */
		const NSRange close = [text rangeOfString:@"]"];
		if (close.location != NSNotFound)
		{
			NSString *rest = [text substringFromIndex:close.location + 1];
			if ([rest hasPrefix:@":"])
				port = (NSUInteger)MAX([rest substringFromIndex:1].integerValue, 0);
			text = [text substringWithRange:NSMakeRange(1, close.location - 1)];
		}
	}
	else
	{
		/* Genau ein Doppelpunkt: host:port. Mehrere: IPv6 ohne Port. */
		const NSRange first = [text rangeOfString:@":"];
		const NSRange last = [text rangeOfString:@":" options:NSBackwardsSearch];
		if ((first.location != NSNotFound) && (first.location == last.location))
		{
			port = (NSUInteger)MAX([text substringFromIndex:first.location + 1].integerValue, 0);
			text = [text substringToIndex:first.location];
		}
	}

	self.host = text;
	self.port = (port <= 65535) ? port : 0;
}

- (void)setAccount:(NSString *)account
{
	NSString *text = RRTrimmed(account);
	const NSRange slash = [text rangeOfString:@"\\"];

	if (slash.location != NSNotFound)
	{
		self.domain = [text substringToIndex:slash.location];
		self.username = [text substringFromIndex:slash.location + 1];
	}
	else
		self.username = text;
}

- (BOOL)isComplete
{
	return RRTrimmed(_host).length > 0;
}

@end

/* ---- RemoteApps -------------------------------------------------------------------------- */

@implementation RRAppConfig

+ (instancetype)newApp
{
	RRAppConfig *app = [[RRAppConfig alloc] init];
	app.identifier = NSUUID.UUID.UUIDString;
	return app;
}

+ (instancetype)appWithDictionary:(NSDictionary *)dictionary
{
	RRAppConfig *app = [[RRAppConfig alloc] init];
	app.identifier = RRString(dictionary[@"id"]);
	app.name = RRString(dictionary[@"name"]);
	app.serverId = RRString(dictionary[@"server"]);
	app.program = RRString(dictionary[@"program"]);
	app.arguments = RRString(dictionary[@"arguments"]);
	app.processName = RRString(dictionary[@"process"]);

	NSMutableArray<NSString *> *known = [NSMutableArray new];
	id list = dictionary[@"knownIds"];
	if ([list isKindOfClass:NSArray.class])
	{
		for (id value in (NSArray *)list)
		{
			if ([value isKindOfClass:NSString.class] && ([(NSString *)value length] > 0))
				[known addObject:value];
		}
	}
	app.knownApplicationIds = known;
	return app;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_identifier = @"";
		_name = @"";
		_serverId = @"";
		_program = @"";
		_arguments = @"";
		_processName = @"";
		_knownApplicationIds = @[];
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	RRAppConfig *copy = [[RRAppConfig allocWithZone:zone] init];
	copy.identifier = _identifier;
	copy.name = _name;
	copy.serverId = _serverId;
	copy.program = _program;
	copy.arguments = _arguments;
	copy.processName = _processName;
	copy.knownApplicationIds = _knownApplicationIds;
	return copy;
}

- (NSDictionary *)dictionary
{
	return @{
		@"id" : _identifier,
		@"name" : _name,
		@"server" : _serverId,
		@"program" : _program,
		@"arguments" : _arguments,
		@"process" : _processName,
		@"knownIds" : _knownApplicationIds,
	};
}

- (NSString *)matchProcessName
{
	NSString *explicitName = RRTrimmed(_processName);
	NSString *source = (explicitName.length > 0) ? explicitName : RRTrimmed(_program);

	if ([source hasPrefix:@"||"])
		source = [source substringFromIndex:2];
	source = RRLastComponent(source).lowercaseString;
	if (source.length == 0)
		return @"";

	/* Ein Alias ("||notepad") oder Pfad ohne Endung meint die .exe. Eine App-ID
	 * ("Microsoft.AutoGenerated.{…}") hat eine Endung und bleibt, wie sie ist. */
	if (source.pathExtension.length == 0)
		source = [source stringByAppendingString:@".exe"];
	return source;
}

- (BOOL)matchesApplicationId:(NSString *)applicationId
{
	NSString *wantedId = RRTrimmed(applicationId).lowercaseString;
	if (wantedId.length == 0)
		return NO;

	for (NSString *known in _knownApplicationIds)
	{
		if ([known.lowercaseString isEqualToString:wantedId])
			return YES;
	}

	NSString *name = self.matchProcessName;
	if (name.length == 0)
		return NO;
	return [RRLastComponent(wantedId) isEqualToString:name] || [wantedId isEqualToString:name];
}

- (NSString *)launchSpec
{
	NSMutableString *spec = [NSMutableString stringWithFormat:@"program:%@", RRTrimmed(_program)];
	NSString *arguments = RRTrimmed(_arguments);
	if (arguments.length > 0)
		[spec appendFormat:@",cmd:%@", arguments];
	return spec;
}

- (BOOL)isComplete
{
	return (RRTrimmed(_program).length > 0) && (_serverId.length > 0);
}

@end

/* ---- Übertragung ------------------------------------------------------------------------- */

@implementation RRTransferConfig

+ (instancetype)transferWithDictionary:(NSDictionary *)dictionary
{
	RRTransferConfig *transfer = [[RRTransferConfig alloc] init];
	transfer.maxApps = MIN(MAX(RRInteger(dictionary[@"maxApps"], 0), 0), 50);
	transfer.autoReconnect = RRBool(dictionary[@"autoReconnect"], YES);
	transfer.reconnectAttempts = MIN(MAX(RRInteger(dictionary[@"reconnectAttempts"], 20), 1), 1000);
	const NSInteger sound = RRInteger(dictionary[@"sound"], RRSoundModeMac);
	transfer.sound = ((sound >= RRSoundModeMac) && (sound <= RRSoundModeOff)) ? (RRSoundMode)sound
	                                                                           : RRSoundModeMac;
	transfer.microphone = RRBool(dictionary[@"microphone"], NO);
	transfer.clipboard = RRBool(dictionary[@"clipboard"], YES);
	transfer.multimon = RRBool(dictionary[@"multimon"], NO);
	const NSInteger scale = RRInteger(dictionary[@"scale"], 0);
	transfer.scalePercent = ((scale >= 100) && (scale <= 500)) ? scale : 0;
	return transfer;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_autoReconnect = YES;
		_reconnectAttempts = 20;
		_sound = RRSoundModeMac;
		_clipboard = YES;
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	RRTransferConfig *copy = [[RRTransferConfig allocWithZone:zone] init];
	copy.maxApps = _maxApps;
	copy.autoReconnect = _autoReconnect;
	copy.reconnectAttempts = _reconnectAttempts;
	copy.sound = _sound;
	copy.microphone = _microphone;
	copy.clipboard = _clipboard;
	copy.multimon = _multimon;
	copy.scalePercent = _scalePercent;
	return copy;
}

- (NSDictionary *)dictionary
{
	return @{
		@"maxApps" : @(_maxApps),
		@"autoReconnect" : @(_autoReconnect),
		@"reconnectAttempts" : @(_reconnectAttempts),
		@"sound" : @(_sound),
		@"microphone" : @(_microphone),
		@"clipboard" : @(_clipboard),
		@"multimon" : @(_multimon),
		@"scale" : @(_scalePercent),
	};
}

@end

/* ---- Arbeitsbereich ---------------------------------------------------------------------- */

@implementation RRWorkspaceItem

+ (instancetype)itemWithDictionary:(NSDictionary *)dictionary
{
	RRWorkspaceItem *item = [[RRWorkspaceItem alloc] init];
	item.appId = RRString(dictionary[@"app"]);
	item.serverRect = NSMakeRect(RRDouble(dictionary[@"x"]), RRDouble(dictionary[@"y"]),
	                             RRDouble(dictionary[@"width"]), RRDouble(dictionary[@"height"]));
	item.minimized = RRBool(dictionary[@"minimized"], NO);
	item.maximized = RRBool(dictionary[@"maximized"], NO);
	return item;
}

- (instancetype)init
{
	self = [super init];
	if (self)
		_appId = @"";
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	RRWorkspaceItem *copy = [[RRWorkspaceItem allocWithZone:zone] init];
	copy.appId = _appId;
	copy.serverRect = _serverRect;
	copy.minimized = _minimized;
	copy.maximized = _maximized;
	return copy;
}

- (NSDictionary *)dictionary
{
	return @{
		@"app" : _appId,
		@"x" : @(_serverRect.origin.x),
		@"y" : @(_serverRect.origin.y),
		@"width" : @(_serverRect.size.width),
		@"height" : @(_serverRect.size.height),
		@"minimized" : @(_minimized),
		@"maximized" : @(_maximized),
	};
}

@end

@implementation RRWorkspaceConfig

+ (instancetype)workspaceWithDictionary:(NSDictionary *)dictionary
{
	RRWorkspaceConfig *workspace = [[RRWorkspaceConfig alloc] init];
	workspace.saveOnQuit = RRBool(dictionary[@"saveOnQuit"], YES);
	workspace.restoreFromLink = RRBool(dictionary[@"restoreFromLink"], YES);
	id savedAt = dictionary[@"savedAt"];
	workspace.savedAt = [savedAt isKindOfClass:NSDate.class] ? (NSDate *)savedAt : nil;

	NSMutableArray<RRWorkspaceItem *> *items = [NSMutableArray new];
	id list = dictionary[@"items"];
	if ([list isKindOfClass:NSArray.class])
	{
		for (id value in (NSArray *)list)
		{
			if (![value isKindOfClass:NSDictionary.class])
				continue;
			RRWorkspaceItem *item = [RRWorkspaceItem itemWithDictionary:value];
			if (item.appId.length > 0)
				[items addObject:item];
		}
	}
	workspace.items = items;
	return workspace;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_saveOnQuit = YES;
		_restoreFromLink = YES;
		_items = @[];
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	RRWorkspaceConfig *copy = [[RRWorkspaceConfig allocWithZone:zone] init];
	copy.saveOnQuit = _saveOnQuit;
	copy.restoreFromLink = _restoreFromLink;
	copy.savedAt = _savedAt;
	copy.items = [[NSArray alloc] initWithArray:_items copyItems:YES];
	return copy;
}

- (NSDictionary *)dictionary
{
	NSMutableArray *items = [NSMutableArray arrayWithCapacity:_items.count];
	for (RRWorkspaceItem *item in _items)
		[items addObject:[item dictionary]];

	NSMutableDictionary *dictionary = [@{
		@"saveOnQuit" : @(_saveOnQuit),
		@"restoreFromLink" : @(_restoreFromLink),
		@"items" : items,
	} mutableCopy];
	if (_savedAt)
		dictionary[@"savedAt"] = _savedAt;
	return dictionary;
}

@end

/* ---- Speicher ---------------------------------------------------------------------------- */

@implementation RRConfig
{
	NSMutableArray<RRServerConfig *> *_serverList;
	NSMutableArray<RRAppConfig *> *_appList;
	RRTransferConfig *_transferConfig;
	RRWorkspaceConfig *_workspaceConfig;
}

+ (RRConfig *)shared
{
	static RRConfig *shared = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [[RRConfig alloc] init];
	});
	return shared;
}

- (instancetype)init
{
	self = [super init];
	if (!self)
		return nil;

	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

	_serverList = [NSMutableArray new];
	for (id value in [defaults arrayForKey:RRDefaultsServers] ?: @[])
	{
		if (![value isKindOfClass:NSDictionary.class])
			continue;
		RRServerConfig *server = [RRServerConfig serverWithDictionary:value];
		if (server.identifier.length > 0)
			[_serverList addObject:server];
	}

	_appList = [NSMutableArray new];
	for (id value in [defaults arrayForKey:RRDefaultsApps] ?: @[])
	{
		if (![value isKindOfClass:NSDictionary.class])
			continue;
		RRAppConfig *app = [RRAppConfig appWithDictionary:value];
		if (app.identifier.length > 0)
			[_appList addObject:app];
	}

	_transferConfig = [RRTransferConfig transferWithDictionary:[defaults dictionaryForKey:RRDefaultsTransfer] ?: @{}];
	_workspaceConfig =
	    [RRWorkspaceConfig workspaceWithDictionary:[defaults dictionaryForKey:RRDefaultsWorkspace] ?: @{}];
	return self;
}

- (void)changed
{
	[NSNotificationCenter.defaultCenter postNotificationName:RRConfigDidChangeNotification object:self];
}

- (void)storeServers
{
	NSMutableArray *list = [NSMutableArray arrayWithCapacity:_serverList.count];
	for (RRServerConfig *server in _serverList)
		[list addObject:[server dictionary]];
	[NSUserDefaults.standardUserDefaults setObject:list forKey:RRDefaultsServers];
}

- (void)storeApps
{
	NSMutableArray *list = [NSMutableArray arrayWithCapacity:_appList.count];
	for (RRAppConfig *app in _appList)
		[list addObject:[app dictionary]];
	[NSUserDefaults.standardUserDefaults setObject:list forKey:RRDefaultsApps];
}

/* ---- Lesen ---- */

- (NSArray<RRServerConfig *> *)servers
{
	return [[NSArray alloc] initWithArray:_serverList copyItems:YES];
}

- (NSArray<RRAppConfig *> *)apps
{
	NSArray<RRAppConfig *> *copies = [[NSArray alloc] initWithArray:_appList copyItems:YES];
	return [copies sortedArrayUsingComparator:^NSComparisonResult(RRAppConfig *a, RRAppConfig *b) {
		return [a.name localizedStandardCompare:b.name];
	}];
}

- (RRTransferConfig *)transfer
{
	return [_transferConfig copy];
}

- (RRWorkspaceConfig *)workspace
{
	return [_workspaceConfig copy];
}

- (RRServerConfig *)serverWithId:(NSString *)identifier
{
	for (RRServerConfig *server in _serverList)
	{
		if ([server.identifier isEqualToString:identifier])
			return [server copy];
	}
	return nil;
}

- (RRAppConfig *)appWithId:(NSString *)identifier
{
	for (RRAppConfig *app in _appList)
	{
		if ([app.identifier isEqualToString:identifier])
			return [app copy];
	}
	return nil;
}

- (NSArray<RRAppConfig *> *)appsForServerId:(NSString *)identifier
{
	NSMutableArray<RRAppConfig *> *result = [NSMutableArray new];
	for (RRAppConfig *app in self.apps)
	{
		if ([app.serverId isEqualToString:identifier])
			[result addObject:app];
	}
	return result;
}

/* ---- Schreiben ---- */

- (void)saveServer:(RRServerConfig *)server
{
	if (server.identifier.length == 0)
		return;

	RRServerConfig *copy = [server copy];
	NSUInteger index = [_serverList indexOfObjectPassingTest:^BOOL(RRServerConfig *other, NSUInteger i, BOOL *stop) {
		return [other.identifier isEqualToString:copy.identifier];
	}];

	if (index == NSNotFound)
		[_serverList addObject:copy];
	else
	{
		/* Neue Anmeldeangaben: das Kennwort wandert mit. */
		RRServerConfig *old = _serverList[index];
		NSString *oldAccount = RRCredentialsAccountFor(old.host, old.port, old.domain, old.username);
		NSString *newAccount = RRCredentialsAccountFor(copy.host, copy.port, copy.domain, copy.username);
		if (oldAccount && newAccount && ![oldAccount isEqualToString:newAccount])
		{
			NSString *password = RRCredentialsPassword(oldAccount);
			if (password && !RRCredentialsPassword(newAccount) &&
			    RRCredentialsStore(newAccount, password, NULL))
				(void)RRCredentialsDelete(oldAccount, NULL);
		}
		_serverList[index] = copy;
	}

	[self storeServers];
	[self changed];
}

- (void)removeServerWithId:(NSString *)identifier
{
	RRServerConfig *server = [self serverWithId:identifier];
	if (!server)
		return;

	NSString *account = RRCredentialsAccountFor(server.host, server.port, server.domain, server.username);
	if (account)
		(void)RRCredentialsDelete(account, NULL);

	for (RRAppConfig *app in [self appsForServerId:identifier])
		[self removeIconFileForAppId:app.identifier];

	[_appList filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RRAppConfig *app, NSDictionary *bindings) {
		return ![app.serverId isEqualToString:identifier];
	}]];
	[_serverList filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RRServerConfig *other, NSDictionary *bindings) {
		return ![other.identifier isEqualToString:identifier];
	}]];

	[self storeServers];
	[self storeApps];
	[self changed];
}

- (void)saveApp:(RRAppConfig *)app
{
	if (app.identifier.length == 0)
		return;

	RRAppConfig *copy = [app copy];
	NSUInteger index = [_appList indexOfObjectPassingTest:^BOOL(RRAppConfig *other, NSUInteger i, BOOL *stop) {
		return [other.identifier isEqualToString:copy.identifier];
	}];

	if (index == NSNotFound)
		[_appList addObject:copy];
	else
		_appList[index] = copy;

	[self storeApps];
	[self changed];
}

- (void)removeAppWithId:(NSString *)identifier
{
	[self removeIconFileForAppId:identifier];
	[_appList filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RRAppConfig *app, NSDictionary *bindings) {
		return ![app.identifier isEqualToString:identifier];
	}]];
	[self storeApps];
	[self changed];
}

- (void)saveTransfer:(RRTransferConfig *)transfer
{
	_transferConfig = [transfer copy];
	[NSUserDefaults.standardUserDefaults setObject:[_transferConfig dictionary] forKey:RRDefaultsTransfer];
	[self changed];
}

- (void)saveWorkspace:(RRWorkspaceConfig *)workspace
{
	_workspaceConfig = [workspace copy];
	[NSUserDefaults.standardUserDefaults setObject:[_workspaceConfig dictionary] forKey:RRDefaultsWorkspace];
	[self changed];
}

/* ---- Kennwörter ---- */

- (NSString *)passwordForServer:(RRServerConfig *)server
{
	NSString *account = RRCredentialsAccountFor(server.host, server.port, server.domain, server.username);
	return account ? RRCredentialsPassword(account) : nil;
}

- (BOOL)setPassword:(NSString *)password forServer:(RRServerConfig *)server error:(NSError **)error
{
	NSString *account = RRCredentialsAccountFor(server.host, server.port, server.domain, server.username);
	if (!account)
	{
		if (error)
			*error = [NSError errorWithDomain:@"rdp-retina"
			                             code:1
			                         userInfo:@{
				                         NSLocalizedDescriptionKey :
				                             @"Für das Kennwort braucht der Server eine Adresse und einen Benutzer."
			                         }];
		return NO;
	}

	if (password.length == 0)
		return RRCredentialsDelete(account, error);
	return RRCredentialsStore(account, password, error);
}

/* ---- Symbole ---- */

- (NSURL *)iconDirectory
{
	NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
	                                                      inDomains:NSUserDomainMask]
	                     .firstObject;
	return [[support URLByAppendingPathComponent:@"rdp-retina" isDirectory:YES]
	    URLByAppendingPathComponent:@"Symbole"
	                    isDirectory:YES];
}

- (NSURL *)iconURLForAppId:(NSString *)identifier
{
	/* Nur die ID als Dateiname, keine Pfadbestandteile */
	NSString *file = [[identifier stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
	    stringByAppendingPathExtension:@"png"];
	return [[self iconDirectory] URLByAppendingPathComponent:file isDirectory:NO];
}

- (void)removeIconFileForAppId:(NSString *)identifier
{
	(void)[NSFileManager.defaultManager removeItemAtURL:[self iconURLForAppId:identifier] error:NULL];
}

- (NSImage *)iconForAppId:(NSString *)identifier
{
	NSURL *url = [self iconURLForAppId:identifier];
	if (![NSFileManager.defaultManager fileExistsAtPath:url.path])
		return nil;
	return [[NSImage alloc] initWithContentsOfURL:url];
}

/* Bild seitenrichtig in ein Quadrat von pixels × pixels einpassen, als PNG */
static NSData *RRSquarePNG(NSImage *image, NSInteger pixels)
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
	                                                                pixelsWide:pixels
	                                                                pixelsHigh:pixels
	                                                             bitsPerSample:8
	                                                           samplesPerPixel:4
	                                                                  hasAlpha:YES
	                                                                  isPlanar:NO
	                                                            colorSpaceName:NSDeviceRGBColorSpace
	                                                               bytesPerRow:0
	                                                              bitsPerPixel:0];
	if (!rep)
		return nil;
	rep.size = NSMakeSize(pixels, pixels);

	NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
	if (!context)
		return nil;

	[NSGraphicsContext saveGraphicsState];
	NSGraphicsContext.currentContext = context;
	context.imageInterpolation = NSImageInterpolationHigh;

	const CGFloat side = (CGFloat)pixels;
	const NSSize size = image.size;
	NSRect target = NSMakeRect(0, 0, side, side);
	if ((size.width > 0) && (size.height > 0))
	{
		const CGFloat factor = MIN(side / size.width, side / size.height);
		const CGFloat width = size.width * factor;
		const CGFloat height = size.height * factor;
		target = NSMakeRect((side - width) / 2.0, (side - height) / 2.0, width, height);
	}
	[image drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
	[NSGraphicsContext restoreGraphicsState];

	return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (BOOL)setIcon:(NSImage *)image forAppId:(NSString *)identifier error:(NSError **)error
{
	if (!image)
	{
		[self removeIconFileForAppId:identifier];
		[self changed];
		return YES;
	}

	NSData *png = RRSquarePNG(image, 1024);
	if (!png)
	{
		if (error)
			*error = [NSError errorWithDomain:@"rdp-retina"
			                             code:2
			                         userInfo:@{ NSLocalizedDescriptionKey : @"Das Bild ließ sich nicht lesen." }];
		return NO;
	}

	if (![NSFileManager.defaultManager createDirectoryAtURL:[self iconDirectory]
	                            withIntermediateDirectories:YES
	                                             attributes:nil
	                                                  error:error])
		return NO;
	if (![png writeToURL:[self iconURLForAppId:identifier] options:NSDataWritingAtomic error:error])
		return NO;

	[self changed];
	return YES;
}

/* ---- Sitzung ---- */

- (NSArray<NSString *> *)sessionArgumentsForServer:(RRServerConfig *)server
{
	RRTransferConfig *transfer = _transferConfig;
	NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObject:@"rdp-retina"];

	/* IPv6 in eckigen Klammern, sonst wäre der Port nicht zu erkennen */
	NSString *host = RRTrimmed(server.host);
	if ([host containsString:@":"])
		host = [NSString stringWithFormat:@"[%@]", host];
	if (server.port != 0)
		[arguments addObject:[NSString stringWithFormat:@"/v:%@:%lu", host, (unsigned long)server.port]];
	else
		[arguments addObject:[@"/v:" stringByAppendingString:host]];

	if (RRTrimmed(server.username).length > 0)
		[arguments addObject:[@"/u:" stringByAppendingString:RRTrimmed(server.username)]];
	if (RRTrimmed(server.domain).length > 0)
		[arguments addObject:[@"/d:" stringByAppendingString:RRTrimmed(server.domain)]];

	[arguments addObject:@"/retina-remoteapp"];

	if (transfer.autoReconnect)
	{
		[arguments addObject:@"+auto-reconnect"];
		[arguments addObject:[NSString stringWithFormat:@"/auto-reconnect-max-retries:%ld",
		                                                (long)transfer.reconnectAttempts]];
	}
	else
		[arguments addObject:@"-auto-reconnect"];

	[arguments addObject:[NSString stringWithFormat:@"/audio-mode:%ld", (long)transfer.sound]];
	if (transfer.microphone)
		[arguments addObject:@"/microphone"];
	[arguments addObject:transfer.clipboard ? @"+clipboard" : @"-clipboard"];
	if (transfer.multimon)
		[arguments addObject:@"/multimon"];
	if (transfer.scalePercent > 0)
		[arguments addObject:[NSString stringWithFormat:@"/scale-desktop:%ld", (long)transfer.scalePercent]];
	return arguments;
}

@end
