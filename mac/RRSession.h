/*
 * rdp-retina – Brücke zwischen Kern und Cocoa
 */
#import <AppKit/AppKit.h>

#include "rr_core.h"

@class RRKeyboard;
@class RRRenderer;
@class RRTexture;

NS_ASSUME_NONNULL_BEGIN

/*
 * Hält den Kern-Kontext und verteilt dessen Rückrufe (aus FreeRDP-Threads) an Desktop-
 * bzw. RemoteApp-Steuerung. Lebt im Hauptthread.
 */
@interface RRSession : NSObject

- (nullable instancetype)initWithArgc:(int)argc argv:(char *_Nullable *_Nonnull)argv exitCode:(int *)exitCode;

@property (nonatomic, readonly) rrContext *rr;
@property (nonatomic, readonly) RRRenderer *renderer;
@property (nonatomic, readonly) RRKeyboard *keyboard;
@property (nonatomic, readonly, nullable) NSScreen *primaryScreen;
/* Pixel je Punkt am primären Bildschirm (Retina: 2) */
@property (nonatomic, readonly) CGFloat scale;
@property (nonatomic, readonly) NSCursor *cursor;
@property (atomic, readonly, nullable) RRTexture *desktopTexture;
@property (nonatomic) int exitCode;

/* /retina-verbose: Fensterverwaltung protokollieren; /retina-selftest: Pixeltest (P2) */
@property (nonatomic, readonly) BOOL verbose;
@property (nonatomic, readonly) BOOL selfTest;

- (BOOL)start;
- (void)stop;

/* Globale Punkte (macOS, y nach oben) <-> Server-Pixel (y nach unten) */
- (NSPoint)serverPointFromScreenPoint:(NSPoint)point;
- (NSRect)screenFrameForServerRect:(rrRect)rect;

- (void)sendScrollWheel:(NSEvent *)event;
- (void)appDidBecomeActive;
- (void)appDidResignActive;

@end

NS_ASSUME_NONNULL_END
