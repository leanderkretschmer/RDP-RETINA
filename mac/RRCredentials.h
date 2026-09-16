/*
 * rdp-retina – Kennwörter im Schlüsselbund
 *
 * Weder ein Applet (siehe RRApplet) noch die Einstellungen der Oberfläche enthalten Kennwörter.
 * Sie liegen als generisches Kennwort im Anmelde-Schlüsselbund, Dienst "rdp-retina", Konto
 * "[domäne\benutzer]@host[:port]" in Kleinschreibung.
 */
#ifndef RR_CREDENTIALS_H
#define RR_CREDENTIALS_H

#import <Foundation/Foundation.h>

#include <freerdp/settings.h>

NS_ASSUME_NONNULL_BEGIN

/* Konto zu den Angaben in settings; nil, wenn Benutzer oder Server fehlt. */
NSString *_Nullable RRCredentialsAccount(rdpSettings *settings);

/* Dasselbe aus Einzelangaben (port 0 oder 3389 = Standard). */
NSString *_Nullable RRCredentialsAccountFor(NSString *host, NSUInteger port,
                                            NSString *_Nullable domain, NSString *_Nullable user);

/* Kennwort ablegen oder ein vorhandenes ersetzen. */
BOOL RRCredentialsStore(NSString *account, NSString *password, NSError *_Nullable *_Nullable error);

/* Gespeichertes Kennwort, nil = keins */
NSString *_Nullable RRCredentialsPassword(NSString *account);

/* Kennwort löschen; YES auch, wenn keins gespeichert war. */
BOOL RRCredentialsDelete(NSString *account, NSError *_Nullable *_Nullable error);

/* Ohne Kennwort in settings eines aus dem Schlüsselbund einsetzen. YES, wenn eingesetzt. */
BOOL RRCredentialsApply(rdpSettings *settings);

NS_ASSUME_NONNULL_END

#endif /* RR_CREDENTIALS_H */
