/*
 * rdp-retina – Kennwörter im Schlüsselbund
 *
 * Ein Applet (siehe RRApplet) darf kein Kennwort enthalten: sein Programm ist ein lesbares
 * Skript. Das Kennwort liegt deshalb als generisches Kennwort im Anmelde-Schlüsselbund,
 * Dienst "rdp-retina", Konto "[domäne\benutzer]@host[:port]" in Kleinschreibung.
 */
#ifndef RR_CREDENTIALS_H
#define RR_CREDENTIALS_H

#import <Foundation/Foundation.h>

#include <freerdp/settings.h>

NS_ASSUME_NONNULL_BEGIN

/* Konto zu den Angaben in settings; nil, wenn Benutzer oder Server fehlt. */
NSString *_Nullable RRCredentialsAccount(rdpSettings *settings);

/* Kennwort ablegen oder ein vorhandenes ersetzen. */
BOOL RRCredentialsStore(NSString *account, NSString *password, NSError *_Nullable *_Nullable error);

/* Ohne Kennwort in settings eines aus dem Schlüsselbund einsetzen. YES, wenn eingesetzt. */
BOOL RRCredentialsApply(rdpSettings *settings);

NS_ASSUME_NONNULL_END

#endif /* RR_CREDENTIALS_H */
