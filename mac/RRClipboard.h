/*
 * rdp-retina – Zwischenablage (W2), Text in beide Richtungen
 */
#import <AppKit/AppKit.h>

#include <freerdp/client/cliprdr.h>

NS_ASSUME_NONNULL_BEGIN

@interface RRClipboard : NSObject

/* Im Kanal-Thread: hängt sich in den cliprdr-Kanal ein. */
- (instancetype)initWithCliprdr:(CliprdrClientContext *)cliprdr;
/* Hauptthread: beginnt, die lokale Zwischenablage zu beobachten. */
- (void)start;
/* Kanal-Thread: löst die Verbindung zum Kanal. */
+ (void)detachCliprdr:(CliprdrClientContext *)cliprdr;

@end

NS_ASSUME_NONNULL_END
