/*
 * rdp-retina – Tastatur (P7)
 */
#import <AppKit/AppKit.h>

#include "rr_core.h"

NS_ASSUME_NONNULL_BEGIN

/*
 * Tasten gehen als Scancodes an den Server; welches Zeichen daraus wird, bestimmt das
 * Tastaturlayout der Sitzung. Deutsches Layout: Windows-Belegung (@ = AltGr+Q).
 *
 * Sondertasten:
 *   Befehl links   -> Strg   (Cmd+C/V/Z/S wirken wie gewohnt)   /retina-cmd:win -> Windows
 *   Befehl rechts  -> Windows-Taste
 *   Option links   -> Alt
 *   Option rechts  -> AltGr
 *   Control        -> Strg
 */
@interface RRKeyboard : NSObject

- (instancetype)initWithContext:(rrContext *)rr;

@property (nonatomic) BOOL commandAsControl;

- (void)handleEvent:(NSEvent *)event;
/* Alle gedrückten Tasten loslassen (Fokusverlust) */
- (void)releaseAll;
/* Feststelltaste abgleichen (Fokusgewinn) */
- (void)syncLockStates;

/* KLID des aktiven macOS-Layouts, 0 = unbekannt */
+ (DWORD)currentLayoutId;
+ (BOOL)isISOKeyboard;

@end

NS_ASSUME_NONNULL_END
