/*
 * rdp-retina – mehrere RemoteApps in einer Sitzung
 *
 * Protokoll: ein Programm je Zeile hin, danach Schreibseite schließen; je Programm "OK" oder
 * "FEHLER" als Zeile zurück.
 */
#import "RRShare.h"

#include <errno.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static const NSUInteger RRShareMaxRequest = 64 * 1024;

/* FNV-1a, nur für einen kurzen, stabilen Dateinamen */
static uint64_t RRShareHash(NSString *text)
{
	uint64_t hash = 14695981039346656037ULL;
	for (const char *c = text.UTF8String; *c; c++)
	{
		hash ^= (unsigned char)*c;
		hash *= 1099511628211ULL;
	}
	return hash;
}

static BOOL RRShareAddress(NSString *path, struct sockaddr_un *address)
{
	memset(address, 0, sizeof(*address));
	address->sun_family = AF_UNIX;

	const char *p = path.fileSystemRepresentation;
	if (strlen(p) >= sizeof(address->sun_path))
		return NO;
	strlcpy(address->sun_path, p, sizeof(address->sun_path));
	return YES;
}

static void RRShareTimeout(int fd, long seconds)
{
	const struct timeval timeout = { .tv_sec = seconds };
	(void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
	(void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static BOOL RRShareWrite(int fd, NSString *text)
{
	NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
	const uint8_t *bytes = data.bytes;
	size_t left = data.length;

	while (left > 0)
	{
		const ssize_t n = write(fd, bytes, left);
		if ((n < 0) && (errno == EINTR))
			continue;
		if (n <= 0)
			return NO;
		bytes += n;
		left -= (size_t)n;
	}
	return YES;
}

static NSArray<NSString *> *RRShareReadLines(int fd)
{
	NSMutableData *data = [NSMutableData new];
	uint8_t buffer[4096];

	while (data.length <= RRShareMaxRequest)
	{
		const ssize_t n = read(fd, buffer, sizeof(buffer));
		if ((n < 0) && (errno == EINTR))
			continue;
		if (n <= 0)
			break;
		[data appendBytes:buffer length:(NSUInteger)n];
	}

	NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
	NSMutableArray<NSString *> *lines = [NSMutableArray new];
	for (NSString *line in [text componentsSeparatedByString:@"\n"])
	{
		if (line.length > 0)
			[lines addObject:line];
	}
	return lines;
}

@implementation RRShare
{
	NSString *_path;
	dispatch_source_t _source;
	BOOL (^_handler)(NSString *app);
}

+ (NSString *)socketPathForSettings:(const rdpSettings *)settings
{
	const char *host = freerdp_settings_get_string(settings, FreeRDP_ServerHostname);
	if (!host || (*host == '\0'))
		return nil;

	const char *user = freerdp_settings_get_string(settings, FreeRDP_Username);
	const char *domain = freerdp_settings_get_string(settings, FreeRDP_Domain);
	NSString *key = [NSString stringWithFormat:@"%s:%u/%s\\%s", host,
	                                           freerdp_settings_get_uint32(settings, FreeRDP_ServerPort),
	                                           domain ?: "", user ?: ""]
	                    .lowercaseString;
	NSString *name = [NSString stringWithFormat:@"rdp-retina-%016llx.sock", RRShareHash(key)];

	/* $TMPDIR gehört nur dem Benutzer */
	NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
	struct sockaddr_un address;
	return RRShareAddress(path, &address) ? path : nil;
}

+ (RRShareResult)handOffApps:(NSArray<NSString *> *)apps toPath:(NSString *)path
{
	struct sockaddr_un address;
	if ((apps.count == 0) || !RRShareAddress(path, &address))
		return RRShareNoInstance;

	const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return RRShareNoInstance;

	/* Kein Zuhörer (auch ein übrig gebliebener Socket): selbst verbinden */
	if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0)
	{
		close(fd);
		return RRShareNoInstance;
	}

	RRShareTimeout(fd, 10);
	RRShareResult result = RRShareRefused;
	NSString *request = [[apps componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
	if (RRShareWrite(fd, request) && (shutdown(fd, SHUT_WR) == 0))
	{
		NSArray<NSString *> *replies = RRShareReadLines(fd);
		if (replies.count == apps.count)
		{
			result = RRShareDone;
			for (NSString *reply in replies)
			{
				if (![reply isEqualToString:@"OK"])
					result = RRShareRefused;
			}
		}
	}
	close(fd);
	return result;
}

- (instancetype)initWithPath:(NSString *)path handler:(BOOL (^)(NSString *app))handler
{
	self = [super init];
	if (!self)
		return nil;

	struct sockaddr_un address;
	if (!RRShareAddress(path, &address))
		return nil;

	const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return nil;

	/* Ein übrig gebliebener Socket einer beendeten Instanz – eine lebende hätte übernommen. */
	(void)unlink(address.sun_path);
	if ((bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) ||
	    (chmod(address.sun_path, S_IRUSR | S_IWUSR) != 0) || (listen(fd, 8) != 0))
	{
		close(fd);
		return nil;
	}

	_path = [path copy];
	_handler = [handler copy];
	_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
	                                 dispatch_get_main_queue());
	__weak RRShare *weakSelf = self;
	dispatch_source_set_event_handler(_source, ^{
		[weakSelf acceptFrom:fd];
	});
	dispatch_source_set_cancel_handler(_source, ^{
		close(fd);
	});
	dispatch_resume(_source);
	return self;
}

- (void)dealloc
{
	[self invalidate];
}

- (void)invalidate
{
	if (!_source)
		return;
	dispatch_source_cancel(_source);
	_source = nil;
	(void)unlink(_path.fileSystemRepresentation);
}

- (void)acceptFrom:(int)listener
{
	const int client = accept(listener, NULL, NULL);
	if (client < 0)
		return;

	/* nur Aufrufe desselben Benutzers */
	uid_t uid = 0;
	gid_t gid = 0;
	if ((getpeereid(client, &uid, &gid) != 0) || (uid != getuid()))
	{
		close(client);
		return;
	}

	RRShareTimeout(client, 5);
	BOOL (^handler)(NSString *) = _handler;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableString *reply = [NSMutableString new];
		for (NSString *app in RRShareReadLines(client))
		{
			__block BOOL ok = NO;
			dispatch_sync(dispatch_get_main_queue(), ^{
				ok = handler(app);
			});
			[reply appendString:ok ? @"OK\n" : @"FEHLER\n"];
		}
		(void)RRShareWrite(client, reply);
		close(client);
	});
}

@end
