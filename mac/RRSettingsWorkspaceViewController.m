/*
 * rdp-retina – Bereich „Arbeitsbereich“ des Hauptfensters
 *
 * Welche RemoteApps offen sind und wo ihre Fenster liegen: speichern, wiederherstellen und die
 * gespeicherten Einträge ansehen. Das eigentliche Speichern und Wiederherstellen erledigt
 * RRConnectionManager.
 */
#import "RRSettingsWorkspaceViewController.h"
#import "RRConfig.h"
#import "RRConnectionManager.h"
#import "RRSettingsForm.h"

static NSUserInterfaceItemIdentifier const RRColumnApp = @"app";
static NSUserInterfaceItemIdentifier const RRColumnServer = @"server";
static NSUserInterfaceItemIdentifier const RRColumnFrame = @"frame";
static NSUserInterfaceItemIdentifier const RRColumnState = @"state";

@interface RRSettingsWorkspaceViewController () <NSTableViewDataSource, NSTableViewDelegate>
- (void)checkboxChanged:(id)sender;
- (void)saveClicked:(id)sender;
- (void)restoreClicked:(id)sender;
- (void)configDidChange:(NSNotification *)notification;
@end

@implementation RRSettingsWorkspaceViewController
{
	NSButton *_saveOnQuitCheckbox;
	NSButton *_restoreCheckbox;
	NSButton *_saveButton;
	NSButton *_restoreButton;
	NSTextField *_savedLabel;
	NSTableView *_table;
	NSArray<RRWorkspaceItem *> *_items;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

/* ---- Aufbau ---------------------------------------------------------------------------- */

- (void)addColumn:(NSUserInterfaceItemIdentifier)identifier title:(NSString *)title width:(CGFloat)width
{
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
	column.title = title;
	column.width = width;
	column.minWidth = 60;
	column.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
	[_table addTableColumn:column];
}

- (void)loadView
{
	NSTextField *explanation = RRFormHint(
	    @"Merkt sich, welche RemoteApps offen sind und wo ihre Fenster liegen. Öffnest du nach einem "
	    @"Neustart eine Verknüpfung, startet rdp-retina alle Programme wieder und legt die Fenster an "
	    @"dieselbe Stelle.");
	explanation.font = [NSFont systemFontOfSize:NSFont.systemFontSize];

	_saveOnQuitCheckbox = [NSButton checkboxWithTitle:@"Beim Beenden merken"
	                                           target:self
	                                           action:@selector(checkboxChanged:)];
	_restoreCheckbox = [NSButton checkboxWithTitle:@"Beim Öffnen einer Verknüpfung wiederherstellen"
	                                        target:self
	                                        action:@selector(checkboxChanged:)];
	_saveButton = [NSButton buttonWithTitle:@"Aktuellen Arbeitsbereich speichern"
	                                 target:self
	                                 action:@selector(saveClicked:)];
	_restoreButton = [NSButton buttonWithTitle:@"Jetzt wiederherstellen"
	                                    target:self
	                                    action:@selector(restoreClicked:)];
	_savedLabel = [NSTextField labelWithString:@""];
	_savedLabel.textColor = NSColor.secondaryLabelColor;

	NSStackView *buttons = RRFormRow(@[ _saveButton, _restoreButton ]);
	NSStackView *top = RRFormColumn(@[
		RRFormHeadline(@"Arbeitsbereich"), explanation, _saveOnQuitCheckbox, _restoreCheckbox,
		buttons, _savedLabel
	]);
	[top setCustomSpacing:6 afterView:_saveOnQuitCheckbox];
	[top setCustomSpacing:20 afterView:_restoreCheckbox];
	[top setCustomSpacing:8 afterView:buttons];

	_table = [NSTableView new];
	_table.style = NSTableViewStyleFullWidth;
	_table.usesAlternatingRowBackgroundColors = YES;
	_table.allowsEmptySelection = YES;
	_table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
	_table.rowHeight = 22;
	_table.dataSource = self;
	_table.delegate = self;
	[self addColumn:RRColumnApp title:@"RemoteApp" width:180];
	[self addColumn:RRColumnServer title:@"Server" width:150];
	[self addColumn:RRColumnFrame title:@"Lage (Server-Pixel)" width:180];
	[self addColumn:RRColumnState title:@"Zustand" width:90];

	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, 240)];
	scroll.documentView = _table;
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = YES;
	scroll.borderType = NSBezelBorder;
	scroll.translatesAutoresizingMaskIntoConstraints = NO;

	NSView *page = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 820, 560)];
	[page addSubview:top];
	[page addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[top.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:28],
		[top.topAnchor constraintEqualToAnchor:page.topAnchor constant:24],
		[top.trailingAnchor constraintLessThanOrEqualToAnchor:page.trailingAnchor constant:-28],
		[scroll.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:28],
		[scroll.trailingAnchor constraintEqualToAnchor:page.trailingAnchor constant:-28],
		[scroll.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:16],
		[scroll.bottomAnchor constraintEqualToAnchor:page.bottomAnchor constant:-24],
		[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:120],
		[page.widthAnchor constraintGreaterThanOrEqualToConstant:760],
		[page.heightAnchor constraintGreaterThanOrEqualToConstant:480],
	]];
	self.view = page;

	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(configDidChange:)
	                                           name:RRConfigDidChangeNotification
	                                         object:nil];
	[self updateControls];
}

/* ---- Anzeige ----------------------------------------------------------------------------- */

- (void)updateControls
{
	RRWorkspaceConfig *workspace = [RRConfig shared].workspace;
	_items = workspace.items;

	_saveOnQuitCheckbox.state = workspace.saveOnQuit ? NSControlStateValueOn : NSControlStateValueOff;
	_restoreCheckbox.state = workspace.restoreFromLink ? NSControlStateValueOn : NSControlStateValueOff;
	_restoreButton.enabled = (_items.count > 0);

	NSDate *savedAt = workspace.savedAt;
	if (savedAt)
		_savedLabel.stringValue = [NSString
		    stringWithFormat:@"Gespeichert am %@ – %lu Fenster",
		                     [NSDateFormatter localizedStringFromDate:savedAt
		                                                    dateStyle:NSDateFormatterMediumStyle
		                                                    timeStyle:NSDateFormatterShortStyle],
		                     (unsigned long)_items.count];
	else
		_savedLabel.stringValue = @"Noch nichts gespeichert";

	[_table reloadData];
}

/* ---- Tabelle ----------------------------------------------------------------------------- */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return (NSInteger)_items.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (!tableColumn || (row < 0) || ((NSUInteger)row >= _items.count))
		return nil;

	NSUserInterfaceItemIdentifier identifier = tableColumn.identifier;
	NSTextField *label = [tableView makeViewWithIdentifier:identifier owner:self];
	if (!label)
	{
		label = [NSTextField labelWithString:@""];
		label.identifier = identifier;
		label.lineBreakMode = NSLineBreakByTruncatingTail;
	}

	RRWorkspaceItem *item = _items[(NSUInteger)row];
	RRAppConfig *app = [[RRConfig shared] appWithId:item.appId];

	if ([identifier isEqualToString:RRColumnApp])
		label.stringValue = app ? app.name : @"gelöscht";
	else if ([identifier isEqualToString:RRColumnServer])
	{
		RRServerConfig *server = app ? [[RRConfig shared] serverWithId:app.serverId] : nil;
		label.stringValue = server ? server.displayName : @"–";
	}
	else if ([identifier isEqualToString:RRColumnFrame])
	{
		const NSRect frame = item.serverRect;
		label.stringValue = [NSString stringWithFormat:@"%ld, %ld – %ld × %ld", (long)NSMinX(frame),
		                                               (long)NSMinY(frame), (long)NSWidth(frame),
		                                               (long)NSHeight(frame)];
	}
	else if ([identifier isEqualToString:RRColumnState])
		label.stringValue = item.maximized ? @"maximiert" : (item.minimized ? @"minimiert" : @"normal");
	return label;
}

/* ---- Aktionen ---------------------------------------------------------------------------- */

- (void)checkboxChanged:(id)sender
{
	RRWorkspaceConfig *workspace = [RRConfig shared].workspace;
	workspace.saveOnQuit = (_saveOnQuitCheckbox.state == NSControlStateValueOn);
	workspace.restoreFromLink = (_restoreCheckbox.state == NSControlStateValueOn);
	[[RRConfig shared] saveWorkspace:workspace];
}

- (void)saveClicked:(id)sender
{
	const NSUInteger count = [[RRConnectionManager shared] saveWorkspace];
	if (count == 0)
		RRFormShowAlert(self.view.window, @"Keine RemoteApp geöffnet.", nil, NSAlertStyleInformational);
	[self updateControls];
}

- (void)restoreClicked:(id)sender
{
	[[RRConnectionManager shared] restoreWorkspace];
}

/* ---- Benachrichtigungen ------------------------------------------------------------------ */

- (void)configDidChange:(NSNotification *)notification
{
	[self updateControls];
}

@end
