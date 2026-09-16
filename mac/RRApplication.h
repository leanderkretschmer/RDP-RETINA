/*
 * rdp-retina – Anwendung und Delegates
 */
#import <AppKit/AppKit.h>

@class RRSession;

NS_ASSUME_NONNULL_BEGIN

/* Reicht keyUp bei gedrückter Befehlstaste weiter, das AppKit sonst verschluckt. */
@interface RRApplication : NSApplication
@end

/* Kommandozeile: genau eine Sitzung, ihr Ende beendet die App */
@interface RRAppDelegate : NSObject <NSApplicationDelegate>
- (instancetype)initWithSession:(RRSession *)session;
@end

/* Oberfläche: Hauptfenster, Verknüpfungen (rdp-retina://open?app=…), Menüleiste */
@interface RRUIAppDelegate : NSObject <NSApplicationDelegate>
- (IBAction)showSettings:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
