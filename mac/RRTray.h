/*
 * rdp-retina – Tray-Symbole entfernter Anwendungen in der Menüleiste (Stufe 4)
 */
#import <AppKit/AppKit.h>

#include <winpr/wtypes.h>

@class RRSession;

NS_ASSUME_NONNULL_BEGIN

@interface RRTray : NSObject

- (instancetype)initWithSession:(RRSession *)session;

/* Hauptthread */
- (void)iconChanged:(UINT32)windowId
             iconId:(UINT32)iconId
            tooltip:(nullable NSString *)tooltip
              image:(nullable NSImage *)image;
- (void)iconDeleted:(UINT32)windowId iconId:(UINT32)iconId;
- (void)removeAll;

@end

NS_ASSUME_NONNULL_END
