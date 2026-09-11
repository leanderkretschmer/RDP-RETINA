/*
 * rdp-retina – Abfragen an HIToolbox (Carbon)
 */
#import <Carbon/Carbon.h>

#import "RRInputSource.h"

typedef struct
{
	const char *name;  /* letzter Teil von com.apple.keylayout.<name> */
	uint32_t layout;   /* Windows-KLID */
} RRLayoutName;

static const RRLayoutName RRLayoutNames[] = {
	{ "German", 0x00000407 },         { "German-DIN-2137", 0x00000407 },
	{ "Austrian", 0x00000C07 },       { "SwissGerman", 0x00000807 },
	{ "SwissFrench", 0x0000100C },    { "US", 0x00000409 },
	{ "ABC", 0x00000409 },            { "USExtended", 0x00000409 },
	{ "USInternational-PC", 0x00020409 }, { "British", 0x00000809 },
	{ "British-PC", 0x00000809 },     { "French", 0x0000040C },
	{ "French-PC", 0x0000040C },      { "Belgian", 0x0000080C },
	{ "Spanish", 0x0000040A },        { "Spanish-ISO", 0x0000040A },
	{ "Italian", 0x00000410 },        { "Italian-Pro", 0x00000410 },
	{ "Dutch", 0x00000413 },          { "Danish", 0x00000406 },
	{ "Swedish", 0x0000041D },        { "Swedish-Pro", 0x0000041D },
	{ "Norwegian", 0x00000414 },      { "Finnish", 0x0000040B },
	{ "Polish", 0x00000415 },         { "PolishPro", 0x00000415 },
	{ "Czech", 0x00000405 },          { "Czech-QWERTY", 0x00010405 },
	{ "Hungarian", 0x0000040E },      { "Portuguese", 0x00000816 },
	{ "Brazilian", 0x00000416 },      { "Turkish", 0x0000041F },
	{ "Russian", 0x00000419 },
};

uint32_t RRInputSourceLayoutId(void)
{
	TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
	if (!source)
		return 0;

	uint32_t layout = 0;
	CFStringRef sourceId = TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
	if (sourceId)
	{
		NSString *name = ((__bridge NSString *)sourceId).pathExtension;
		for (size_t i = 0; i < sizeof(RRLayoutNames) / sizeof(RRLayoutNames[0]); i++)
		{
			if ([name isEqualToString:@(RRLayoutNames[i].name)])
			{
				layout = RRLayoutNames[i].layout;
				break;
			}
		}
	}
	CFRelease(source);
	return layout;
}

BOOL RRInputSourceIsISO(void)
{
	return KBGetLayoutType(LMGetKbdType()) == kKeyboardISO;
}
