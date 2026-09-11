/*
 * rdp-retina – portabler Kern
 *
 * Der Kern kapselt FreeRDP 3: Verbindung, Einstellungen (Pixelgröße, Skalierung, GFX),
 * RemoteApp-Zustand und die Weitergabe der Bilddaten. Eine Oberfläche (Cocoa-App,
 * Prüf-Client) bekommt fertige Ereignisse über rrFrontend und ruft für Eingaben und
 * Fensterbefehle die rr_*-Funktionen auf.
 *
 * Koordinaten sind durchgehend Server-Pixel im virtuellen Bildschirm von Windows: Ursprung
 * oben links am primären Bildschirm, y wächst nach unten (RemoteApp-Fenster, Bildschirme,
 * Mausereignisse). Einzige Ausnahme ist der Desktoppuffer: Er beginnt an der linken oberen
 * Ecke aller Bildschirme, bei /multimon also um rr_desktop_origin() verschoben.
 * Punkte im Sinne von macOS kennt der Kern nicht – die Umrechnung ist Sache der
 * Oberfläche, und genau dort darf nicht skaliert werden.
 */
#ifndef RR_CORE_H
#define RR_CORE_H

#include <winpr/wtypes.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/rail.h>
#include <freerdp/window.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define RR_MAX_SCREENS 16

	typedef struct rr_context rrContext;

	typedef struct
	{
		INT32 x;
		INT32 y;
		UINT32 width;
		UINT32 height;
	} rrRect;

	/* Ein lokaler Bildschirm. Alle Maße in Pixeln des Backing-Store, Server-Koordinaten. */
	typedef struct
	{
		rrRect frame;
		rrRect workArea;      /* ohne Menüleiste und Dock */
		UINT32 physicalWidthMm;
		UINT32 physicalHeightMm;
		UINT32 scalePercent;  /* backingScaleFactor * 100, auf Retina 200 */
		BOOL primary;
	} rrScreen;

	typedef enum
	{
		RR_MODE_DESKTOP,
		RR_MODE_REMOTEAPP
	} rrMode;

	/* Momentaufnahme eines entfernten Fensters. Zeiger gelten nur während des Aufrufs. */
	typedef struct
	{
		UINT32 id;
		UINT32 ownerId;
		UINT32 style;
		UINT32 exStyle;
		UINT32 showState;      /* WINDOW_HIDE, WINDOW_SHOW_MINIMIZED, ... */
		rrRect rect;           /* windowOffset/windowSize, ohne unsichtbare Ränder */
		rrRect client;         /* Client-Bereich, absolut */
		INT32 visibleOffsetX;
		INT32 visibleOffsetY;
		UINT32 numVisibilityRects;
		const RECTANGLE_16* visibilityRects;
		UINT32 marginLeft;     /* unsichtbare Größenänderungsränder */
		UINT32 marginTop;
		UINT32 marginRight;
		UINT32 marginBottom;
		const char* title;     /* UTF-8, nie NULL */
		BOOL surfaceMapped;    /* Inhalt kommt aus eigener GFX-Fläche statt aus dem Desktop */
	} rrWindow;

	typedef struct
	{
		UINT32 capsVersion;    /* bestätigte GFX-Version, 0 = kein GFX */
		UINT32 capsFlags;
		UINT64 frames;
		UINT64 surfaceCommands;
		UINT64 codec[16];      /* Anzahl Flächenbefehle je RDPGFX_CODECID_* */
	} rrGfxStats;

	/*
	 * Rückrufe an die Oberfläche. Alle kommen aus Threads von FreeRDP (RDP-Thread oder
	 * Kanal-Thread), nie aus dem UI-Thread. Nicht belegte Einträge dürfen NULL sein.
	 * Rückgabe FALSE bricht die Verbindung ab.
	 */
	typedef struct
	{
		/* Verbindung steht, Desktoppuffer hat width x height Pixel. */
		BOOL (*Connected)(rrContext* rr, UINT32 width, UINT32 height);
		/* Verbindung beendet oder gescheitert. error = freerdp_get_last_error(). */
		void (*Disconnected)(rrContext* rr, UINT32 error);

		/* Sitzungsgröße geändert; der Desktoppuffer ist neu angelegt. */
		BOOL (*DesktopResized)(rrContext* rr, UINT32 width, UINT32 height);
		/* Geänderte Bereiche im Desktoppuffer (BGRX, 4 Byte je Pixel). Der Puffer wird
		 * während des Aufrufs nicht beschrieben. */
		BOOL (*DesktopUpdated)(rrContext* rr, const BYTE* buffer, UINT32 stride,
		                       const rrRect* rects, UINT32 count);

		/* RemoteApp */
		BOOL (*RailStarted)(rrContext* rr);
		BOOL (*WindowChanged)(rrContext* rr, const rrWindow* window, UINT32 fieldFlags,
		                      BOOL created);
		BOOL (*WindowDeleted)(rrContext* rr, UINT32 windowId);
		BOOL (*WindowIcon)(rrContext* rr, UINT32 windowId, BOOL big, const BYTE* bgra,
		                   UINT32 width, UINT32 height);
		/* ACTIVE_WND und/oder ZORDER (fieldFlags zeigt, was gültig ist). zorder: oben zuerst. */
		BOOL (*DesktopState)(rrContext* rr, UINT32 fieldFlags, UINT32 activeWindowId,
		                     const UINT32* zorder, UINT32 count);
		/* Fensterinhalt aus eigener GFX-Fläche (BGRA). full = ganze Fläche neu übernehmen,
		 * alpha = Fläche trägt Transparenz (sonst ist der Alphakanal bedeutungslos). */
		BOOL (*WindowSurface)(rrContext* rr, UINT32 windowId, const BYTE* data, UINT32 stride,
		                      UINT32 width, UINT32 height, const rrRect* rects, UINT32 count,
		                      BOOL full, BOOL alpha);
		void (*WindowSurfaceUnmapped)(rrContext* rr, UINT32 windowId);
		/* Server startet/beendet ein lokales Verschieben oder Größeändern (RAIL_WMSZ_*).
		 * Bei RAIL_WMSZ_MOVE ist (x, y) relativ zum Fenster, sonst absolut. */
		BOOL (*LocalMoveSize)(rrContext* rr, UINT32 windowId, BOOL start, UINT16 type, INT32 x,
		                      INT32 y);
		BOOL (*MinMaxInfo)(rrContext* rr, const RAIL_MINMAXINFO_ORDER* info);
		BOOL (*WindowCloak)(rrContext* rr, UINT32 windowId, BOOL cloaked);
		/* Tray-Symbole. tooltip NULL bzw. bgra NULL = unverändert. */
		BOOL (*NotifyIconChanged)(rrContext* rr, UINT32 windowId, UINT32 iconId,
		                          const char* tooltip, const BYTE* bgra, UINT32 width,
		                          UINT32 height);
		BOOL (*NotifyIconDeleted)(rrContext* rr, UINT32 windowId, UINT32 iconId);

		/* Mauszeiger. PointerNew liefert ein Handle der Oberfläche (NULL erlaubt). */
		void* (*PointerNew)(rrContext* rr, const BYTE* bgra, UINT32 width, UINT32 height,
		                    UINT32 hotX, UINT32 hotY);
		void (*PointerFree)(rrContext* rr, void* handle);
		BOOL (*PointerSet)(rrContext* rr, void* handle); /* handle NULL = unsichtbar */
		BOOL (*PointerSetDefault)(rrContext* rr);
		BOOL (*PointerSetPosition)(rrContext* rr, UINT32 x, UINT32 y);

		/* Kanäle, die der Kern nicht selbst bedient (z.B. cliprdr für die Zwischenablage). */
		void (*ChannelConnected)(rrContext* rr, const char* name, void* iface);
		void (*ChannelDisconnected)(rrContext* rr, const char* name, void* iface);
	} rrFrontend;

	/* ---- Lebenszyklus ---------------------------------------------------------------- */

	/* Legt den Kontext an und wertet die Kommandozeile aus (FreeRDP-kompatibel).
	 * Eigene Schalter beginnen mit /retina- bzw. /probe- und werden vorher herausgefiltert.
	 * NULL: nichts zu verbinden (Hilfe, Version, Fehler) – *exitCode ist dann gesetzt. */
	rrContext* rr_new(const rrFrontend* frontend, void* user, int argc, char** argv,
	                  int* exitCode);
	void rr_free(rrContext* rr);

	void* rr_user(rrContext* rr);
	rdpContext* rr_rdp(rrContext* rr);
	rdpSettings* rr_settings(rrContext* rr);
	rrMode rr_mode(rrContext* rr);

	/* Wert eines eigenen Schalters, z.B. rr_option(rr, "retina-cmd") für /retina-cmd:win.
	 * "" = Schalter ohne Wert, NULL = nicht angegeben. */
	const char* rr_option(rrContext* rr, const char* name);

	/* TRUE, wenn /size, /w oder /h ausdrücklich angegeben wurde. */
	BOOL rr_size_given(rrContext* rr);

	/*
	 * Legt die Sitzungsgeometrie fest. Muss vor rr_start aufgerufen werden.
	 * Die Sitzungsgröße ergibt sich in dieser Reihenfolge:
	 *   RemoteApp oder /f      -> Pixelgröße des primären Bildschirms
	 *   /size:N%               -> Anteil der nutzbaren Fläche
	 *   /size:WxH, /w, /h      -> wie angegeben
	 *   sonst                  -> defaultWidth x defaultHeight (0 = nutzbare Fläche)
	 * Nie 1024x768 aus Versehen.
	 */
	BOOL rr_configure(rrContext* rr, const rrScreen* screens, UINT32 count, UINT32 defaultWidth,
	                  UINT32 defaultHeight);

	BOOL rr_start(rrContext* rr);
	void rr_stop(rrContext* rr);

	/* W3 (/multimon): Sitzung über mehrere Bildschirme. Die linke obere Ecke des
	 * Desktoppuffers relativ zum primären Bildschirm; ohne /multimon (0, 0). */
	BOOL rr_multimon(rrContext* rr);
	void rr_desktop_origin(rrContext* rr, INT32* x, INT32* y);

	/* ---- Eingabe (aus jedem Thread) -------------------------------------------------- */

	BOOL rr_mouse_move(rrContext* rr, INT32 x, INT32 y);
	/* button: 0 links, 1 rechts, 2 Mitte, 3 X1, 4 X2 */
	BOOL rr_mouse_button(rrContext* rr, UINT32 button, BOOL down, INT32 x, INT32 y);
	/* 120 Einheiten = eine Rastung. Positiv = nach oben bzw. nach rechts. */
	BOOL rr_mouse_wheel(rrContext* rr, BOOL horizontal, INT32 units);
	/* rdpScancode wie RDP_SCANCODE_* (inkl. KBDEXT) */
	BOOL rr_key_scancode(rrContext* rr, UINT32 rdpScancode, BOOL down, BOOL repeat);
	BOOL rr_key_unicode(rrContext* rr, UINT16 codeUnit, BOOL down);
	BOOL rr_focus_in(rrContext* rr, BOOL capsLock, BOOL numLock);
	/* Apple-Tastencode (NSEvent.keyCode) -> RDP-Scancode, 0 = keine Zuordnung.
	 * iso = ISO-Tastatur (vertauscht ^/< wie bei Apple üblich). */
	UINT32 rr_scancode_from_apple_keycode(UINT32 keycode, BOOL iso);

	/* ---- Anzeige --------------------------------------------------------------------- */

	/* Neue Sitzungsgröße über Display Control anfordern (nur mit /dynamic-resolution). */
	BOOL rr_request_size(rrContext* rr, UINT32 width, UINT32 height);
	/* Bildübertragung anhalten, z.B. wenn das Fenster minimiert ist. */
	BOOL rr_suppress_output(rrContext* rr, BOOL suppress);
	BOOL rr_gfx_stats(rrContext* rr, rrGfxStats* stats);
	const char* rr_codec_name(UINT32 codecId);

	/* ---- RemoteApp (aus jedem Thread) ------------------------------------------------ */

	BOOL rr_rail_activate(rrContext* rr, UINT32 windowId, BOOL active);
	/* SC_MINIMIZE, SC_MAXIMIZE, SC_RESTORE, SC_CLOSE, ... */
	BOOL rr_rail_command(rrContext* rr, UINT32 windowId, UINT16 command);
	/* Neue Lage eines Fensters melden; rect im Sinne von rrWindow.rect. */
	BOOL rr_rail_move(rrContext* rr, UINT32 windowId, const rrRect* rect);
	/* Lokales Verschieben/Größeändern abschließen: Lage melden, dann Maustaste loslassen
	 * (MS-RDPERP 3.2.5.1.7). keyboard = TRUE bei RAIL_WMSZ_KEYMOVE/KEYSIZE. */
	BOOL rr_rail_end_local_move(rrContext* rr, UINT32 windowId, const rrRect* rect,
	                            INT32 cursorX, INT32 cursorY, BOOL keyboard);
	BOOL rr_rail_system_menu(rrContext* rr, UINT32 windowId, INT32 x, INT32 y);
	BOOL rr_rail_work_area(rrContext* rr, const rrRect* area);
	/* Mausereignis an ein Tray-Symbol: WM_LBUTTONUP, WM_CONTEXTMENU, NIN_SELECT, ... */
	BOOL rr_rail_notify_event(rrContext* rr, UINT32 windowId, UINT32 iconId, UINT32 message);
	/* Aktuellen Zustand eines Fensters holen (title und visibilityRects bleiben NULL). */
	BOOL rr_rail_get_window(rrContext* rr, UINT32 windowId, rrWindow* window);

#ifdef __cplusplus
}
#endif

#endif /* RR_CORE_H */
