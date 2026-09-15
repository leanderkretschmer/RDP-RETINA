/*
 * rdp-retina – Applets für das Dock
 *
 * --createapp prüft die Argumente mit FreeRDPs eigenem Parser, legt daraus ein App-Bundle an
 * und trägt es ins Dock ein. Das Kennwort wandert in den Schlüsselbund (RRCredentials), im
 * Bundle steht es nie. Gestartet wird über "open -b com.cratchmere.rdp-retina": läuft bereits
 * eine Verbindung zu diesem Server und Benutzer, übernimmt sie das Programm. Dafür reicht das
 * Applet /v:, /u: und alle übrigen Angaben unverändert weiter.
 */
#import "RRApplet.h"
#import "RRCredentials.h"

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>

#include <freerdp/settings.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>

static NSString *const RRAppletClientId = @"com.cratchmere.rdp-retina";
static NSString *const RRAppletMarker = @"RRApplet";
static NSString *const RRAppletExecutable = @"rdp-retina-applet";
static NSString *const RRAppletIcon = @"applet";

/* ---- Kleinkram ------------------------------------------------------------------------- */

static BOOL RRFail(NSError **error, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

static BOOL RRFail(NSError **error, NSString *format, ...)
{
	if (error)
	{
		va_list list;
		va_start(list, format);
		NSString *text = [[NSString alloc] initWithFormat:format arguments:list];
		va_end(list);
		*error = [NSError errorWithDomain:@"rdp-retina"
		                             code:1
		                         userInfo:@{ NSLocalizedDescriptionKey : text }];
	}
	return NO;
}

static const char *RRErrorText(NSError *error)
{
	return error.localizedDescription.UTF8String ?: "unbekannter Fehler";
}

static void RRUsage(void)
{
	fprintf(stderr,
	        "rdp-retina --createapp: legt ein Applet für eine RemoteApp an.\n"
	        "\n"
	        "  rdp-retina --createapp /v:<server> /u:<benutzer> [/p:<kennwort>] \\\n"
	        "             /app:<programm oder pfad> [--appname=<name>] [--icon=<datei|url>]\n"
	        "             [--nodock] [--dest=<ordner>]\n"
	        "\n"
	        "Pflicht sind /v: und /app:. Alle weiteren Argumente (z.B. /multimon, /scale:180)\n"
	        "landen unverändert im Applet, nur /p: nicht: das Kennwort kommt in den\n"
	        "Schlüsselbund. Ohne eigenes /cert: bekommt das Applet /cert:tofu, weil es keine\n"
	        "Rückfrage im Terminal stellen kann.\n");
}

/* Argumentname ohne führende /, - oder + */
static NSString *RRArgumentBody(NSString *arg)
{
	NSUInteger i = 0;

	while (i < arg.length)
	{
		const unichar c = [arg characterAtIndex:i];
		if ((c != '/') && (c != '-') && (c != '+'))
			break;
		i++;
	}
	return [arg substringFromIndex:i];
}

/* Für sh in einfache Anführungszeichen: darin ist nur ' selbst besonders. */
static NSString *RRShellQuote(NSString *value)
{
	NSString *escaped = [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
	return [NSString stringWithFormat:@"'%@'", escaped];
}

static int RRRun(NSString *tool, NSArray<NSString *> *arguments)
{
	NSTask *task = [NSTask new];

	task.executableURL = [NSURL fileURLWithPath:tool];
	task.arguments = arguments;
	task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
	task.standardError = NSFileHandle.fileHandleWithNullDevice;

	if (![task launchAndReturnError:NULL])
		return -1;
	[task waitUntilExit];
	return task.terminationStatus;
}

/* ---- Argumente ------------------------------------------------------------------------ */

/* Unteroptionen von /app: in FreeRDP. Fehlt eine davon, ist die Angabe das Programm selbst. */
static NSArray<NSString *> *RRAppKeys(void)
{
	return @[
		@"program:", @"workdir:", @"name:", @"icon:", @"cmd:", @"file:", @"guid:", @"hidef:"
	];
}

/* Prüft die Argumente mit FreeRDP und liefert die fertigen Einstellungen. */
static rdpSettings *RRParseArguments(NSArray<NSString *> *arguments, NSString *password)
{
	NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:@"rdp-retina"];

	for (NSString *argument in arguments)
	{
		/* Eigene Schalter kennt FreeRDP nicht; sie wandern ungeprüft ins Applet. */
		if (![RRArgumentBody(argument) hasPrefix:@"retina-"])
			[all addObject:argument];
	}
	if (password.length > 0)
		[all addObject:[@"/p:" stringByAppendingString:password]];

	char **argv = calloc(all.count + 1, sizeof(char *));
	if (!argv)
		return NULL;

	int count = 0;
	for (NSString *argument in all)
	{
		argv[count] = strdup(argument.UTF8String);
		if (!argv[count])
			break;
		count++;
	}

	rdpSettings *settings = freerdp_settings_new(0);
	int status = -1;
	if (settings && (count == (int)all.count))
		status = freerdp_client_settings_parse_command_line(settings, count, argv, NO);

	if (status != 0)
	{
		if (settings)
			(void)freerdp_client_settings_command_line_status_print(settings, status, count, argv);
		freerdp_settings_free(settings);
		settings = NULL;
	}

	for (int i = 0; i < count; i++)
		free(argv[i]);
	free(argv);
	return settings;
}

static NSString *RRNameFromProgram(NSString *program)
{
	NSString *value = program;

	if ([value hasPrefix:@"||"])
		value = [value substringFromIndex:2];
	value = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
	value = value.lastPathComponent;
	if ([value.pathExtension caseInsensitiveCompare:@"exe"] == NSOrderedSame)
		value = value.stringByDeletingPathExtension;
	value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	return (value.length > 0) ? value : @"RemoteApp";
}

/* Dateiname: / und : gehen im Dateisystem nicht. */
static NSString *RRSafeName(NSString *name)
{
	NSMutableString *out = [NSMutableString new];

	for (NSUInteger i = 0; i < name.length; i++)
	{
		const unichar c = [name characterAtIndex:i];
		if ((c == '/') || (c == ':'))
			[out appendString:@"-"];
		else
			[out appendString:[NSString stringWithCharacters:&c length:1]];
	}
	return out;
}

/* Bundle-Kennungen dürfen nur Buchstaben, Ziffern, Punkt und Bindestrich enthalten. */
static NSString *RRIdentifierPart(NSString *name)
{
	NSString *lower = name.lowercaseString;
	NSMutableString *out = [NSMutableString new];

	for (NSUInteger i = 0; i < lower.length; i++)
	{
		const unichar c = [lower characterAtIndex:i];
		if (((c >= 'a') && (c <= 'z')) || ((c >= '0') && (c <= '9')))
			[out appendString:[NSString stringWithCharacters:&c length:1]];
		else if ((out.length > 0) && ![out hasSuffix:@"-"])
			[out appendString:@"-"];
	}
	while ([out hasSuffix:@"-"])
		[out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
	return (out.length > 0) ? out : @"applet";
}

/* ---- Symbol --------------------------------------------------------------------------- */

/* Nach der Create-Regel: der Aufrufer gibt das Bild frei. */
static CGImageRef RRCreateIconImage(NSImage *image, size_t pixels)
{
	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx =
	    CGBitmapContextCreate(NULL, pixels, pixels, 8, 0, space,
	                          kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);

	CGColorSpaceRelease(space);
	if (!ctx)
		return NULL;

	CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
	NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
	[NSGraphicsContext saveGraphicsState];
	NSGraphicsContext.currentContext = gc;

	/* Seitenverhältnis behalten, mittig einpassen. */
	const NSSize size = image.size;
	NSRect target = NSMakeRect(0, 0, (CGFloat)pixels, (CGFloat)pixels);
	if ((size.width > 0) && (size.height > 0))
	{
		const CGFloat factor = MIN(pixels / size.width, pixels / size.height);
		const CGFloat width = size.width * factor;
		const CGFloat height = size.height * factor;
		target = NSMakeRect((pixels - width) / 2.0, (pixels - height) / 2.0, width, height);
	}
	[image drawInRect:target
	         fromRect:NSZeroRect
	        operation:NSCompositingOperationSourceOver
	         fraction:1.0];

	[NSGraphicsContext restoreGraphicsState];
	CGImageRef cg = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);
	return cg;
}

static BOOL RRWriteIcns(NSImage *image, NSURL *icns)
{
	/* Jede Pixelgröße einmal: für 16 pt @2x nimmt macOS die 32-Pixel-Fassung usw. */
	static const size_t sizes[] = { 16, 32, 64, 128, 256, 512, 1024 };
	const size_t count = sizeof(sizes) / sizeof(sizes[0]);

	CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
	    (__bridge CFURLRef)icns, (__bridge CFStringRef) @"com.apple.icns", count, NULL);
	if (!dest)
		return NO;

	size_t written = 0;
	for (size_t i = 0; i < count; i++)
	{
		CGImageRef cg = RRCreateIconImage(image, sizes[i]);
		if (!cg)
			continue;
		CGImageDestinationAddImage(dest, cg, NULL);
		CGImageRelease(cg);
		written++;
	}

	const BOOL ok = (written == count) && CGImageDestinationFinalize(dest);
	CFRelease(dest);
	return ok;
}

/* Rückfall, falls ImageIO die .icns nicht schreibt: PNGs in einem .iconset und iconutil. */
static BOOL RRWriteIcnsViaIconutil(NSImage *image, NSURL *icns)
{
	NSString *folder = [NSString stringWithFormat:@"rdp-retina-%08x.iconset", arc4random()];
	NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:folder]
	                        isDirectory:YES];
	static const struct
	{
		size_t points;
		size_t factor;
	} sizes[] = { { 16, 1 },  { 16, 2 },  { 32, 1 },  { 32, 2 },  { 128, 1 },
		          { 128, 2 }, { 256, 1 }, { 256, 2 }, { 512, 1 }, { 512, 2 } };

	if (![NSFileManager.defaultManager createDirectoryAtURL:dir
	                           withIntermediateDirectories:YES
	                                            attributes:nil
	                                                 error:NULL])
		return NO;

	BOOL ok = YES;
	for (size_t i = 0; ok && (i < sizeof(sizes) / sizeof(sizes[0])); i++)
	{
		CGImageRef cg = RRCreateIconImage(image, sizes[i].points * sizes[i].factor);
		if (!cg)
		{
			ok = NO;
			break;
		}

		NSString *file = (sizes[i].factor == 1)
		                     ? [NSString stringWithFormat:@"icon_%zux%zu.png", sizes[i].points,
		                                                  sizes[i].points]
		                     : [NSString stringWithFormat:@"icon_%zux%zu@2x.png", sizes[i].points,
		                                                  sizes[i].points];
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
		NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
		CGImageRelease(cg);
		ok = (png != nil) && [png writeToURL:[dir URLByAppendingPathComponent:file] atomically:YES];
	}

	if (ok)
		ok = (RRRun(@"/usr/bin/iconutil", @[ @"-c", @"icns", @"-o", icns.path, dir.path ]) == 0);
	[NSFileManager.defaultManager removeItemAtURL:dir error:NULL];
	return ok;
}

static NSData *RRDownload(NSURL *url, NSError **error)
{
	__block NSData *result = nil;
	__block NSError *failure = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);

	NSURLSessionDataTask *task = [NSURLSession.sharedSession
	      dataTaskWithURL:url
	    completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
		    NSHTTPURLResponse *http =
		        [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
		    if (http && ((http.statusCode < 200) || (http.statusCode > 299)))
		    {
			    NSString *text = [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
			    failure = [NSError errorWithDomain:@"rdp-retina"
			                                  code:http.statusCode
			                              userInfo:@{ NSLocalizedDescriptionKey : text }];
		    }
		    else
		    {
			    result = data;
			    failure = taskError;
		    }
		    dispatch_semaphore_signal(done);
	    }];
	[task resume];

	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
	                                                (int64_t)(30 * NSEC_PER_SEC))) != 0)
	{
		[task cancel];
		(void)RRFail(error, @"Symbol ließ sich nicht laden: Zeitüberschreitung");
		return nil;
	}

	if (!result)
	{
		if (failure && error)
			*error = failure;
		else
			(void)RRFail(error, @"Symbol ließ sich nicht laden");
		return nil;
	}
	return result;
}

static NSImage *RRLoadIcon(NSString *source, NSError **error)
{
	NSData *data = nil;

	if ([source hasPrefix:@"http://"] || [source hasPrefix:@"https://"])
	{
		NSURL *url = [NSURL URLWithString:source];
		if (!url)
		{
			(void)RRFail(error, @"Adresse für das Symbol unverständlich: %@", source);
			return nil;
		}
		data = RRDownload(url, error);
	}
	else
		data = [NSData dataWithContentsOfFile:source.stringByExpandingTildeInPath
		                             options:0
		                               error:error];

	if (!data)
		return nil;

	NSImage *image = [[NSImage alloc] initWithData:data];
	if (!image || (image.size.width <= 0) || (image.size.height <= 0))
	{
		(void)RRFail(error, @"Symbol ließ sich nicht lesen (PNG, JPEG, ICNS oder PDF)");
		return nil;
	}
	return image;
}

/* Ohne --icon das Symbol von rdp-retina selbst. */
static BOOL RRCopyClientIcon(NSURL *icns)
{
	NSBundle *main = NSBundle.mainBundle;
	NSString *name = main.infoDictionary[@"CFBundleIconFile"];
	NSString *path =
	    name ? [main pathForResource:name.stringByDeletingPathExtension ofType:@"icns"] : nil;

	if (path)
		return [NSFileManager.defaultManager copyItemAtPath:path toPath:icns.path error:NULL];

	NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:main.bundlePath];
	return RRWriteIcns(icon, icns) || RRWriteIcnsViaIconutil(icon, icns);
}

/* ---- Bundle --------------------------------------------------------------------------- */

static NSString *RRLaunchScript(NSArray<NSString *> *arguments, NSString *client, BOOL clientIsBundle)
{
	NSMutableString *quoted = [NSMutableString new];
	NSMutableString *script = [NSMutableString new];

	for (NSString *argument in arguments)
		[quoted appendFormat:@" %@", RRShellQuote(argument)];

	[script appendString:@"#!/bin/sh\n"
	                     @"# Von rdp-retina --createapp erzeugt: startet eine RemoteApp.\n"
	                     @"# Das Kennwort steht im Schlüsselbund (Dienst \"rdp-retina\"), "
	                     @"nicht in dieser Datei.\n"];
	[script appendFormat:@"start() {\n\t/usr/bin/open \"$@\" --args%@\n}\n", quoted];
	[script appendFormat:@"if start -n -b %@ 2>/dev/null; then\n\texit 0\nfi\n",
	                     RRShellQuote(RRAppletClientId)];
	if (clientIsBundle)
		[script appendFormat:@"if [ -d %@ ]; then\n\texec /usr/bin/open -n %@ --args%@\nfi\n",
		                     RRShellQuote(client), RRShellQuote(client), quoted];
	else
		[script appendFormat:@"if [ -x %@ ]; then\n\texec %@%@\nfi\n", RRShellQuote(client),
		                     RRShellQuote(client), quoted];
	[script appendString:@"echo 'rdp-retina ist nicht installiert "
	                     @"(com.cratchmere.rdp-retina).' >&2\nexit 1\n"];
	return script;
}

static NSDictionary *RRAppletInfo(NSString *name, NSString *identifier,
                                 NSArray<NSString *> *arguments, NSString *client)
{
	NSString *created = [NSISO8601DateFormatter stringFromDate:NSDate.date
	                                                 timeZone:NSTimeZone.localTimeZone
	                                             formatOptions:NSISO8601DateFormatWithInternetDateTime];

	return @{
		@"CFBundleDevelopmentRegion" : @"de",
		@"CFBundleDisplayName" : name,
		@"CFBundleExecutable" : RRAppletExecutable,
		@"CFBundleIconFile" : RRAppletIcon,
		@"CFBundleIdentifier" : identifier,
		@"CFBundleInfoDictionaryVersion" : @"6.0",
		@"CFBundleName" : name,
		@"CFBundlePackageType" : @"APPL",
		@"CFBundleShortVersionString" : @"1.0",
		@"CFBundleVersion" : @"1",
		@"LSApplicationCategoryType" : @"public.app-category.utilities",
		@"LSMinimumSystemVersion" : @"13.0",
		@"NSHighResolutionCapable" : @YES,
		/* Merkmal eines eigenen Applets: nur solche Bundles überschreibt --createapp. */
		RRAppletMarker : @{
			@"Version" : @1,
			@"Arguments" : arguments,
			@"Client" : client,
			@"Created" : created,
		},
	};
}

/* YES, wenn dort nichts liegt oder ein eigenes Applet lag (das dann entfernt ist). */
static BOOL RRClearTarget(NSURL *bundle, NSError **error)
{
	NSFileManager *fm = NSFileManager.defaultManager;
	NSURL *plist = [bundle URLByAppendingPathComponent:@"Contents/Info.plist"];

	if (![fm fileExistsAtPath:bundle.path])
		return YES;

	NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:plist error:NULL];
	if (!info[RRAppletMarker])
		return RRFail(error, @"%@ gibt es schon und ist kein rdp-retina-Applet", bundle.path);
	return [fm removeItemAtURL:bundle error:error];
}

static BOOL RRCreateBundle(NSURL *bundle, NSDictionary *info, NSString *script,
                           NSString *iconSource, NSError **error)
{
	NSFileManager *fm = NSFileManager.defaultManager;
	NSURL *contents = [bundle URLByAppendingPathComponent:@"Contents" isDirectory:YES];
	NSURL *macos = [contents URLByAppendingPathComponent:@"MacOS" isDirectory:YES];
	NSURL *resources = [contents URLByAppendingPathComponent:@"Resources" isDirectory:YES];

	if (![fm createDirectoryAtURL:macos withIntermediateDirectories:YES attributes:nil error:error])
		return NO;
	if (![fm createDirectoryAtURL:resources
	    withIntermediateDirectories:YES
	                     attributes:nil
	                          error:error])
		return NO;

	NSData *plist = [NSPropertyListSerialization dataWithPropertyList:info
	                                                          format:NSPropertyListXMLFormat_v1_0
	                                                         options:0
	                                                           error:error];
	if (!plist)
		return NO;
	if (![plist writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"]
	              options:NSDataWritingAtomic
	                error:error])
		return NO;
	if (![@"APPL????" writeToURL:[contents URLByAppendingPathComponent:@"PkgInfo"]
	                  atomically:YES
	                    encoding:NSUTF8StringEncoding
	                       error:error])
		return NO;

	NSURL *exe = [macos URLByAppendingPathComponent:RRAppletExecutable];
	if (![script writeToURL:exe atomically:YES encoding:NSUTF8StringEncoding error:error])
		return NO;
	if (![fm setAttributes:@{ NSFilePosixPermissions : @(0755) } ofItemAtPath:exe.path error:error])
		return NO;

	NSURL *icns = [resources
	    URLByAppendingPathComponent:[RRAppletIcon stringByAppendingPathExtension:@"icns"]];
	if (iconSource)
	{
		NSImage *image = RRLoadIcon(iconSource, error);
		if (!image)
			return NO;
		if (!RRWriteIcns(image, icns) && !RRWriteIcnsViaIconutil(image, icns))
			return RRFail(error, @"Symbol ließ sich nicht als .icns schreiben");
	}
	else if (!RRCopyClientIcon(icns))
		return RRFail(error, @"Symbol von rdp-retina nicht gefunden");
	return YES;
}

/* ---- Dock ----------------------------------------------------------------------------- */

static BOOL RRAddToDock(NSString *bundlePath)
{
	NSURL *url = [NSURL fileURLWithPath:bundlePath isDirectory:YES];
	NSArray *stored = (__bridge_transfer NSArray *)CFPreferencesCopyAppValue(
	    CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
	NSMutableArray *apps =
	    [stored isKindOfClass:NSArray.class] ? [stored mutableCopy] : [NSMutableArray new];

	for (NSDictionary *entry in apps)
	{
		if (![entry isKindOfClass:NSDictionary.class])
			continue;

		NSString *existing = entry[@"tile-data"][@"file-data"][@"_CFURLString"];
		if (![existing isKindOfClass:NSString.class])
			continue;

		NSURL *other = [existing hasPrefix:@"file:"] ? [NSURL URLWithString:existing]
		                                             : [NSURL fileURLWithPath:existing];
		if ([other.URLByStandardizingPath.path isEqualToString:url.URLByStandardizingPath.path])
			return YES; /* steht schon im Dock */
	}

	[apps addObject:@{
		@"tile-type" : @"file-tile",
		@"tile-data" : @{
			@"file-label" : bundlePath.lastPathComponent.stringByDeletingPathExtension,
			@"file-type" : @41,
			@"file-data" : @{ @"_CFURLString" : url.absoluteString, @"_CFURLStringType" : @15 },
		},
	}];

	CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFArrayRef)apps,
	                         CFSTR("com.apple.dock"));
	if (!CFPreferencesAppSynchronize(CFSTR("com.apple.dock")))
		return NO;

	/* Das Dock liest seine Liste beim Start. */
	(void)RRRun(@"/usr/bin/killall", @[ @"Dock" ]);
	return YES;
}

/* ---- Ablauf --------------------------------------------------------------------------- */

BOOL RRAppletRequested(int argc, char **argv)
{
	for (int i = 1; i < argc; i++)
	{
		if (strcmp(argv[i], "--createapp") == 0)
			return YES;
	}
	return NO;
}

int RRAppletMain(int argc, char **argv)
{
	NSMutableArray<NSString *> *forward = [NSMutableArray new];
	NSString *name = nil;
	NSString *iconSource = nil;
	NSString *dest = nil;
	NSString *password = nil;
	BOOL nodock = NO;
	BOOL hasCert = NO;
	BOOL hasServer = NO;
	BOOL hasApp = NO;

	for (int i = 1; i < argc; i++)
	{
		NSString *arg = [NSString stringWithCString:argv[i] encoding:NSUTF8StringEncoding];
		if (!arg)
		{
			fprintf(stderr, "rdp-retina: Argument %d ist nicht als UTF-8 lesbar\n", i);
			return 1;
		}

		if ([arg isEqualToString:@"--createapp"])
			continue;
		if ([arg isEqualToString:@"--nodock"])
		{
			nodock = YES;
			continue;
		}
		if ([arg hasPrefix:@"--appname="])
		{
			name = [arg substringFromIndex:@"--appname=".length];
			continue;
		}
		if ([arg hasPrefix:@"--icon="])
		{
			iconSource = [arg substringFromIndex:@"--icon=".length];
			continue;
		}
		if ([arg hasPrefix:@"--dest="])
		{
			dest = [arg substringFromIndex:@"--dest=".length];
			continue;
		}

		NSString *body = RRArgumentBody(arg);
		if ([body hasPrefix:@"p:"])
		{
			/* Das Kennwort gehört in den Schlüsselbund, nicht ins Bundle. */
			password = [body substringFromIndex:2];
			continue;
		}
		if ([body hasPrefix:@"gp:"] || [body hasPrefix:@"gat:"])
		{
			fprintf(stderr, "rdp-retina: Gateway-Kennwort und -Token (/gp:, /gat:) landeten im "
			                "Klartext im Applet – bitte ohne sie anlegen\n");
			return 1;
		}
		if ([body hasPrefix:@"cert:"] || [body hasPrefix:@"cert-"])
			hasCert = YES;
		if ([body hasPrefix:@"v:"])
			hasServer = YES;
		if ([body hasPrefix:@"app:"])
		{
			NSString *value = [body substringFromIndex:@"app:".length];
			BOOL keyed = NO;

			if (value.length == 0)
			{
				fprintf(stderr, "rdp-retina: /app: ohne Programm\n");
				return 1;
			}
			for (NSString *key in RRAppKeys())
				keyed = keyed || [value hasPrefix:key];

			/* FreeRDP erwartet program:, eine nackte Angabe ergänzen wir. */
			[forward addObject:keyed ? arg : [@"/app:program:" stringByAppendingString:value]];
			hasApp = YES;
			continue;
		}
		[forward addObject:arg];
	}

	if (!hasServer || !hasApp)
	{
		RRUsage();
		return 1;
	}
	if (!hasCert)
		[forward addObject:@"/cert:tofu"];

	rdpSettings *settings = RRParseArguments(forward, password);
	if (!settings)
	{
		fprintf(stderr, "rdp-retina: Argumente nicht verständlich, kein Applet angelegt\n");
		return 1;
	}

	if (name.length == 0)
	{
		const char *given = freerdp_settings_get_string(settings, FreeRDP_RemoteApplicationName);
		const char *program = freerdp_settings_get_string(settings, FreeRDP_RemoteApplicationProgram);

		if (given && (*given != '\0'))
			name = [NSString stringWithUTF8String:given];
		else if (program && (*program != '\0'))
			name = RRNameFromProgram([NSString stringWithUTF8String:program]);
	}
	name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (name.length == 0)
	{
		fprintf(stderr, "rdp-retina: kein Name für das Applet, bitte --appname=<name>\n");
		freerdp_settings_free(settings);
		return 1;
	}

	NSString *folder = (dest.length > 0)
	                       ? dest.stringByExpandingTildeInPath
	                       : [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
	NSError *error = nil;
	if (![NSFileManager.defaultManager createDirectoryAtPath:folder
	                            withIntermediateDirectories:YES
	                                             attributes:nil
	                                                  error:&error])
	{
		fprintf(stderr, "rdp-retina: %s ließ sich nicht anlegen: %s\n", folder.UTF8String,
		        RRErrorText(error));
		freerdp_settings_free(settings);
		return 1;
	}

	NSBundle *main = NSBundle.mainBundle;
	NSString *client = main.bundlePath;
	const BOOL clientIsBundle = [client.pathExtension isEqualToString:@"app"];
	if (!clientIsBundle)
		client = main.executablePath ?: @"rdp-retina";

	NSString *file = [RRSafeName(name) stringByAppendingPathExtension:@"app"];
	NSURL *bundle = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:file]
	                           isDirectory:YES];
	NSString *identifier =
	    [NSString stringWithFormat:@"%@.applet.%@", RRAppletClientId, RRIdentifierPart(name)];

	if (!RRClearTarget(bundle, &error))
	{
		fprintf(stderr, "rdp-retina: %s\n", RRErrorText(error));
		freerdp_settings_free(settings);
		return 1;
	}
	if (!RRCreateBundle(bundle, RRAppletInfo(name, identifier, forward, client),
	                    RRLaunchScript(forward, client, clientIsBundle), iconSource, &error))
	{
		fprintf(stderr, "rdp-retina: %s\n", RRErrorText(error));
		/* Das halbfertige Bundle stammt von uns. */
		[NSFileManager.defaultManager removeItemAtURL:bundle error:NULL];
		freerdp_settings_free(settings);
		return 1;
	}

	/* Ad hoc signieren und bei Launch Services anmelden; beides ist nicht entscheidend. */
	(void)RRRun(@"/usr/bin/codesign", @[ @"--force", @"--sign", @"-", bundle.path ]);
	(void)RRRun(@"/System/Library/Frameworks/CoreServices.framework/Frameworks/"
	            @"LaunchServices.framework/Support/lsregister",
	            @[ @"-f", bundle.path ]);

	NSString *account = RRCredentialsAccount(settings);
	if (password.length > 0)
	{
		NSError *keychain = nil;
		if (!account)
			fprintf(stderr, "rdp-retina: kein Konto für den Schlüsselbund, /u: fehlt\n");
		else if (!RRCredentialsStore(account, password, &keychain))
			fprintf(stderr, "rdp-retina: Kennwort nicht im Schlüsselbund gespeichert: %s\n",
			        RRErrorText(keychain));
		else
			printf("Kennwort im Schlüsselbund: Dienst rdp-retina, Konto %s\n", account.UTF8String);
	}
	else
		printf("Kennwort: aus dem Schlüsselbund, sofern dort eines für %s liegt\n",
		       account ? account.UTF8String : "diesen Server");

	if (!nodock && !RRAddToDock(bundle.path))
		fprintf(stderr, "rdp-retina: Applet ließ sich nicht ins Dock legen\n");

	printf("%s angelegt\n", bundle.path.UTF8String);
	freerdp_settings_free(settings);
	return 0;
}
