/*
 * rdp-retina – Sitzungen der Oberfläche
 *
 * Eine Sitzung je Server, denn Windows gibt jedem Benutzer nur eine. Sie verbindet im
 * RemoteApp-Modus ohne erstes Programm; so erscheinen Programme, die in der Windows-Sitzung noch
 * laufen, bevor etwas gestartet wird. Eine RemoteApp startet über rr_rail_launch – ist ihr
 * Programm dort schon offen, kommt stattdessen das Fenster nach vorn.
 *
 * Dazu die Höchstzahl gleichzeitig offener RemoteApps und der Arbeitsbereich: Lage aller Fenster
 * speichern und später – etwa nach einem Neustart beim Öffnen einer Verknüpfung – alle Programme
 * starten und ihre Fenster an dieselbe Stelle legen.
 *
 * Nur im Hauptthread.
 */
#import <AppKit/AppKit.h>

@class RRAppConfig;

NS_ASSUME_NONNULL_BEGIN

/* Sitzung verbunden oder getrennt, Fenster geöffnet oder geschlossen */
extern NSNotificationName const RRConnectionsDidChangeNotification;

typedef NS_ENUM(NSInteger, RRServerState) {
	RRServerStateDisconnected,
	RRServerStateConnecting,
	RRServerStateConnected,
};

@interface RRConnectionManager : NSObject

+ (RRConnectionManager *)shared;

/* Aus der Oberfläche (fromLink NO) oder einer Verknüpfung (YES; darf den Arbeitsbereich
 * wiederherstellen). Fehler zeigt der Manager selbst an. */
- (void)openApp:(RRAppConfig *)app fromLink:(BOOL)fromLink;

/* rdp-retina://open?app=<ID>. NO, wenn die Adresse nicht passt. */
- (BOOL)handleURL:(NSURL *)url;

- (RRServerState)stateForServerId:(NSString *)identifier;
/* Offene RemoteApps (Programme mit sichtbarem oder minimiertem Hauptfenster); nil = alle Server */
- (NSUInteger)openAppCountForServerId:(nullable NSString *)identifier;
- (void)disconnectServerId:(NSString *)identifier;

/* Arbeitsbereich: Lage aller zugeordneten Fenster speichern; Rückgabe = Zahl der Fenster. */
- (NSUInteger)saveWorkspace;
/* Gespeicherte Programme starten (bereits offene nicht doppelt) und Fenster platzieren. */
- (void)restoreWorkspace;

/* Beim Beenden: Arbeitsbereich merken, falls eingestellt, und alle Sitzungen trennen. */
- (void)shutdown;

@property (nonatomic, readonly) BOOL hasSessions;

@end

NS_ASSUME_NONNULL_END
