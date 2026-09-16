/*
 * rdp-retina – Anwendung und Delegates
 */
#import "RRApplication.h"
#import "RRConnectionManager.h"
#import "RRSession.h"
#import "RRSettingsWindowController.h"

@implementation RRApplication

- (void)sendEvent:(NSEvent *)event
{
	/* Solange Cmd gedrückt ist, stellt AppKit keyUp nicht zu. Ohne das bliebe z.B. "C"
	 * nach Cmd+C in der Sitzung hängen. */
	if ((event.type == NSEventTypeKeyUp) && (event.modifierFlags & NSEventModifierFlagCommand))
	{
		[self.keyWindow sendEvent:event];
		return;
	}
	[super sendEvent:event];
}

@end

/* ---- Kommandozeile ---------------------------------------------------------------------- */

@implementation RRAppDelegate
{
	RRSession *_session;
}

- (instancetype)initWithSession:(RRSession *)session
{
	self = [super init];
	if (self)
		_session = session;
	return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	if (![_session start])
	{
		fprintf(stderr, "rdp-retina: Start fehlgeschlagen\n");
		_session.exitCode = 1;
		[NSApp terminate:nil];
	}
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	[_session stop];
	return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	fflush(stdout);
	fflush(stderr);
	exit(_session.exitCode);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	/* RemoteApp-Fenster kommen und gehen; die Sitzung entscheidet über das Ende. */
	return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
	return YES;
}

@end

/* ---- Oberfläche ------------------------------------------------------------------------- */

static NSMenuItem *RRMenuItem(NSString *title, SEL _Nullable action, NSString *key,
                              NSEventModifierFlags modifiers)
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
	item.keyEquivalentModifierMask = modifiers;
	return item;
}

static NSMenuItem *RRSubmenu(NSMenu *menu)
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:menu.title action:NULL keyEquivalent:@""];
	item.submenu = menu;
	return item;
}

/* Menüleiste ohne Nib. In einem RemoteApp-Fenster gehen Befehlstasten an Windows
 * (RRMetalView performKeyEquivalent:), die Menüs gelten für das Hauptfenster. */
static NSMenu *RRMainMenu(id target)
{
	const NSEventModifierFlags command = NSEventModifierFlagCommand;
	NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];

	NSMenu *app = [[NSMenu alloc] initWithTitle:@"rdp-retina"];
	[app addItem:RRMenuItem(@"Über rdp-retina", @selector(orderFrontStandardAboutPanel:), @"", 0)];
	[app addItem:NSMenuItem.separatorItem];
	NSMenuItem *settings = RRMenuItem(@"Einstellungen …", @selector(showSettings:), @",", command);
	settings.target = target;
	[app addItem:settings];
	[app addItem:NSMenuItem.separatorItem];
	NSMenu *services = [[NSMenu alloc] initWithTitle:@"Dienste"];
	[app addItem:RRSubmenu(services)];
	NSApp.servicesMenu = services;
	[app addItem:NSMenuItem.separatorItem];
	[app addItem:RRMenuItem(@"rdp-retina ausblenden", @selector(hide:), @"h", command)];
	[app addItem:RRMenuItem(@"Andere ausblenden", @selector(hideOtherApplications:), @"h",
	                        command | NSEventModifierFlagOption)];
	[app addItem:RRMenuItem(@"Alle einblenden", @selector(unhideAllApplications:), @"", 0)];
	[app addItem:NSMenuItem.separatorItem];
	[app addItem:RRMenuItem(@"rdp-retina beenden", @selector(terminate:), @"q", command)];
	[bar addItem:RRSubmenu(app)];

	NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Bearbeiten"];
	/* undo:/redo: behandelt die Responder-Kette (Textfelder); in keinem öffentlichen Header deklariert */
	[edit addItem:RRMenuItem(@"Widerrufen", NSSelectorFromString(@"undo:"), @"z", command)];
	[edit addItem:RRMenuItem(@"Wiederholen", NSSelectorFromString(@"redo:"), @"z",
	                         command | NSEventModifierFlagShift)];
	[edit addItem:NSMenuItem.separatorItem];
	[edit addItem:RRMenuItem(@"Ausschneiden", @selector(cut:), @"x", command)];
	[edit addItem:RRMenuItem(@"Kopieren", @selector(copy:), @"c", command)];
	[edit addItem:RRMenuItem(@"Einsetzen", @selector(paste:), @"v", command)];
	[edit addItem:RRMenuItem(@"Löschen", @selector(delete:), @"", 0)];
	[edit addItem:RRMenuItem(@"Alles auswählen", @selector(selectAll:), @"a", command)];
	[bar addItem:RRSubmenu(edit)];

	NSMenu *window = [[NSMenu alloc] initWithTitle:@"Fenster"];
	[window addItem:RRMenuItem(@"Im Dock ablegen", @selector(performMiniaturize:), @"m", command)];
	[window addItem:RRMenuItem(@"Zoomen", @selector(performZoom:), @"", 0)];
	[window addItem:NSMenuItem.separatorItem];
	[window addItem:RRMenuItem(@"Schließen", @selector(performClose:), @"w", command)];
	[window addItem:NSMenuItem.separatorItem];
	[window addItem:RRMenuItem(@"Alle nach vorne bringen", @selector(arrangeInFront:), @"", 0)];
	[bar addItem:RRSubmenu(window)];
	NSApp.windowsMenu = window;

	return bar;
}

@implementation RRUIAppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
	NSApp.mainMenu = RRMainMenu(self);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	/* Über eine Verknüpfung gestartet: nur die RemoteApp, kein Einstellungsfenster. */
	NSNumber *isDefault = notification.userInfo[NSApplicationLaunchIsDefaultLaunchKey];
	if (!isDefault || isDefault.boolValue)
		[[RRSettingsWindowController shared] showAndActivate];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls
{
	BOOL handled = NO;
	for (NSURL *url in urls)
		handled = [[RRConnectionManager shared] handleURL:url] || handled;

	/* rdp-retina://open ohne RemoteApp: die Oberfläche zeigen */
	if (!handled)
		[[RRSettingsWindowController shared] showAndActivate];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag
{
	if (!flag)
		[[RRSettingsWindowController shared] showAndActivate];
	return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	[[RRConnectionManager shared] shutdown];
	return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	/* Sitzungen laufen ohne Einstellungsfenster weiter. */
	return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
	return YES;
}

- (IBAction)showSettings:(id)sender
{
	[[RRSettingsWindowController shared] showAndActivate];
}

@end
