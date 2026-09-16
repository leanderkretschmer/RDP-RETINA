/*
 * rdp-retina – RemoteApp-Fenster (Stufen 2 bis 4)
 */
#import <AppKit/AppKit.h>

#include "rr_core.h"

@class RRSession;

NS_ASSUME_NONNULL_BEGIN

/* Hauptfenster eines Windows-Programms, Momentaufnahme im Hauptthread */
@interface RRRemoteWindow : NSObject
@property (nonatomic, readonly) UINT32 windowId;
@property (nonatomic, readonly) rrRect rect; /* Server-Pixel; minimiert die letzte echte Lage */
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *applicationId; /* "" = noch nicht gemeldet */
@property (nonatomic, readonly) BOOL minimized;
@property (nonatomic, readonly) BOOL maximized;
@end

@interface RRRailController : NSObject

- (instancetype)initWithSession:(RRSession *)session;

/* Dock-Symbol auf das große Symbol der ersten Windows-Anwendung setzen (Vorgabe YES).
 * Die Oberfläche mit mehreren Servern und Programmen behält ihr eigenes Symbol. */
@property (nonatomic) BOOL updatesApplicationIcon;

/* Aus Kanal-Threads: App-ID bzw. Programm eines Fensters (rrFrontend.WindowProcess) */
- (void)windowProcess:(UINT32)windowId applicationId:(NSString *)applicationId;

/* Hauptthread: Fenster für die Oberfläche. Hauptfenster = ohne Besitzer, kein
 * Werkzeugfenster, nicht versteckt, mit Fläche. Änderungen meldet -[RRSession
 * remoteWindowsDidChange]. */
- (NSArray<RRRemoteWindow *> *)appWindows;
- (void)moveWindow:(UINT32)windowId toRect:(rrRect)rect;
/* Wiederherstellen, falls minimiert, und nach vorn holen */
- (void)showWindow:(UINT32)windowId;
- (void)setWindow:(UINT32)windowId maximized:(BOOL)maximized minimized:(BOOL)minimized;

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
