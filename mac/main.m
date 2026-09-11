/*
 * rdp-retina – RDP-Client für macOS mit nativer Retina-Schärfe und RemoteApp
 *
 * Bedienung nur über die Kommandozeile, Argumente wie bei xfreerdp (P1):
 *   rdp-retina /v:server /u:benutzer /f /scale:180 /gfx:AVC444 /network:lan
 *   rdp-retina /v:server /u:benutzer /app:program:"||taskmgr"
 */
#import <AppKit/AppKit.h>

#import "RRApplication.h"
#import "RRSession.h"

/* Xcode hängt beim Start eigene Argumente an (-NSDocumentRevisionsDebugMode YES, ...),
 * die FreeRDPs Auswertung ablehnen würde. */
static int RRFilterArguments(int argc, char **argv, char **out)
{
	int count = 0;

	for (int i = 0; i < argc; i++)
	{
		const char *arg = argv[i];
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

		[RRApplication sharedApplication];

		int exitCode = 0;
		RRSession *session = [[RRSession alloc] initWithArgc:count argv:args exitCode:&exitCode];
		if (!session)
		{
			free(args);
			return exitCode;
		}

		RRAppDelegate *delegate = [[RRAppDelegate alloc] initWithSession:session];
		NSApp.delegate = delegate;
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		[NSApp run];

		free(args);
		return session.exitCode;
	}
}
