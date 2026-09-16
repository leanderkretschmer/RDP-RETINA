/*
 * rdp-retina – Bereich „Server“ des Hauptfensters
 *
 * Liste der RDP-Server links, Anmeldung rechts. Felder werden beim Verlassen gespeichert. Das
 * Kennwort liegt im Schlüsselbund und wird nur geschrieben, wenn der Benutzer es geändert hat;
 * ändern sich Adresse, Benutzer oder Domäne, zieht es zum neuen Konto um.
 */
#import "RRSettingsServersViewController.h"
#import "RRConfig.h"
#import "RRConnectionManager.h"
#import "RRSettingsForm.h"

static NSUserInterfaceItemIdentifier const RRServerCellIdentifier = @"RRServerCell";

static NSColor *RRServerStateColor(RRServerState state)
{
	switch (state)
	{
		case RRServerStateConnected:
			return NSColor.systemGreenColor;
		case RRServerStateConnecting:
			return NSColor.systemYellowColor;
		case RRServerStateDisconnected:
			break;
	}
	return NSColor.tertiaryLabelColor;
}

/* Adresse, wie der Benutzer sie einträgt: host oder host:port */
static NSString *RRServerAddress(RRServerConfig *server)
{
	if ((server.port == 0) || (server.port == 3389))
		return server.host;
	if ([server.host containsString:@":"])
		return [NSString stringWithFormat:@"[%@]:%lu", server.host, (unsigned long)server.port];
	return [NSString stringWithFormat:@"%@:%lu", server.host, (unsigned long)server.port];
}

static NSUInteger RRServerPort(RRServerConfig *server)
{
	return (server.port == 0) ? 3389 : server.port;
}

/* Dasselbe Konto im Schlüsselbund */
static BOOL RRSameAccount(RRServerConfig *a, RRServerConfig *b)
{
	return ([a.host caseInsensitiveCompare:b.host] == NSOrderedSame) &&
	       (RRServerPort(a) == RRServerPort(b)) &&
	       ([a.username caseInsensitiveCompare:b.username] == NSOrderedSame) &&
	       ([a.domain caseInsensitiveCompare:b.domain] == NSOrderedSame);
}

static BOOL RRSameServer(RRServerConfig *a, RRServerConfig *b)
{
	return [a.name isEqualToString:b.name] && [a.host isEqualToString:b.host] &&
	       (a.port == b.port) && [a.username isEqualToString:b.username] &&
	       [a.domain isEqualToString:b.domain];
}

@interface RRSettingsServersViewController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
- (void)addRemoveClicked:(NSSegmentedControl *)sender;
- (void)disconnectClicked:(id)sender;
- (void)configDidChange:(NSNotification *)notification;
- (void)connectionsDidChange:(NSNotification *)notification;
@end

@implementation RRSettingsServersViewController
{
	NSTableView *_table;
	NSSegmentedControl *_addRemove;
	NSStackView *_detail;
	NSTextField *_emptyHint;
	NSTextField *_nameField;
	NSTextField *_addressField;
	NSTextField *_userField;
	NSTextField *_domainField;
	NSSecureTextField *_passwordField;
	NSImageView *_statusDot;
	NSTextField *_statusLabel;
	NSButton *_disconnectButton;

	NSArray<RRServerConfig *> *_servers;
	RRServerConfig *_current;
	BOOL _passwordEdited;
	BOOL _passwordStored;
	BOOL _reloading;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

/* ---- Aufbau ---------------------------------------------------------------------------- */

- (void)loadView
{
	_table = [NSTableView new];
	NSScrollView *list = RRFormTableScrollView(_table, 26);
	_table.dataSource = self;
	_table.delegate = self;

	_addRemove = RRFormAddRemoveControl(self, @selector(addRemoveClicked:));

	_nameField = RRFormTextField(@"Anzeigename", self);
	_addressField = RRFormTextField(@"server.example.com oder 192.168.0.10:3389", self);
	_userField = RRFormTextField(@"Benutzer oder DOMÄNE\\Benutzer", self);
	_domainField = RRFormTextField(@"optional", self);
	_passwordField = RRFormSecureField(@"nicht gespeichert", self);

	_statusDot = [NSImageView imageViewWithImage:RRFormDotImage(NSColor.tertiaryLabelColor)];
	_statusLabel = [NSTextField labelWithString:@""];
	_disconnectButton = [NSButton buttonWithTitle:@"Trennen"
	                                       target:self
	                                       action:@selector(disconnectClicked:)];
	NSStackView *status = RRFormRow(@[ _statusDot, _statusLabel, _disconnectButton ]);

	NSGridView *grid = RRFormGrid(@[
		@[ RRFormLabel(@"Name:"), _nameField ],
		@[ RRFormLabel(@"Adresse:"), _addressField ],
		@[ RRFormLabel(@"Benutzer:"), _userField ],
		@[ RRFormLabel(@"Domäne:"), _domainField ],
		@[ RRFormLabel(@"Kennwort:"), _passwordField ],
		@[ RRFormLabel(@"Status:"), status ],
	]);
	NSGridRow *statusRow = [grid rowAtIndex:5];
	statusRow.rowAlignment = NSGridRowAlignmentNone;
	statusRow.yPlacement = NSGridCellPlacementCenter;
	statusRow.topPadding = 6;

	NSTextField *hint = RRFormHint(@"Das Kennwort liegt im Schlüsselbund. Ist keines gespeichert, "
	                               @"fragt rdp-retina beim Verbinden danach.");
	_detail = RRFormColumn(@[ RRFormHeadline(@"Server"), grid, hint ]);

	_emptyHint = [NSTextField labelWithString:@""];
	_emptyHint.textColor = NSColor.secondaryLabelColor;
	_emptyHint.translatesAutoresizingMaskIntoConstraints = NO;

	NSView *area = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 480)];
	for (NSView *view in @[ _detail, _emptyHint ])
	{
		[area addSubview:view];
		[NSLayoutConstraint activateConstraints:@[
			[view.leadingAnchor constraintEqualToAnchor:area.leadingAnchor],
			[view.topAnchor constraintEqualToAnchor:area.topAnchor],
			[view.trailingAnchor constraintLessThanOrEqualToAnchor:area.trailingAnchor],
			[view.bottomAnchor constraintLessThanOrEqualToAnchor:area.bottomAnchor],
		]];
	}

	self.view = RRFormMasterDetail(list, _addRemove, area);

	NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
	[center addObserver:self
	           selector:@selector(configDidChange:)
	               name:RRConfigDidChangeNotification
	             object:nil];
	[center addObserver:self
	           selector:@selector(connectionsDidChange:)
	               name:RRConnectionsDidChangeNotification
	             object:nil];

	[self reloadSelecting:[RRConfig shared].servers.firstObject.identifier];
}

- (NSTableCellView *)makeServerCell
{
	NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 220, 26)];
	cell.identifier = RRServerCellIdentifier;

	NSImageView *dot = [NSImageView imageViewWithImage:RRFormDotImage(NSColor.tertiaryLabelColor)];
	NSTextField *text = [NSTextField labelWithString:@""];
	text.lineBreakMode = NSLineBreakByTruncatingTail;
	[text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
	                               forOrientation:NSLayoutConstraintOrientationHorizontal];
	dot.translatesAutoresizingMaskIntoConstraints = NO;
	text.translatesAutoresizingMaskIntoConstraints = NO;
	[cell addSubview:dot];
	[cell addSubview:text];
	cell.imageView = dot;
	cell.textField = text;

	[NSLayoutConstraint activateConstraints:@[
		[dot.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
		[dot.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
		[dot.widthAnchor constraintEqualToConstant:10],
		[dot.heightAnchor constraintEqualToConstant:10],
		[text.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:8],
		[text.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
		[text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
	]];
	return cell;
}

/* ---- Anzeige ----------------------------------------------------------------------------- */

/* Liste neu laden und den Server mit identifier auswählen (nil = keinen). */
- (void)reloadSelecting:(NSString *)identifier
{
	_reloading = YES;
	_servers = [RRConfig shared].servers;
	[_table reloadData];

	NSInteger row = -1;
	for (NSUInteger i = 0; identifier && (i < _servers.count); i++)
	{
		if ([_servers[i].identifier isEqualToString:identifier])
		{
			row = (NSInteger)i;
			break;
		}
	}
	if (row >= 0)
	{
		[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
		    byExtendingSelection:NO];
		[_table scrollRowToVisible:row];
	}
	else
		[_table deselectAll:nil];
	_reloading = NO;

	[self selectionChanged];
}

- (void)selectionChanged
{
	const NSInteger row = _table.selectedRow;
	RRServerConfig *next = nil;
	if ((row >= 0) && ((NSUInteger)row < _servers.count))
		next = [_servers[(NSUInteger)row] copy];

	const BOOL switched = !next || !_current || ![next.identifier isEqualToString:_current.identifier];
	_current = next;
	if (switched)
	{
		_passwordEdited = NO;
		_passwordField.stringValue = @"";
		_passwordStored = _current ? ([[RRConfig shared] passwordForServer:_current].length > 0) : NO;
	}
	[self updateFields];
}

- (void)updateFields
{
	const BOOL has = (_current != nil);
	_detail.hidden = !has;
	_emptyHint.hidden = has;
	_emptyHint.stringValue =
	    (_servers.count == 0) ? @"Noch kein Server – mit + anlegen" : @"Links einen Server auswählen";
	[_addRemove setEnabled:has forSegment:1];
	if (!has)
		return;

	RRFormSetString(_nameField, _current.name);
	RRFormSetString(_addressField, RRServerAddress(_current));
	RRFormSetString(_userField, _current.username);
	RRFormSetString(_domainField, _current.domain);
	_passwordField.placeholderString =
	    _passwordStored ? @"im Schlüsselbund gespeichert" : @"nicht gespeichert";
	[self updateStatus];
}

- (void)updateStatus
{
	if (!_current)
		return;

	RRConnectionManager *manager = [RRConnectionManager shared];
	const RRServerState state = [manager stateForServerId:_current.identifier];
	const NSUInteger apps = [manager openAppCountForServerId:_current.identifier];

	switch (state)
	{
		case RRServerStateConnected:
			_statusLabel.stringValue =
			    (apps == 1) ? @"Verbunden – 1 RemoteApp offen"
			                : [NSString stringWithFormat:@"Verbunden – %lu RemoteApps offen",
			                                             (unsigned long)apps];
			break;
		case RRServerStateConnecting:
			_statusLabel.stringValue = @"Verbindet …";
			break;
		case RRServerStateDisconnected:
			_statusLabel.stringValue = @"Getrennt";
			break;
	}
	_statusDot.image = RRFormDotImage(RRServerStateColor(state));
	_disconnectButton.enabled = (state != RRServerStateDisconnected);
}

/* Wert aus _current in das Feld, auch während es gerade den Fokus abgibt */
- (void)showCurrentValueInField:(NSTextField *)field
{
	if (!_current)
		return;
	if (field == _nameField)
		field.stringValue = _current.name;
	else if (field == _addressField)
		field.stringValue = RRServerAddress(_current);
	else if (field == _userField)
		field.stringValue = _current.username;
	else if (field == _domainField)
		field.stringValue = _current.domain;
}

/* ---- Liste ------------------------------------------------------------------------------- */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return (NSInteger)_servers.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	NSTableCellView *cell = [tableView makeViewWithIdentifier:RRServerCellIdentifier owner:self];
	if (!cell)
		cell = [self makeServerCell];
	if ((row < 0) || ((NSUInteger)row >= _servers.count))
		return cell;

	RRServerConfig *server = _servers[(NSUInteger)row];
	cell.textField.stringValue = server.displayName;
	cell.imageView.image =
	    RRFormDotImage(RRServerStateColor([[RRConnectionManager shared] stateForServerId:server.identifier]));
	return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	if (!_reloading)
		[self selectionChanged];
}

/* ---- Felder ------------------------------------------------------------------------------ */

- (void)controlTextDidChange:(NSNotification *)notification
{
	if (notification.object == _passwordField)
		_passwordEdited = YES;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	id field = notification.object;
	if (!_current)
		return;
	if (field == _passwordField)
	{
		[self commitPassword];
		return;
	}

	RRServerConfig *old = _current;
	RRServerConfig *server = [old copy];
	if (field == _nameField)
		server.name = RRFormTrimmed(_nameField.stringValue);
	else if (field == _addressField)
		[server setAddress:RRFormTrimmed(_addressField.stringValue)];
	else if (field == _userField)
		[server setAccount:RRFormTrimmed(_userField.stringValue)];
	else if (field == _domainField)
		server.domain = RRFormTrimmed(_domainField.stringValue);
	else
		return;

	if (RRSameServer(old, server))
	{
		[self showCurrentValueInField:field];
		return;
	}

	/* Das Kennwort hängt am Konto (Benutzer@Adresse): beim Umbenennen mitnehmen. */
	NSString *password = nil;
	if (!RRSameAccount(old, server))
		password = [[RRConfig shared] passwordForServer:old];

	[[RRConfig shared] saveServer:server];

	if (password.length > 0)
	{
		NSError *error = nil;
		if ([[RRConfig shared] setPassword:password forServer:server error:&error])
			(void)[[RRConfig shared] setPassword:nil forServer:old error:NULL];
		else
			RRFormShowError(self.view.window, @"Das Kennwort ließ sich nicht übernehmen.", error);
	}

	[self showCurrentValueInField:field];
}

- (void)commitPassword
{
	if (!_passwordEdited || !_current)
		return;

	NSString *password = _passwordField.stringValue;
	NSError *error = nil;
	if (![[RRConfig shared] setPassword:((password.length > 0) ? password : nil)
	                          forServer:_current
	                              error:&error])
		RRFormShowError(self.view.window, @"Das Kennwort ließ sich nicht speichern.", error);

	_passwordEdited = NO;
	_passwordField.stringValue = @"";
	_passwordStored = ([[RRConfig shared] passwordForServer:_current].length > 0);
	[self updateFields];
}

/* ---- Aktionen ---------------------------------------------------------------------------- */

- (void)addRemoveClicked:(NSSegmentedControl *)sender
{
	NSWindow *window = self.view.window;
	if (!RRFormEndEditing(window))
		return;

	if (sender.selectedSegment == 0)
		[self addServer];
	else
		[self removeServerWithWindow:window];
}

- (void)addServer
{
	RRServerConfig *server = [RRServerConfig newServer];
	server.name = @"Neuer Server";
	[[RRConfig shared] saveServer:server];
	[self reloadSelecting:server.identifier];
	[self.view.window makeFirstResponder:_addressField];
}

- (void)removeServerWithWindow:(NSWindow *)window
{
	RRServerConfig *server = _current;
	if (!server)
		return;

	NSAlert *alert = [NSAlert new];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = [NSString stringWithFormat:@"„%@“ entfernen?", server.displayName];
	alert.informativeText = @"Die RemoteApps dieses Servers werden mit entfernt.";
	NSButton *remove = [alert addButtonWithTitle:@"Entfernen"];
	remove.hasDestructiveAction = YES;
	[alert addButtonWithTitle:@"Abbrechen"];

	void (^handler)(NSModalResponse) = ^(NSModalResponse response) {
		if (response != NSAlertFirstButtonReturn)
			return;

		const NSInteger row = self->_table.selectedRow;
		[[RRConfig shared] removeServerWithId:server.identifier];

		NSArray<RRServerConfig *> *servers = [RRConfig shared].servers;
		NSString *next = nil;
		if (servers.count > 0)
			next = servers[MIN((NSUInteger)MAX(row, (NSInteger)0), servers.count - 1)].identifier;
		[self reloadSelecting:next];
	};

	if (window)
		[alert beginSheetModalForWindow:window completionHandler:handler];
	else
		handler([alert runModal]);
}

- (void)disconnectClicked:(id)sender
{
	if (_current)
		[[RRConnectionManager shared] disconnectServerId:_current.identifier];
}

/* ---- Benachrichtigungen ------------------------------------------------------------------ */

- (void)configDidChange:(NSNotification *)notification
{
	NSString *identifier = _current.identifier ?: [RRConfig shared].servers.firstObject.identifier;
	[self reloadSelecting:identifier];
}

- (void)connectionsDidChange:(NSNotification *)notification
{
	if (_servers.count > 0)
		[_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _servers.count)]
		                  columnIndexes:[NSIndexSet indexSetWithIndex:0]];
	[self updateStatus];
}

@end
