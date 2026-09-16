/*
 * RDP-Retina Link – Verknüpfung auf eine RemoteApp
 *
 * rdp-retina bringt diese kleine App als Vorlage mit (Contents/Helpers) und legt für jede
 * Verknüpfung eine Kopie an (mac/RRLinkInstaller.m): umbenannt, mit eigenem Symbol und der ID der
 * RemoteApp im erweiterten Attribut com.cratchmere.rdp-retina.app. Die Signatur bleibt dabei
 * unverändert gültig.
 *
 * Gestartet ruft die Kopie rdp-retina://open?app=<ID> auf und beendet sich gleich wieder;
 * rdp-retina startet die RemoteApp in der bestehenden Sitzung. Ohne Attribut – die unveränderte
 * Vorlage – öffnet sie nur rdp-retina.
 */
#import <AppKit/AppKit.h>

#include <sys/xattr.h>

/* wie RRLinkAppAttribute in mac/RRLinkInstaller.m */
static NSString *const RRLinkAppAttribute = @"com.cratchmere.rdp-retina.app";
static const NSTimeInterval RRLinkTimeout = 15.0;

/* ID der RemoteApp am eigenen Bundle, nil = keine */
static NSString *RRLinkAppId(void)
{
	const char *path = NSBundle.mainBundle.bundlePath.fileSystemRepresentation;
	char value[512];

	const ssize_t size = getxattr(path, RRLinkAppAttribute.UTF8String, value, sizeof(value), 0, 0);
	if (size <= 0)
		return nil;
	return [[NSString alloc] initWithBytes:value
	                                length:(NSUInteger)size
	                              encoding:NSUTF8StringEncoding];
}

static NSURL *RRLinkURL(NSString *identifier)
{
	NSURLComponents *components = [NSURLComponents new];
	components.scheme = @"rdp-retina";
	components.host = @"open";
	if (identifier.length > 0)
		components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"app" value:identifier] ];
	return components.URL;
}

static void RRLinkShowError(NSString *detail)
{
	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
	if (@available(macOS 14.0, *))
		[NSApp activate];
	else
		[NSApp activateIgnoringOtherApps:YES];

	NSAlert *alert = [NSAlert new];
	alert.messageText = @"rdp-retina ist nicht installiert";
	alert.informativeText = detail;
	[alert runModal];
}

int main(int argc, const char *argv[])
{
	@autoreleasepool
	{
		NSURL *url = RRLinkURL(RRLinkAppId());
		if (!url)
			return 1;

		NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
		configuration.activates = YES;

		/* Die Antwort kommt auf einer beliebigen Queue; über die Hauptqueue zurückmelden und
		 * solange die Run Loop drehen – so hängt nichts, egal wo Launch Services antwortet. */
		__block BOOL finished = NO;
		__block NSError *failure = nil;
		[NSWorkspace.sharedWorkspace openURL:url
		                       configuration:configuration
		                   completionHandler:^(NSRunningApplication *app, NSError *error) {
			                   dispatch_async(dispatch_get_main_queue(), ^{
				                   failure = error;
				                   finished = YES;
			                   });
		                   }];

		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:RRLinkTimeout];
		while (!finished && (deadline.timeIntervalSinceNow > 0))
			[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
			                       beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

		if (finished && !failure)
			return 0;

		NSString *detail = failure.localizedDescription;
		if (detail.length == 0)
			detail = @"Die Verknüpfung konnte rdp-retina nicht öffnen. Bitte rdp-retina aus dem "
			         @"App Store installieren und die Verknüpfung dort neu anlegen.";
		RRLinkShowError(detail);
		return 1;
	}
}
