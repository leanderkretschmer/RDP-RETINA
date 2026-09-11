/*
 * rdp-retina – Desktop-Modus (Stufe 1)
 */
#import <AppKit/AppKit.h>

@class RRSession;
@class RRTexture;

NS_ASSUME_NONNULL_BEGIN

extern const NSWindowStyleMask RRDesktopWindowStyle;

@interface RRDesktopController : NSObject

- (instancetype)initWithSession:(RRSession *)session;

/* Hauptthread, vor dem Verbinden. pixels = Sitzungsgröße. */
- (void)showWithPixelSize:(NSSize)pixels fullscreen:(BOOL)fullscreen;
/* Hauptthread */
- (void)desktopResized:(NSSize)pixels texture:(nullable RRTexture *)texture;
/* Beliebiger Thread */
- (void)desktopUpdated;
/* Hauptthread */
- (void)cursorChanged;
- (void)close;
/* Selbsttest (P2): Ergebnis auf stderr */
- (void)runSelfTest;

@end

NS_ASSUME_NONNULL_END
