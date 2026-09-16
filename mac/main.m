/*
 * rdp-retina – RDP-Client für macOS mit nativer Retina-Schärfe und RemoteApp
 *
 * Mit Argumenten wie xfreerdp (P1) verbindet die App direkt:
 *   rdp-retina /v:server /u:benutzer /f /scale:180 /gfx:AVC444 /network:lan
 *   rdp-retina /v:server /u:benutzer /app:program:"||taskmgr"
 * Ohne Argumente – aus Finder, Launchpad oder über eine Verknüpfung – öffnet sie die Oberfläche.
 */
#import <AppKit/AppKit.h>

#import "RRApplet.h"
#import "RRApplication.h"
#import "RRSession.h"

/* NSApp.delegate hält nur schwach; die Delegates leben so lange wie der Prozess. */
static RRAppDelegate *RRCommandLineDelegate = nil;
static RRUIAppDelegate *RRInterfaceDelegate = nil;

/* Xcode hängt beim Start eigene Argumente an (-NSDocumentRevisionsDebugMode YES, ...), ältere
 * macOS-Versionen beim Start aus dem Finder -psn_…; FreeRDPs Auswertung lehnte beide ab. */
static int RRFilterArguments(int argc, char **argv, char **out)
{
	int count = 0;

	for (int i = 0; i < argc; i++)
	{
		const char *arg = argv[i];
		if ((i > 0) && (strncmp(arg, "-psn_", 5) == 0))
			continue;
		if ((i > 0) && ((strncmp(arg, "-NS", 3) == 0) || (strncmp(arg, "-Apple", 6) == 0)))
		{
			if ((i + 1 < argc) && (argv[i + 1][0] != '/') && (argv[i + 1][0] != '-') &&
			    (argv[i + 1][0] != '+'))
				i++;
			continue;
		}
		out[count++] = argv[i];
	}
	out[count] = NULL;
	return count;
}

int main(int argc, char *argv[])
{
	@autoreleasepool
	{
		char **args = calloc((size_t)argc + 1, sizeof(char *));
		if (!args)
			return 1;
		const int count = RRFilterArguments(argc, argv, args);

		/* --createapp legt nur ein Applet an und verbindet sich nicht. In der App Sandbox (Mac App
		 * Store) geht das nicht: Dock-Einstellungen und andere Programme sind dort gesperrt. */
		if (RRAppletRequested(count, args))
		{
			int code = 1;
			if (getenv("APP_SANDBOX_CONTAINER_ID"))
				fprintf(stderr, "rdp-retina: --createapp gibt es in der App-Store-Fassung nicht. Die "
				                "App Sandbox verbietet Einträge im Dock und das Starten anderer "
				                "Programme.\n");
			else
				code = RRAppletMain(count, args);
			free(args);
			return code;
		}

		[RRApplication sharedApplication];

		if (count <= 1)
		{
			free(args);
			RRInterfaceDelegate = [[RRUIAppDelegate alloc] init];
			NSApp.delegate = RRInterfaceDelegate;
			[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
			[NSApp run];
			return 0;
		}

		int exitCode = 0;
		RRSession *session = [[RRSession alloc] initWithArgc:count argv:args exitCode:&exitCode];
		if (!session)
		{
			free(args);
			return exitCode;
		}

		RRCommandLineDelegate = [[RRAppDelegate alloc] initWithSession:session];
		NSApp.delegate = RRCommandLineDelegate;
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		[NSApp run];

		free(args);
		return session.exitCode;
	}
}
