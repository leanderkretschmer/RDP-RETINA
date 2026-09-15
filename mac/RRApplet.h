/*
 * rdp-retina – Applets für das Dock
 *
 * Ein Applet ist ein kleines App-Bundle, dessen Programm nur rdp-retina mit gespeicherten
 * Argumenten startet. Damit öffnet ein Klick im Dock genau eine RemoteApp:
 *
 *   rdp-retina --createapp /v:server /u:benutzer /p:kennwort /app:||notepad \
 *              --appname=Editor --icon=~/Bilder/editor.png
 */
#ifndef RR_APPLET_H
#define RR_APPLET_H

#import <Foundation/Foundation.h>

/* YES, wenn --createapp unter den Argumenten steht. */
BOOL RRAppletRequested(int argc, char **argv);

/* Legt das Applet an und liefert den Exit-Code des Programms. */
int RRAppletMain(int argc, char **argv);

#endif /* RR_APPLET_H */
