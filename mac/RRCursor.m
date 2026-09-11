/*
 * rdp-retina – Mauszeiger und Symbole aus Serverpixeln
 */
#import "RRCursor.h"

NSImage *RRImageCreate(const BYTE *bgra, UINT32 width, UINT32 height, CGFloat scale)
{
	if (!bgra || (width == 0) || (height == 0) || (scale <= 0))
		return nil;

	NSBitmapImageRep *rep =
	    [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
	                                            pixelsWide:width
	                                            pixelsHigh:height
	                                         bitsPerSample:8
	                                       samplesPerPixel:4
	                                              hasAlpha:YES
	                                              isPlanar:NO
	                                        colorSpaceName:NSDeviceRGBColorSpace
	                                          bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
	                                           bytesPerRow:4 * width
	                                          bitsPerPixel:32];
	if (!rep)
		return nil;

	unsigned char *dst = rep.bitmapData;
	const size_t pixels = (size_t)width * height;
	for (size_t i = 0; i < pixels; i++)
	{
		const BYTE *s = &bgra[4 * i];
		dst[0] = s[2];
		dst[1] = s[1];
		dst[2] = s[0];
		dst[3] = s[3];
		dst += 4;
	}

	const NSSize size = NSMakeSize(width / scale, height / scale);
	rep.size = size;

	NSImage *image = [[NSImage alloc] initWithSize:size];
	[image addRepresentation:rep];
	return image;
}

NSCursor *RRCursorCreate(const BYTE *bgra, UINT32 width, UINT32 height, UINT32 hotX, UINT32 hotY,
                         CGFloat scale)
{
	NSImage *image = RRImageCreate(bgra, width, height, scale);
	if (!image)
		return nil;
	return [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(hotX / scale, hotY / scale)];
}

NSCursor *RRCursorHidden(void)
{
	static NSCursor *hidden = nil;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		const BYTE transparent[4] = { 0, 0, 0, 0 };
		NSImage *image = RRImageCreate(transparent, 1, 1, 1.0);
		hidden = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
	});
	return hidden;
}
