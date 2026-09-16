/*
 * rdp-retina – Brücke zwischen Kern und Cocoa
 */
#import <AppKit/AppKit.h>

#include "rr_core.h"

@class RRKeyboard;
@class RRRemoteWindow;
@class RRRenderer;
@class RRSession;
@class RRTexture;

NS_ASSUME_NONNULL_BEGIN

/* Für die Oberfläche, alle Aufrufe im Hauptthread */
@protocol RRSessionDelegate <NSObject>
/* Verbindung beendet: gewollt (error 0), vom Server oder durch einen Fehler. */
- (void)session:(RRSession *)session didEndWithError:(UINT32)error;
@optional
- (void)sessionDidConnect:(RRSession *)session;
/* RemoteApp-Kanal steht: Programme dürfen starten, offene Fenster werden gemeldet. */
- (void)sessionRailDidStart:(RRSession *)session;
/* Fenster angelegt, geändert, gelöscht oder einem Programm zugeordnet (-appWindows). */
- (void)sessionWindowsDidChange:(RRSession *)session;
@end

/*
 * Hält den Kern-Kontext und verteilt dessen Rückrufe (aus FreeRDP-Threads) an Desktop-
 * bzw. RemoteApp-Steuerung. Lebt im Hauptthread.
 */
@interface RRSession : NSObject

/* Kommandozeile: Ende der Verbindung beendet die App. */
- (nullable instancetype)initWithArgc:(int)argc argv:(char *_Nullable *_Nonnull)argv exitCode:(int *)exitCode;

/* Oberfläche: Argumente wie auf der Kommandozeile (arguments[0] = Programmname). Kennwort und
 * Zertifikat fragen Dialoge ab, das Ende der Verbindung meldet der Delegate. */
- (nullable instancetype)initWithArguments:(NSArray<NSString *> *)arguments
                                  delegate:(id<RRSessionDelegate>)delegate
                                  exitCode:(int *)exitCode;

@property (nonatomic, readonly) rrContext *rr;
@property (nonatomic, readonly) RRRenderer *renderer;
@property (nonatomic, readonly) RRKeyboard *keyboard;
@property (nonatomic, readonly, nullable) NSScreen *primaryScreen;
/* Pixel je Punkt am primären Bildschirm (Retina: 2) */
@property (nonatomic, readonly) CGFloat scale;
@property (nonatomic, readonly) NSCursor *cursor;
@property (atomic, readonly, nullable) RRTexture *desktopTexture;
@property (nonatomic) int exitCode;

@property (nonatomic, weak, readonly, nullable) id<RRSessionDelegate> delegate;
/* Server, wie auf der Kommandozeile angegeben */
@property (nonatomic, readonly, copy) NSString *serverName;
@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly) BOOL railStarted;

/* /retina-verbose: Fensterverwaltung protokollieren; /retina-selftest: Pixeltest (P2) */
@property (nonatomic, readonly) BOOL verbose;
@property (nonatomic, readonly) BOOL selfTest;

- (BOOL)start;
- (void)stop;

/* Weiteres Programm in dieser Sitzung, Angabe wie bei /app: */
- (BOOL)launchApp:(NSString *)app;

/* RemoteApp-Fenster (Hauptthread) */
- (NSArray<RRRemoteWindow *> *)appWindows;
- (void)moveRemoteWindow:(UINT32)windowId toRect:(rrRect)rect;
- (void)showRemoteWindow:(UINT32)windowId;
- (void)setRemoteWindow:(UINT32)windowId maximized:(BOOL)maximized minimized:(BOOL)minimized;
/* Von RRRailController: Fenster haben sich geändert */
- (void)remoteWindowsDidChange;

/* Globale Punkte (macOS, y nach oben) <-> Server-Pixel (y nach unten) */
- (NSPoint)serverPointFromScreenPoint:(NSPoint)point;
- (NSRect)screenFrameForServerRect:(rrRect)rect;

- (void)sendScrollWheel:(NSEvent *)event;
- (void)appDidBecomeActive;
- (void)appDidResignActive;

@end

NS_ASSUME_NONNULL_END
