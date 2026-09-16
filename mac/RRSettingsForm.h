/*
 * rdp-retina – Bausteine für die Formulare des Hauptfensters
 *
 * Beschriftungen, Felder, Raster, Listen mit Hinzufügen/Entfernen und Meldungen, damit die
 * vier Bereiche gleich aussehen. Nur im Hauptthread.
 */
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/* Breite der Eingabefelder und größte Breite von Fließtexten */
extern const CGFloat RRFormFieldWidth;
extern const CGFloat RRFormTextWidth;

/* Leerzeichen und Zeilenumbrüche an den Enden entfernen */
NSString *RRFormTrimmed(NSString *text);

/* Beschriftung links im Formular, rechtsbündig */
NSTextField *RRFormLabel(NSString *text);
/* Eingabefelder; delegate bekommt controlTextDidChange: und controlTextDidEndEditing: */
NSTextField *RRFormTextField(NSString *placeholder, id<NSTextFieldDelegate> delegate);
NSSecureTextField *RRFormSecureField(NSString *placeholder, id<NSTextFieldDelegate> delegate);
/* Fließtext in kleiner, gedämpfter Schrift */
NSTextField *RRFormHint(NSString *text);
/* Fette Überschrift eines Bereichs */
NSTextField *RRFormHeadline(NSString *text);

/* Zweispaltiges Raster: Beschriftung | Inhalt. Jede Zeile hat genau zwei Einträge, leere Zellen
 * sind NSGridCell.emptyContentView. */
NSGridView *RRFormGrid(NSArray<NSArray<NSView *> *> *rows);
/* Stapel nebeneinander (mittig) bzw. untereinander (linksbündig) */
NSStackView *RRFormRow(NSArray<NSView *> *views);
NSStackView *RRFormColumn(NSArray<NSView *> *views);

/* Einspaltige Liste ohne Kopfzeile in einer Scroll-Ansicht */
NSScrollView *RRFormTableScrollView(NSTableView *tableView, CGFloat rowHeight);
/* „+“ und „−“ unter einer Liste; action bekommt das Steuerelement, selectedSegment 0 oder 1 */
NSSegmentedControl *RRFormAddRemoveControl(id target, SEL action);
/* Liste links mit Knöpfen darunter, Inhalt rechts oben */
NSView *RRFormMasterDetail(NSScrollView *list, NSSegmentedControl *buttons, NSView *detail);
/* Inhalt oben links mit Rand */
NSView *RRFormPage(NSView *content);

/* Text setzen, außer der Benutzer bearbeitet das Feld gerade */
void RRFormSetString(NSTextField *field, NSString *value);
/* Laufende Eingabe im Fenster abschließen (speichert das Feld); NO, wenn es sie nicht hergibt */
BOOL RRFormEndEditing(NSWindow *_Nullable window);

/* Farbiger Punkt, z.B. für den Verbindungsstatus */
NSImage *RRFormDotImage(NSColor *color);

/* Meldung als Sheet an window, ohne Fenster als eigenes Fenster */
void RRFormShowAlert(NSWindow *_Nullable window, NSString *message, NSString *_Nullable information,
                     NSAlertStyle style);
void RRFormShowError(NSWindow *_Nullable window, NSString *message, NSError *_Nullable error);

NS_ASSUME_NONNULL_END
