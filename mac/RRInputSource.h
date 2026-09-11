/*
 * rdp-retina – Abfragen an HIToolbox (Carbon)
 *
 * Eigene Übersetzungseinheit: HIToolbox bindet CFPlugInCOM.h ein, und das definiert
 * REFIID anders als WinPR. Beide Welten dürfen sich deshalb nie in einer Datei treffen.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Windows-KLID des aktiven macOS-Tastaturlayouts, 0 = unbekannt */
uint32_t RRInputSourceLayoutId(void);

/* Tastatur mit ISO-Anordnung (vertauscht die Codes für ^ und <) */
BOOL RRInputSourceIsISO(void);

NS_ASSUME_NONNULL_END
