/*
 * rdp-retina – RemoteApp-Fenster (Stufen 2 bis 4)
 */
#import <AppKit/AppKit.h>

#include "rr_core.h"

@class RRSession;

NS_ASSUME_NONNULL_BEGIN

@interface RRRailController : NSObject

- (instancetype)initWithSession:(RRSession *)session;

/* Aus FreeRDP-Threads */
- (void)windowChanged:(const rrWindow *)window fields:(UINT32)fields created:(BOOL)created;
- (void)windowDeleted:(UINT32)windowId;
- (void)desktopStateFields:(UINT32)fields
                    active:(UINT32)activeWindowId
                    zorder:(const UINT32 *_Nullable)zorder
                     count:(UINT32)count;
- (BOOL)windowSurface:(UINT32)windowId
                 data:(const BYTE *)data
               stride:(UINT32)stride
                width:(UINT32)width
               height:(UINT32)height
                rects:(const rrRect *)rects
                count:(UINT32)count
                 full:(BOOL)full
                alpha:(BOOL)alpha;
- (void)desktopUpdated;
- (void)localMoveSize:(UINT32)windowId start:(BOOL)start type:(UINT16)type x:(INT32)x y:(INT32)y;
- (void)minMaxInfo:(const RAIL_MINMAXINFO_ORDER *)info;
- (void)windowCloak:(UINT32)windowId cloaked:(BOOL)cloaked;

/* Hauptthread */
- (void)windowIcon:(UINT32)windowId big:(BOOL)big image:(NSImage *)image;
- (void)cursorChanged;
- (void)closeAll;

@end

NS_ASSUME_NONNULL_END
