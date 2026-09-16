/*
 * rdp-retina – Hauptfenster der Oberfläche
 *
 * Vier Bereiche in einer Symbolleiste, wie Systemeinstellungen früher:
 *   Server        mehrere RDP-Server mit Anmeldung (Kennwort im Schlüsselbund)
 *   RemoteApps    Programm, Name und Symbol je App; starten; Verknüpfung installieren
 *   Übertragung   Höchstzahl offener Apps, Wiederverbinden, Ton, Mikrofon, Zwischenablage, …
 *   Arbeitsbereich  Lage der Fenster speichern und wiederherstellen
 *
 * Öffnet sich, wenn rdp-retina ohne Argumente und ohne Verknüpfung gestartet wird, und beim
 * Klick auf das Dock-Symbol. Nur im Hauptthread.
 */
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RRSettingsWindowController : NSWindowController

+ (RRSettingsWindowController *)shared;

/* Fenster zeigen und die App nach vorn holen */
- (void)showAndActivate;

@end

NS_ASSUME_NONNULL_END
