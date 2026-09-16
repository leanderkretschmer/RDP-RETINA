/*
 * rdp-retina – mehrere RemoteApps in einer Sitzung
 *
 * Windows gibt jedem Benutzer nur eine Sitzung (fSingleSessionPerUser); eine zweite Verbindung
 * verdrängt die erste. Deshalb übernimmt eine laufende Instanz weitere Programme: Sie lauscht
 * auf einem Unix-Socket je Server und Benutzer. Ein neuer Aufruf schickt ihr seine
 * /app:-Angaben, wartet auf die Bestätigung und beendet sich.
 */
#import <Foundation/Foundation.h>

#include <freerdp/settings.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RRShareResult) {
	RRShareNoInstance, /* keine laufende Instanz: selbst verbinden */
	RRShareDone,       /* übernommen */
	RRShareRefused,    /* Instanz läuft, hat abgelehnt */
};

@interface RRShare : NSObject

/* Socket für Server, Port, Domäne und Benutzer; nil ohne Server. */
+ (nullable NSString *)socketPathForSettings:(const rdpSettings *)settings;

+ (RRShareResult)handOffApps:(NSArray<NSString *> *)apps toPath:(NSString *)path;

/* Lauscht bis -invalidate. handler läuft einmal je Programm auf einer Nebenqueue – er darf den
 * Hauptthread nicht abwarten, der kann in einem Dialog stecken. */
- (nullable instancetype)initWithPath:(NSString *)path handler:(BOOL (^)(NSString *app))handler;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
