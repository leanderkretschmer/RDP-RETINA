/*
 * rdp-retina – Anwendung und Delegate
 */
#import <AppKit/AppKit.h>

@class RRSession;

NS_ASSUME_NONNULL_BEGIN

/* Reicht keyUp bei gedrückter Befehlstaste weiter, das AppKit sonst verschluckt. */
@interface RRApplication : NSApplication
@end

@interface RRAppDelegate : NSObject <NSApplicationDelegate>
- (instancetype)initWithSession:(RRSession *)session;
@end

NS_ASSUME_NONNULL_END
