/*
 * rdp-retina – Anwendung und Delegate
 */
#import "RRApplication.h"
#import "RRSession.h"

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

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
	[_session appDidBecomeActive];
}

- (void)applicationDidResignActive:(NSNotification *)notification
{
	[_session appDidResignActive];
}

@end
