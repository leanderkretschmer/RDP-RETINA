/*
 * rdp-retina – Mauszeiger und Symbole aus Serverpixeln
 */
#import <AppKit/AppKit.h>

#include <winpr/wtypes.h>

NS_ASSUME_NONNULL_BEGIN

/* BGRA-Pixel (nicht vormultipliziert) als Bild mit Retina-Auflösung:
 * width Pixel ergeben width/scale Punkte, also ein Server-Pixel je Bildschirmpixel. */
NSImage *_Nullable RRImageCreate(const BYTE *bgra, UINT32 width, UINT32 height, CGFloat scale);

NSCursor *_Nullable RRCursorCreate(const BYTE *bgra, UINT32 width, UINT32 height, UINT32 hotX,
                                   UINT32 hotY, CGFloat scale);

/* Unsichtbarer Zeiger (Server blendet den Zeiger aus) */
NSCursor *RRCursorHidden(void);

NS_ASSUME_NONNULL_END
