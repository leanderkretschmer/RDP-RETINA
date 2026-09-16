/*
 * rdp-retina – Verknüpfungen (Companion-Apps) für RemoteApps
 *
 * Ablauf siehe RRLinkInstaller.h. In der App Sandbox braucht das zwei Berechtigungen
 * (mac/rdp-retina.entitlements):
 *   com.apple.security.files.user-selected.read-write  den Ort aus dem Sicherungsdialog beschreiben
 *   com.apple.security.files.user-selected.executable  die Kopie ist ein Programm; ohne diese
 *                                                       Berechtigung versieht die Sandbox sie mit
 *                                                       dem Quarantäne-Attribut, und Gatekeeper
 *                                                       verweigert den Start
 */
#import "RRLinkInstaller.h"
#import "RRConfig.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <errno.h>
#include <pwd.h>
#include <string.h>
#include <sys/xattr.h>
#include <unistd.h>

NSString *const RRLinkURLScheme = @"rdp-retina";
NSString *const RRLinkAppAttribute = @"com.cratchmere.rdp-retina.app";

/* Muss zum Schritt „Verknüpfungsvorlage“ in scripts/gen-xcodeproj.py passen. */
static NSString *const RRLinkTemplatePath = @"Contents/Helpers/RDP-Retina Link.app";
static const NSInteger RRLinkIconPixels = 1024;

/* ---- Symbol ---------------------------------------------------------------------------- */

/* size seitenrichtig in bounds einpassen, mittig */
static NSRect RRLinkFitRect(NSSize size, NSRect bounds)
{
	if ((size.width <= 0) || (size.height <= 0))
		return bounds;

	const CGFloat factor = MIN(bounds.size.width / size.width, bounds.size.height / size.height);
	const CGFloat width = size.width * factor;
	const CGFloat height = size.height * factor;
	return NSMakeRect(NSMinX(bounds) + (bounds.size.width - width) / 2.0,
	                  NSMinY(bounds) + (bounds.size.height - height) / 2.0, width, height);
}

NSImage *RRLinkBadgedIcon(NSImage *image)
{
	const CGFloat pixels = (CGFloat)RRLinkIconPixels;
	const NSRect canvas = NSMakeRect(0, 0, pixels, pixels);

	/* Das Symbol aus dem Bundle, nicht NSApp.applicationIconImage – das ersetzt die
	 * Fensterverwaltung zur Laufzeit durch das Symbol einer Windows-Anwendung. */
	NSImage *appIcon = [NSWorkspace.sharedWorkspace iconForFile:NSBundle.mainBundle.bundlePath];

	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
	                                                               pixelsWide:RRLinkIconPixels
	                                                               pixelsHigh:RRLinkIconPixels
	                                                            bitsPerSample:8
	                                                          samplesPerPixel:4
	                                                                 hasAlpha:YES
	                                                                 isPlanar:NO
	                                                           colorSpaceName:NSDeviceRGBColorSpace
	                                                              bytesPerRow:0
	                                                             bitsPerPixel:0];
	if (!rep)
		return image ?: appIcon;
	rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace] ?: rep;

	NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
	if (!context)
		return image ?: appIcon;

	[NSGraphicsContext saveGraphicsState];
	NSGraphicsContext.currentContext = context;
	context.imageInterpolation = NSImageInterpolationHigh;

	if (image)
	{
		[image drawInRect:RRLinkFitRect(image.size, canvas)
		         fromRect:NSZeroRect
		        operation:NSCompositingOperationSourceOver
		         fraction:1.0];

		/* unten rechts, gut 40 % der Kantenlänge, mit leichtem Schatten */
		const CGFloat side = round(pixels * 0.42);
		const CGFloat margin = round(pixels * 0.02);
		const NSRect badge =
		    NSMakeRect(NSMaxX(canvas) - side - margin, NSMinY(canvas) + margin, side, side);

		NSShadow *shadow = [NSShadow new];
		shadow.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.35];
		shadow.shadowBlurRadius = round(pixels * 0.012);
		shadow.shadowOffset = NSMakeSize(0.0, -round(pixels * 0.004));

		[NSGraphicsContext saveGraphicsState];
		[shadow set];
		[appIcon drawInRect:badge
		           fromRect:NSZeroRect
		          operation:NSCompositingOperationSourceOver
		           fraction:1.0];
		[NSGraphicsContext restoreGraphicsState];
	}
	else
	{
		[appIcon drawInRect:canvas
		           fromRect:NSZeroRect
		          operation:NSCompositingOperationSourceOver
		           fraction:1.0];
	}

	[context flushGraphics];
	[NSGraphicsContext restoreGraphicsState];

	/* 1024 Pixel als 512 Punkte: scharf bis zur größten Darstellung im Finder */
	rep.size = NSMakeSize(pixels / 2.0, pixels / 2.0);
	NSImage *result = [[NSImage alloc] initWithSize:rep.size];
	[result addRepresentation:rep];
	return result;
}

/* ---- Hilfen ---------------------------------------------------------------------------- */

static BOOL RRLinkFail(NSError **error, NSString *text)
{
	if (error)
		*error = [NSError errorWithDomain:@"rdp-retina"
		                             code:1
		                         userInfo:@{ NSLocalizedDescriptionKey : text }];
	return NO;
}

/* Dateiname der Verknüpfung: / und : gehen im Dateisystem nicht. */
static NSString *RRLinkFileName(NSString *name)
{
	NSString *trimmed =
	    [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSString *safe = [[trimmed stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
	    stringByReplacingOccurrencesOfString:@":"
	                              withString:@"-"];
	return (safe.length > 0) ? safe : @"RemoteApp";
}

/* ~/Applications des Benutzers. NSHomeDirectory() zeigt in der App Sandbox in den Container;
 * der Sicherungsdialog läuft außerhalb der Sandbox und soll den echten Ordner anbieten. */
static NSURL *RRLinkDefaultDirectory(void)
{
	NSString *home = nil;
	const struct passwd *entry = getpwuid(getuid());

	if (entry && entry->pw_dir)
		home = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->pw_dir
		                                                                 length:strlen(entry->pw_dir)];
	if (home.length == 0)
		home = NSHomeDirectory();
	NSString *applications = [home stringByAppendingPathComponent:@"Applications"];
	return [NSURL fileURLWithPath:applications isDirectory:YES];
}

/* ID der RemoteApp am Bundle, nil = keine Verknüpfung von rdp-retina */
static NSString *RRLinkReadAppId(NSURL *url)
{
	const char *path = url.fileSystemRepresentation;
	const char *name = RRLinkAppAttribute.UTF8String;

	const ssize_t size = getxattr(path, name, NULL, 0, 0, 0);
	if ((size <= 0) || (size > 4096))
		return nil;

	NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
	const ssize_t read = getxattr(path, name, data.mutableBytes, (size_t)size, 0, 0);
	if (read <= 0)
		return nil;
	data.length = (NSUInteger)read;
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

/* Vorlage nach target kopieren, kennzeichnen und mit Symbol versehen. */
static BOOL RRLinkWrite(NSURL *template, NSURL *target, NSString *identifier, NSImage *icon,
                        NSError **error)
{
	NSFileManager *fm = NSFileManager.defaultManager;

	if ([fm fileExistsAtPath:target.path])
	{
		/* Nur eigene Verknüpfungen ersetzen, nie ein fremdes Programm. */
		if (!RRLinkReadAppId(target))
			return RRLinkFail(error, [NSString stringWithFormat:@"„%@“ gibt es schon und ist keine "
			                                                    @"Verknüpfung von rdp-retina.",
			                                                    target.lastPathComponent]);
		if (![fm removeItemAtURL:target error:error])
			return NO;
	}

	if (![fm copyItemAtURL:template toURL:target error:error])
		return NO;

	NSData *value = [identifier dataUsingEncoding:NSUTF8StringEncoding];
	if (!value || (setxattr(target.fileSystemRepresentation, RRLinkAppAttribute.UTF8String,
	                        value.bytes, value.length, 0, 0) != 0))
	{
		const int code = errno;
		[fm removeItemAtURL:target error:NULL];
		return RRLinkFail(error, [NSString stringWithFormat:@"Die Verknüpfung ließ sich nicht "
		                                                    @"kennzeichnen (%s).",
		                                                    strerror(code)]);
	}

	/* Ohne Symbol funktioniert die Verknüpfung trotzdem, sie zeigt dann das der Vorlage. */
	if (![NSWorkspace.sharedWorkspace setIcon:icon forFile:target.path options:0])
		fprintf(stderr, "rdp-retina: Symbol für %s nicht gesetzt\n", target.path.UTF8String);
	return YES;
}

/* ---- RRLinkInstaller ------------------------------------------------------------------- */

@implementation RRLinkInstaller

+ (NSURL *)URLForAppId:(NSString *)identifier
{
	NSURLComponents *components = [NSURLComponents new];
	components.scheme = RRLinkURLScheme;
	components.host = @"open";
	components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"app" value:identifier] ];

	NSURL *url = components.URL;
	return url ?: [NSURL URLWithString:@"rdp-retina://open"];
}

+ (NSString *)appIdFromURL:(NSURL *)url
{
	if (!url.scheme || ([url.scheme caseInsensitiveCompare:RRLinkURLScheme] != NSOrderedSame))
		return nil;

	NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
	if (!components.host || ([components.host caseInsensitiveCompare:@"open"] != NSOrderedSame))
		return nil;

	for (NSURLQueryItem *item in components.queryItems)
	{
		if ([item.name isEqualToString:@"app"] && (item.value.length > 0))
			return item.value;
	}
	return nil;
}

+ (void)installLinkForApp:(RRAppConfig *)app
                     icon:(NSImage *)icon
                   window:(NSWindow *)window
               completion:(void (^)(NSURL *link, NSError *error))completion
{
	NSURL *template = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:RRLinkTemplatePath
	                                                                 isDirectory:YES];
	if (![NSFileManager.defaultManager fileExistsAtPath:template.path])
	{
		NSError *error = nil;
		(void)RRLinkFail(&error, @"Die Vorlage für Verknüpfungen fehlt – rdp-retina bitte neu "
		                         @"installieren.");
		completion(nil, error);
		return;
	}

	NSString *name = RRLinkFileName(app.name);
	NSString *identifier = [app.identifier copy];
	NSImage *badged = RRLinkBadgedIcon(icon);

	NSSavePanel *panel = [NSSavePanel savePanel];
	panel.title = @"Verknüpfung installieren";
	panel.message = [NSString stringWithFormat:@"Verknüpfung für „%@“ anlegen", name];
	panel.prompt = @"Anlegen";
	panel.nameFieldStringValue = [name stringByAppendingPathExtension:@"app"];
	panel.allowedContentTypes = @[ UTTypeApplicationBundle ];
	panel.canCreateDirectories = YES;
	panel.directoryURL = RRLinkDefaultDirectory();

	[panel beginSheetModalForWindow:window
	              completionHandler:^(NSModalResponse response) {
		              NSURL *chosen = panel.URL;
		              if ((response != NSModalResponseOK) || !chosen)
		              {
			              completion(nil, nil);
			              return;
		              }

		              NSURL *target = chosen;
		              if ([target.pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame)
			              target = [target URLByAppendingPathExtension:@"app"];

		              NSError *error = nil;
		              const BOOL scoped = [chosen startAccessingSecurityScopedResource];
		              const BOOL written = RRLinkWrite(template, target, identifier, badged, &error);
		              if (scoped)
			              [chosen stopAccessingSecurityScopedResource];

		              if (!written)
		              {
			              if (!error)
				              (void)RRLinkFail(&error, @"Die Verknüpfung ließ sich nicht anlegen.");
			              completion(nil, error);
			              return;
		              }

		              [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ target ]];
		              completion(target, nil);
	              }];
}

@end
