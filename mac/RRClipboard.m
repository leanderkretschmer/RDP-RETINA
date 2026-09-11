/*
 * rdp-retina – Zwischenablage (W2), Text in beide Richtungen
 *
 * Windows -> Mac: Bei jeder Formatliste mit CF_UNICODETEXT wird der Text sofort geholt
 *                 und in die Mac-Zwischenablage geschrieben.
 * Mac -> Windows: Die Mac-Zwischenablage wird zweimal je Sekunde geprüft; bei Änderung
 *                 geht eine Formatliste raus, der Text erst auf Anfrage.
 */
#import "RRClipboard.h"

#include <winpr/user.h>
#include <freerdp/channels/cliprdr.h>

@interface RRClipboard ()
@property (atomic, copy, nullable) NSString *localText;
@property (atomic) BOOL ready;
- (UINT)sendFormatList;
- (void)takeRemoteText:(NSString *)text;
- (void)stopTimer;
@end

static RRClipboard *RRClipboardFrom(CliprdrClientContext *context)
{
	return context->custom ? (__bridge RRClipboard *)context->custom : nil;
}

static UINT rr_clip_monitor_ready(CliprdrClientContext *context,
                                  const CLIPRDR_MONITOR_READY *monitorReady)
{
	RRClipboard *clipboard = RRClipboardFrom(context);
	if (!clipboard)
		return CHANNEL_RC_OK;

	CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = CB_USE_LONG_FORMAT_NAMES;

	CLIPRDR_CAPABILITIES capabilities = { 0 };
	capabilities.cCapabilitiesSets = 1;
	capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;

	const UINT rc = context->ClientCapabilities(context, &capabilities);
	if (rc != CHANNEL_RC_OK)
		return rc;

	clipboard.ready = YES;
	return [clipboard sendFormatList];
}

static UINT rr_clip_server_capabilities(CliprdrClientContext *context,
                                        const CLIPRDR_CAPABILITIES *capabilities)
{
	return CHANNEL_RC_OK;
}

static UINT rr_clip_server_format_list(CliprdrClientContext *context,
                                       const CLIPRDR_FORMAT_LIST *formatList)
{
	CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
	response.common.msgFlags = CB_RESPONSE_OK;

	const UINT rc = context->ClientFormatListResponse(context, &response);
	if (rc != CHANNEL_RC_OK)
		return rc;

	for (UINT32 i = 0; i < formatList->numFormats; i++)
	{
		if (formatList->formats[i].formatId == CF_UNICODETEXT)
		{
			CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
			request.requestedFormatId = CF_UNICODETEXT;
			return context->ClientFormatDataRequest(context, &request);
		}
	}
	return CHANNEL_RC_OK;
}

static UINT rr_clip_server_format_list_response(CliprdrClientContext *context,
                                                const CLIPRDR_FORMAT_LIST_RESPONSE *response)
{
	return CHANNEL_RC_OK;
}

static UINT rr_clip_server_format_data_request(CliprdrClientContext *context,
                                               const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
	RRClipboard *clipboard = RRClipboardFrom(context);
	NSString *text = clipboard.localText;
	CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
	NSMutableData *data = nil;

	if (text && (request->requestedFormatId == CF_UNICODETEXT))
	{
		NSString *windowsText =
		    [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
		        stringByReplacingOccurrencesOfString:@"\n"
		                                  withString:@"\r\n"];
		data = [[windowsText dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
		const uint16_t terminator = 0;
		[data appendBytes:&terminator length:sizeof(terminator)];
	}

	if (data)
	{
		response.common.msgFlags = CB_RESPONSE_OK;
		response.common.dataLen = (UINT32)data.length;
		response.requestedFormatData = data.bytes;
	}
	else
		response.common.msgFlags = CB_RESPONSE_FAIL;

	return context->ClientFormatDataResponse(context, &response);
}

static UINT rr_clip_server_format_data_response(CliprdrClientContext *context,
                                                const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
	RRClipboard *clipboard = RRClipboardFrom(context);
	if (!clipboard || (response->common.msgFlags & CB_RESPONSE_FAIL) ||
	    !response->requestedFormatData)
		return CHANNEL_RC_OK;

	NSUInteger length = response->common.dataLen & ~(UINT32)1;
	while (length >= 2)
	{
		uint16_t last = 0;
		memcpy(&last, response->requestedFormatData + length - 2, sizeof(last));
		if (last != 0)
			break;
		length -= 2;
	}

	NSString *text = [[NSString alloc] initWithBytes:response->requestedFormatData
	                                          length:length
	                                        encoding:NSUTF16LittleEndianStringEncoding];
	text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
	if (text)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			[clipboard takeRemoteText:text];
		});
	}
	return CHANNEL_RC_OK;
}

@implementation RRClipboard
{
	CliprdrClientContext *_cliprdr;
	NSTimer *_timer;
	NSInteger _changeCount;
}

- (instancetype)initWithCliprdr:(CliprdrClientContext *)cliprdr
{
	self = [super init];
	if (!self)
		return nil;

	_cliprdr = cliprdr;
	_changeCount = -1;

	/* Der Kanal hält eine eigene Referenz, bis detachCliprdr: sie abgibt. */
	cliprdr->custom = (void *)CFBridgingRetain(self);
	cliprdr->MonitorReady = rr_clip_monitor_ready;
	cliprdr->ServerCapabilities = rr_clip_server_capabilities;
	cliprdr->ServerFormatList = rr_clip_server_format_list;
	cliprdr->ServerFormatListResponse = rr_clip_server_format_list_response;
	cliprdr->ServerFormatDataRequest = rr_clip_server_format_data_request;
	cliprdr->ServerFormatDataResponse = rr_clip_server_format_data_response;
	return self;
}

+ (void)detachCliprdr:(CliprdrClientContext *)cliprdr
{
	void *custom = cliprdr->custom;
	cliprdr->custom = NULL;
	if (!custom)
		return;

	RRClipboard *clipboard = (RRClipboard *)CFBridgingRelease(custom);
	dispatch_async(dispatch_get_main_queue(), ^{
		[clipboard stopTimer];
	});
}

- (void)start
{
	[self poll];
	_timer = [NSTimer scheduledTimerWithTimeInterval:0.5
	                                          target:self
	                                        selector:@selector(poll)
	                                        userInfo:nil
	                                         repeats:YES];
}

- (void)stopTimer
{
	[_timer invalidate];
	_timer = nil;
}

- (void)poll
{
	NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
	const NSInteger changeCount = pasteboard.changeCount;
	if (changeCount == _changeCount)
		return;

	_changeCount = changeCount;
	self.localText = [pasteboard stringForType:NSPasteboardTypeString];
	if (self.ready)
		(void)[self sendFormatList];
}

- (UINT)sendFormatList
{
	const BOOL hasText = self.localText != nil;
	CLIPRDR_FORMAT format = { 0 };
	format.formatId = CF_UNICODETEXT;

	CLIPRDR_FORMAT_LIST list = { 0 };
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = hasText ? 1 : 0;
	list.formats = hasText ? &format : NULL;
	return _cliprdr->ClientFormatList(_cliprdr, &list);
}

- (void)takeRemoteText:(NSString *)text
{
	if ([text isEqualToString:self.localText])
		return;

	NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
	[pasteboard clearContents];
	[pasteboard setString:text forType:NSPasteboardTypeString];
	/* Eigene Änderung nicht als lokale Änderung zurückschicken */
	_changeCount = pasteboard.changeCount;
	self.localText = text;
}

@end
