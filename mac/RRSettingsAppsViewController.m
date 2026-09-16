/*
 * rdp-retina – Bereich „RemoteApps“ des Hauptfensters
 *
 * RDP kann nicht abfragen, welche Programme ein Server freigibt – der Benutzer trägt Programm,
 * Name und Symbol selbst ein. Von hier aus lässt sich eine RemoteApp starten und eine
 * Verknüpfung (Companion-App) mit ihrem Symbol anlegen.
 */
#import "RRSettingsAppsViewController.h"
#import "RRConfig.h"
#import "RRConnectionManager.h"
#import "RRLinkInstaller.h"
#import "RRSettingsForm.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSUserInterfaceItemIdentifier const RRAppCellIdentifier = @"RRAppCell";

/* Zelle der Liste: Symbol, Name, darunter der Server */
@interface RRAppCellView : NSTableCellView
@property (nonatomic, strong) NSTextField *detailField;
@end

@implementation RRAppCellView
@end

@interface RRSettingsAppsViewController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
- (void)addRemoveClicked:(NSSegmentedControl *)sender;
- (void)serverChanged:(NSPopUpButton *)sender;
- (void)chooseIconClicked:(id)sender;
- (void)removeIconClicked:(id)sender;
- (void)iconDropped:(NSImageView *)sender;
- (void)startClicked:(id)sender;
- (void)installClicked:(id)sender;
- (void)configDidChange:(NSNotification *)notification;
@end

@implementation RRSettingsAppsViewController
{
	NSTableView *_table;
	NSSegmentedControl *_addRemove;
	NSStackView *_detail;
	NSTextField *_emptyHint;
	NSTextField *_nameField;
	NSPopUpButton *_serverPopup;
	NSTextField *_programField;
	NSTextField *_argumentsField;
	NSTextField *_processField;
	NSImageView *_iconView;
	NSButton *_chooseIconButton;
	NSButton *_removeIconButton;
	NSButton *_startButton;
	NSButton *_installButton;

	NSArray<RRAppConfig *> *_apps;
	RRAppConfig *_current;
	NSMutableDictionary<NSString *, NSImage *> *_iconCache;
	BOOL _reloading;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

/* ---- Aufbau ---------------------------------------------------------------------------- */

- (void)loadView
{
	_iconCache = [NSMutableDictionary new];

	_table = [NSTableView new];
	NSScrollView *list = RRFormTableScrollView(_table, 44);
	_table.dataSource = self;
	_table.delegate = self;

	_addRemove = RRFormAddRemoveControl(self, @selector(addRemoveClicked:));

	_nameField = RRFormTextField(@"Name im Dock", self);

	_serverPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_serverPopup.autoenablesItems = NO;
	_serverPopup.target = self;
	_serverPopup.action = @selector(serverChanged:);
	_serverPopup.translatesAutoresizingMaskIntoConstraints = NO;
	[_serverPopup.widthAnchor constraintEqualToConstant:RRFormFieldWidth].active = YES;

	_programField = RRFormTextField(@"||notepad oder C:\\Windows\\System32\\notepad.exe", self);
	_argumentsField = RRFormTextField(@"optional", self);
	_processField = RRFormTextField(@"für die Zuordnung offener Fenster", self);

	_iconView = [NSImageView new];
	_iconView.editable = YES;
	_iconView.allowsCutCopyPaste = NO;
	_iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
	_iconView.imageFrameStyle = NSImageFrameNone;
	_iconView.target = self;
	_iconView.action = @selector(iconDropped:);
	_iconView.toolTip = @"Bild hierher ziehen";
	_iconView.translatesAutoresizingMaskIntoConstraints = NO;
	[NSLayoutConstraint activateConstraints:@[
		[_iconView.widthAnchor constraintEqualToConstant:128],
		[_iconView.heightAnchor constraintEqualToConstant:128],
	]];

	_chooseIconButton = [NSButton buttonWithTitle:@"Symbol wählen …"
	                                       target:self
	                                       action:@selector(chooseIconClicked:)];
	_removeIconButton = [NSButton buttonWithTitle:@"Entfernen"
	                                       target:self
	                                       action:@selector(removeIconClicked:)];
	NSTextField *iconHint = RRFormHint(@"Unten rechts erscheint das Symbol von rdp-retina.");
	NSStackView *iconButtons = RRFormColumn(@[ _chooseIconButton, _removeIconButton, iconHint ]);
	iconButtons.spacing = 8;
	NSStackView *iconRow = RRFormRow(@[ _iconView, iconButtons ]);
	iconRow.alignment = NSLayoutAttributeTop;
	iconRow.spacing = 14;

	NSGridView *grid = RRFormGrid(@[
		@[ RRFormLabel(@"Name:"), _nameField ],
		@[ RRFormLabel(@"Server:"), _serverPopup ],
		@[ RRFormLabel(@"Programm:"), _programField ],
		@[ RRFormLabel(@"Argumente:"), _argumentsField ],
		@[ RRFormLabel(@"Prozessname:"), _processField ],
		@[ RRFormLabel(@"Symbol:"), iconRow ],
	]);
	NSGridRow *serverRow = [grid rowAtIndex:1];
	serverRow.rowAlignment = NSGridRowAlignmentNone;
	serverRow.yPlacement = NSGridCellPlacementCenter;
	NSGridRow *iconGridRow = [grid rowAtIndex:5];
	iconGridRow.rowAlignment = NSGridRowAlignmentNone;
	iconGridRow.yPlacement = NSGridCellPlacementTop;
	iconGridRow.topPadding = 4;

	_startButton = [NSButton buttonWithTitle:@"Starten" target:self action:@selector(startClicked:)];
	_installButton = [NSButton buttonWithTitle:@"Verknüpfung installieren …"
	                                    target:self
	                                    action:@selector(installClicked:)];
	NSStackView *actions = RRFormRow(@[ _startButton, _installButton ]);

	NSTextField *hint = RRFormHint(
	    @"RDP kann nicht abfragen, welche Programme ein Server freigibt. Eintragen, was dort als "
	    @"RemoteApp freigegeben ist: den Alias aus der Freigabeliste (||notepad) oder den "
	    @"vollständigen Pfad.");
	NSTextField *processHint = RRFormHint(
	    @"Am Prozessnamen erkennt rdp-retina, ob das Programm schon offen ist, und ordnet Fenster "
	    @"im Arbeitsbereich zu. Leer lassen, wenn er sich aus dem Programm ergibt.");

	_detail = RRFormColumn(@[ RRFormHeadline(@"RemoteApp"), grid, actions, hint, processHint ]);
	[_detail setCustomSpacing:20 afterView:grid];
	[_detail setCustomSpacing:20 afterView:actions];
	[_detail setCustomSpacing:8 afterView:hint];

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

	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(configDidChange:)
	                                           name:RRConfigDidChangeNotification
	                                         object:nil];

	[self reloadSelecting:[RRConfig shared].apps.firstObject.identifier];
}

- (RRAppCellView *)makeAppCell
{
	RRAppCellView *cell = [[RRAppCellView alloc] initWithFrame:NSMakeRect(0, 0, 220, 44)];
	cell.identifier = RRAppCellIdentifier;

	NSImageView *icon = [NSImageView new];
	icon.imageScaling = NSImageScaleProportionallyUpOrDown;
	NSTextField *name = [NSTextField labelWithString:@""];
	name.lineBreakMode = NSLineBreakByTruncatingTail;
	NSTextField *server = [NSTextField labelWithString:@""];
	server.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	server.textColor = NSColor.secondaryLabelColor;
	server.lineBreakMode = NSLineBreakByTruncatingTail;

	for (NSView *view in @[ icon, name, server ])
	{
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[cell addSubview:view];
	}
	for (NSTextField *field in @[ name, server ])
		[field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
		                                forOrientation:NSLayoutConstraintOrientationHorizontal];
	cell.imageView = icon;
	cell.textField = name;
	cell.detailField = server;

	[NSLayoutConstraint activateConstraints:@[
		[icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
		[icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
		[icon.widthAnchor constraintEqualToConstant:32],
		[icon.heightAnchor constraintEqualToConstant:32],
		[name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
		[name.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
		[name.bottomAnchor constraintEqualToAnchor:cell.centerYAnchor constant:1],
		[server.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
		[server.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
		[server.topAnchor constraintEqualToAnchor:cell.centerYAnchor constant:1],
	]];
	return cell;
}

/* ---- Anzeige ----------------------------------------------------------------------------- */

- (NSImage *)iconForAppId:(NSString *)identifier
{
	NSImage *image = _iconCache[identifier];
	if (!image)
	{
		image = RRLinkBadgedIcon([[RRConfig shared] iconForAppId:identifier]);
		_iconCache[identifier] = image;
	}
	return image;
}

/* Liste neu laden und die RemoteApp mit identifier auswählen (nil = keine). */
- (void)reloadSelecting:(NSString *)identifier
{
	_reloading = YES;
	_apps = [RRConfig shared].apps;
	[_table reloadData];

	NSInteger row = -1;
	for (NSUInteger i = 0; identifier && (i < _apps.count); i++)
	{
		if ([_apps[i].identifier isEqualToString:identifier])
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
	_current = nil;
	if ((row >= 0) && ((NSUInteger)row < _apps.count))
		_current = [_apps[(NSUInteger)row] copy];
	[self updateFields];
}

- (void)updateFields
{
	const BOOL has = (_current != nil);
	_detail.hidden = !has;
	_emptyHint.hidden = has;
	_emptyHint.stringValue = (_apps.count == 0) ? @"Noch keine RemoteApp – mit + anlegen"
	                                            : @"Links eine RemoteApp auswählen";
	[_addRemove setEnabled:has forSegment:1];
	if (!has)
		return;

	RRFormSetString(_nameField, _current.name);
	RRFormSetString(_programField, _current.program);
	RRFormSetString(_argumentsField, _current.arguments);
	RRFormSetString(_processField, _current.processName);
	[self updateProcessPlaceholderForProgram:(_programField.currentEditor ? _programField.stringValue
	                                                                      : _current.program)];
	[self fillServerPopup];

	_iconView.image = [self iconForAppId:_current.identifier];
	_removeIconButton.enabled = ([[RRConfig shared] iconForAppId:_current.identifier] != nil);
	[self updateActions];
}

- (void)fillServerPopup
{
	[_serverPopup removeAllItems];
	NSMenu *menu = _serverPopup.menu;
	NSMenuItem *selected = nil;

	for (RRServerConfig *server in [RRConfig shared].servers)
	{
		NSMenuItem *item = [menu addItemWithTitle:server.displayName action:NULL keyEquivalent:@""];
		item.representedObject = server.identifier;
		if ([server.identifier isEqualToString:_current.serverId])
			selected = item;
	}

	if (!selected)
	{
		const BOOL hasServers = (menu.numberOfItems > 0);
		if (hasServers)
			[menu addItem:[NSMenuItem separatorItem]];
		selected = [menu addItemWithTitle:(hasServers ? @"Server fehlt" : @"Kein Server angelegt")
		                           action:NULL
		                    keyEquivalent:@""];
		selected.enabled = NO;
	}
	[_serverPopup selectItem:selected];
	_serverPopup.enabled = ([RRConfig shared].servers.count > 0);
}

- (void)updateProcessPlaceholderForProgram:(NSString *)program
{
	if (!_current)
		return;

	RRAppConfig *probe = [_current copy];
	probe.program = RRFormTrimmed(program);
	probe.processName = @"";
	NSString *name = probe.matchProcessName;
	_processField.placeholderString = (name.length > 0) ? name : @"für die Zuordnung offener Fenster";
}

- (void)updateActions
{
	const BOOL ready = (_current != nil) && _current.complete &&
	                   ([[RRConfig shared] serverWithId:_current.serverId] != nil);
	_startButton.enabled = ready;
	_installButton.enabled = ready;
}

/* ---- Liste ------------------------------------------------------------------------------- */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return (NSInteger)_apps.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	RRAppCellView *cell = [tableView makeViewWithIdentifier:RRAppCellIdentifier owner:self];
	if (!cell)
		cell = [self makeAppCell];
	if ((row < 0) || ((NSUInteger)row >= _apps.count))
		return cell;

	RRAppConfig *app = _apps[(NSUInteger)row];
	RRServerConfig *server = [[RRConfig shared] serverWithId:app.serverId];
	cell.textField.stringValue = (app.name.length > 0) ? app.name : @"Ohne Namen";
	cell.detailField.stringValue = server ? server.displayName : @"kein Server";
	cell.imageView.image = [self iconForAppId:app.identifier];
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
	if (notification.object == _programField)
		[self updateProcessPlaceholderForProgram:_programField.stringValue];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	id field = notification.object;
	if (!_current)
		return;

	RRAppConfig *app = [_current copy];
	if (field == _nameField)
		app.name = RRFormTrimmed(_nameField.stringValue);
	else if (field == _programField)
		app.program = RRFormTrimmed(_programField.stringValue);
	else if (field == _argumentsField)
		app.arguments = RRFormTrimmed(_argumentsField.stringValue);
	else if (field == _processField)
		app.processName = RRFormTrimmed(_processField.stringValue);
	else
		return;

	const BOOL unchanged = [app.name isEqualToString:_current.name] &&
	                       [app.program isEqualToString:_current.program] &&
	                       [app.arguments isEqualToString:_current.arguments] &&
	                       [app.processName isEqualToString:_current.processName];
	if (!unchanged)
		[[RRConfig shared] saveApp:app];

	/* Anzeige wie gespeichert (getrimmt), auch im Feld, das gerade den Fokus abgibt */
	NSTextField *textField = field;
	if (textField == _nameField)
		textField.stringValue = _current.name;
	else if (textField == _programField)
		textField.stringValue = _current.program;
	else if (textField == _argumentsField)
		textField.stringValue = _current.arguments;
	else if (textField == _processField)
		textField.stringValue = _current.processName;
}

- (void)serverChanged:(NSPopUpButton *)sender
{
	id identifier = sender.selectedItem.representedObject;
	if (!_current || ![identifier isKindOfClass:NSString.class] ||
	    [_current.serverId isEqualToString:identifier])
		return;

	RRAppConfig *app = [_current copy];
	app.serverId = identifier;
	[[RRConfig shared] saveApp:app];
}

/* ---- Symbol ------------------------------------------------------------------------------ */

- (void)storeIcon:(NSImage *)image forAppId:(NSString *)identifier
{
	NSError *error = nil;
	if (![[RRConfig shared] setIcon:image forAppId:identifier error:&error])
		RRFormShowError(self.view.window, @"Das Symbol ließ sich nicht speichern.", error);

	[_iconCache removeObjectForKey:identifier];
	[self reloadSelecting:_current.identifier];
}

- (void)chooseIconClicked:(id)sender
{
	NSWindow *window = self.view.window;
	if (!_current || !window)
		return;

	NSString *identifier = _current.identifier;
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	panel.allowedContentTypes = @[ UTTypeImage ];
	panel.allowsMultipleSelection = NO;
	panel.canChooseDirectories = NO;
	panel.canChooseFiles = YES;
	panel.message = @"Symbol für die RemoteApp wählen";
	panel.prompt = @"Übernehmen";

	[panel beginSheetModalForWindow:window
	              completionHandler:^(NSModalResponse result) {
		              NSURL *url = panel.URL;
		              if ((result != NSModalResponseOK) || !url)
			              return;

		              NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
		              if (!image)
		              {
			              RRFormShowAlert(window, @"Das Bild ließ sich nicht lesen.", url.lastPathComponent,
			                              NSAlertStyleWarning);
			              return;
		              }
		              [self storeIcon:image forAppId:identifier];
	              }];
}

- (void)removeIconClicked:(id)sender
{
	if (_current)
		[self storeIcon:nil forAppId:_current.identifier];
}

- (void)iconDropped:(NSImageView *)sender
{
	if (!_current)
		return;

	NSImage *image = sender.image;
	if (image)
		[self storeIcon:image forAppId:_current.identifier];
	else
		[self updateFields];
}

/* ---- Aktionen ---------------------------------------------------------------------------- */

- (void)addRemoveClicked:(NSSegmentedControl *)sender
{
	NSWindow *window = self.view.window;
	if (!RRFormEndEditing(window))
		return;

	if (sender.selectedSegment == 0)
		[self addApp];
	else
		[self removeAppWithWindow:window];
}

- (void)addApp
{
	RRAppConfig *app = [RRAppConfig newApp];
	app.name = @"Neue RemoteApp";
	app.serverId = [RRConfig shared].servers.firstObject.identifier ?: @"";
	[[RRConfig shared] saveApp:app];
	[self reloadSelecting:app.identifier];
	[self.view.window makeFirstResponder:_nameField];
}

- (void)removeAppWithWindow:(NSWindow *)window
{
	RRAppConfig *app = _current;
	if (!app)
		return;

	NSAlert *alert = [NSAlert new];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = [NSString stringWithFormat:@"„%@“ entfernen?", app.name];
	alert.informativeText = @"Das Symbol wird mit gelöscht. Installierte Verknüpfungen dieser "
	                        @"RemoteApp funktionieren danach nicht mehr.";
	NSButton *remove = [alert addButtonWithTitle:@"Entfernen"];
	remove.hasDestructiveAction = YES;
	[alert addButtonWithTitle:@"Abbrechen"];

	void (^handler)(NSModalResponse) = ^(NSModalResponse response) {
		if (response != NSAlertFirstButtonReturn)
			return;

		const NSInteger row = self->_table.selectedRow;
		[[RRConfig shared] removeAppWithId:app.identifier];
		[self->_iconCache removeObjectForKey:app.identifier];

		NSArray<RRAppConfig *> *apps = [RRConfig shared].apps;
		NSString *next = nil;
		if (apps.count > 0)
			next = apps[MIN((NSUInteger)MAX(row, (NSInteger)0), apps.count - 1)].identifier;
		[self reloadSelecting:next];
	};

	if (window)
		[alert beginSheetModalForWindow:window completionHandler:handler];
	else
		handler([alert runModal]);
}

- (void)startClicked:(id)sender
{
	if (!RRFormEndEditing(self.view.window) || !_current)
		return;
	[[RRConnectionManager shared] openApp:_current fromLink:NO];
}

- (void)installClicked:(id)sender
{
	NSWindow *window = self.view.window;
	if (!window || !RRFormEndEditing(window) || !_current)
		return;

	RRAppConfig *app = [_current copy];
	NSImage *icon = [[RRConfig shared] iconForAppId:app.identifier];
	[RRLinkInstaller installLinkForApp:app
	                              icon:icon
	                            window:window
	                        completion:^(NSURL *link, NSError *error) {
		                        if (error)
		                        {
			                        RRFormShowError(window, @"Die Verknüpfung ließ sich nicht anlegen.",
			                                        error);
			                        return;
		                        }
		                        if (!link)
			                        return;

		                        NSString *folder =
		                            link.URLByDeletingLastPathComponent.path.stringByAbbreviatingWithTildeInPath;
		                        NSString *message =
		                            [NSString stringWithFormat:@"„%@“ liegt jetzt in %@.", app.name,
		                                                       folder ?: @"dem gewählten Ordner"];
		                        RRFormShowAlert(window, message,
		                                        @"Zum Dock hinzufügen: aus dem Finder ins Dock ziehen.",
		                                        NSAlertStyleInformational);
	                        }];
}

/* ---- Benachrichtigungen ------------------------------------------------------------------ */

- (void)configDidChange:(NSNotification *)notification
{
	[_iconCache removeAllObjects];
	NSString *identifier = _current.identifier ?: [RRConfig shared].apps.firstObject.identifier;
	[self reloadSelecting:identifier];
}

@end
