/*
 * rdp-retina – Verknüpfungen (Companion-Apps) für RemoteApps
 *
 * rdp-retina bringt eine kleine, signierte Vorlage mit (Contents/Helpers/RDP-Retina Link.app).
 * „Verknüpfung installieren“ kopiert sie an einen Ort, den der Benutzer im Sicherungsdialog
 * wählt, benennt sie nach der RemoteApp, setzt ihr Symbol (hochgeladenes Bild, unten rechts das
 * Symbol von rdp-retina) und hinterlegt die ID der RemoteApp als erweitertes Attribut. Die
 * Vorlage selbst bleibt dabei unverändert, ihre Signatur gültig.
 *
 * Gestartet liest die Kopie das Attribut, ruft rdp-retina://open?app=<ID> auf und beendet sich.
 * Ins Dock zieht der Benutzer sie selbst – eine App in der Sandbox darf das Dock nicht ändern.
 */
#import <AppKit/AppKit.h>

@class RRAppConfig;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const RRLinkURLScheme;     /* "rdp-retina" */
extern NSString *const RRLinkAppAttribute;  /* erweitertes Attribut mit der ID der RemoteApp */

/* Symbol der Verknüpfung: image quadratisch eingepasst, unten rechts das Symbol von rdp-retina.
 * Ohne image nur das Symbol von rdp-retina. Hauptthread. */
NSImage *RRLinkBadgedIcon(NSImage *_Nullable image);

@interface RRLinkInstaller : NSObject

/* rdp-retina://open?app=<ID> */
+ (NSURL *)URLForAppId:(NSString *)identifier;
/* ID aus einer solchen Adresse, sonst nil */
+ (nullable NSString *)appIdFromURL:(NSURL *)url;

/* Sicherungsdialog als Sheet an window (Vorgabe ~/Applications, Name der RemoteApp), dann
 * Verknüpfung anlegen und im Finder zeigen. completion im Hauptthread: Ort der Verknüpfung, oder
 * ein Fehler; beides nil, wenn der Benutzer abbricht. */
+ (void)installLinkForApp:(RRAppConfig *)app
                     icon:(nullable NSImage *)icon
                   window:(NSWindow *)window
               completion:(void (^)(NSURL *_Nullable link, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
