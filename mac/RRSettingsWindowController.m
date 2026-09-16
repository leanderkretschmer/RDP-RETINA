/*
 * rdp-retina – Hauptfenster der Oberfläche
 *
 * Ein NSTabViewController im Symbolleisten-Stil; jeder Bereich hat seinen eigenen Controller
 * (RRSettings*ViewController). Größe, Lage und gewählter Bereich bleiben über Neustarts erhalten.
 */
#import "RRSettingsWindowController.h"
#import "RRSettingsAppsViewController.h"
#import "RRSettingsServersViewController.h"
#import "RRSettingsTransferViewController.h"
#import "RRSettingsWorkspaceViewController.h"

static NSString *const RRSettingsTabKey = @"RRSettingsSelectedTab";
static NSWindowFrameAutosaveName const RRSettingsFrameName = @"RRSettingsWindow";
static const NSSize RRSettingsDefaultSize = { 820, 560 };

/* Merkt sich den gewählten Bereich */
@interface RRSettingsTabViewController : NSTabViewController
@end

@implementation RRSettingsTabViewController

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem
{
	[super tabView:tabView didSelectTabViewItem:tabViewItem];

	id identifier = tabViewItem.identifier;
	if ([identifier isKindOfClass:NSString.class])
		[NSUserDefaults.standardUserDefaults setObject:identifier forKey:RRSettingsTabKey];
}

@end

@interface RRSettingsWindowController () <NSWindowDelegate>
- (void)setUp;
@end

@implementation RRSettingsWindowController
{
	RRSettingsTabViewController *_tabs;
}

+ (RRSettingsWindowController *)shared
{
	static RRSettingsWindowController *shared;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		NSWindow *window = [[NSWindow alloc]
		    initWithContentRect:NSMakeRect(0, 0, RRSettingsDefaultSize.width, RRSettingsDefaultSize.height)
		              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
		                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
		                backing:NSBackingStoreBuffered
		                  defer:YES];
		shared = [[RRSettingsWindowController alloc] initWithWindow:window];
		[shared setUp];
	});
	return shared;
}

- (void)setUp
{
	NSWindow *window = self.window;
	window.title = @"rdp-retina";
	window.releasedWhenClosed = NO;
	window.toolbarStyle = NSWindowToolbarStylePreference;
	window.contentMinSize = NSMakeSize(760, 500);
	window.delegate = self;

	_tabs = [RRSettingsTabViewController new];
	_tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
	_tabs.transitionOptions = NSViewControllerTransitionNone;
	_tabs.canPropagateSelectedChildViewControllerTitle = NO;

	[self addTab:[RRSettingsServersViewController new]
	    identifier:@"server"
	         label:@"Server"
	        symbol:@"server.rack"];
	[self addTab:[RRSettingsAppsViewController new]
	    identifier:@"apps"
	         label:@"RemoteApps"
	        symbol:@"square.grid.2x2"];
	[self addTab:[RRSettingsTransferViewController new]
	    identifier:@"transfer"
	         label:@"Übertragung"
	        symbol:@"arrow.left.arrow.right"];
	[self addTab:[RRSettingsWorkspaceViewController new]
	    identifier:@"workspace"
	         label:@"Arbeitsbereich"
	        symbol:@"rectangle.3.group"];

	NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:RRSettingsTabKey];
	window.contentViewController = _tabs;
	if (saved)
	{
		const NSInteger index = [_tabs.tabView indexOfTabViewItemWithIdentifier:saved];
		if (index != NSNotFound)
			_tabs.selectedTabViewItemIndex = index;
	}

	if (![window setFrameUsingName:RRSettingsFrameName])
	{
		[window setContentSize:RRSettingsDefaultSize];
		[window center];
	}
	[window setFrameAutosaveName:RRSettingsFrameName];
	[self updatePreferredContentSize];
}

- (void)addTab:(NSViewController *)controller
    identifier:(NSString *)identifier
         label:(NSString *)label
        symbol:(NSString *)symbol
{
	controller.preferredContentSize = RRSettingsDefaultSize;

	NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:identifier];
	item.label = label;
	item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
	item.viewController = controller;
	[_tabs addTabViewItem:item];
}

/* Die Tab-Ansicht bringt das Fenster beim Wechsel auf die bevorzugte Größe der Seite. Damit ein
 * Wechsel die vom Benutzer gewählte Größe behält, bekommen alle Seiten die aktuelle. */
- (void)updatePreferredContentSize
{
	const NSSize size = self.window.contentView.frame.size;
	if ((size.width <= 0) || (size.height <= 0))
		return;

	for (NSTabViewItem *item in _tabs.tabViewItems)
		item.viewController.preferredContentSize = size;
}

- (void)windowDidResize:(NSNotification *)notification
{
	[self updatePreferredContentSize];
}

- (void)showAndActivate
{
	[self showWindow:nil];
	[self.window makeKeyAndOrderFront:nil];

	if (@available(macOS 14.0, *))
		[NSApp activate];
	else
	{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		[NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
	}
}

@end
