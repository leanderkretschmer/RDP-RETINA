/*
 * rdp-retina – interne Struktur des Kerns
 */
#ifndef RR_PRIVATE_H
#define RR_PRIVATE_H

#include <winpr/synch.h>
#include <winpr/wlog.h>

#include <freerdp/log.h>
#include <freerdp/client/rail.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/client/disp.h>

#include "rr_core.h"

#define RR_TAG CLIENT_TAG("retina")

typedef struct rr_rail_window rrRailWindow;

typedef struct
{
	BYTE* bgra;
	UINT32 width;
	UINT32 height;
} rrIcon;

struct rr_context
{
	rdpClientContext common; /* muss vorn stehen, FreeRDP castet den Kontext */

	rrFrontend fe;
	void* user;
	rrMode mode;
	wLog* log;

	/* Kommandozeile */
	char** options;
	size_t optionCount;
	BOOL sizeGiven;
	BOOL gfxGiven;

	rrScreen screens[RR_MAX_SCREENS];
	UINT32 screenCount;
	rrScreen primary;

	/* Kanäle */
	RailClientContext* rail;
	RdpgfxClientContext* gfx;
	DispClientContext* disp;

	/* Desktoppuffer: Zwischenablage für geänderte Rechtecke */
	rrRect* dirty;
	UINT32 dirtyCapacity;

	/* Display Control */
	CRITICAL_SECTION dispLock;
	BOOL dispReady;
	UINT32 dispWantWidth;
	UINT32 dispWantHeight;
	UINT32 dispSentWidth;
	UINT32 dispSentHeight;
	UINT64 dispSentAt;

	/* RemoteApp */
	CRITICAL_SECTION railLock;
	rrRailWindow** windows;
	size_t windowCount;
	size_t windowCapacity;
	rrIcon* icons;
	UINT32 iconCaches;
	UINT32 iconEntries;
	BOOL railActive;
	BOOL railExecSent;
	pcRailServerHandshake railHandshake;
	pcRailServerHandshakeEx railHandshakeEx;

	/* GFX */
	CRITICAL_SECTION statsLock;
	rrGfxStats stats;
	pcRdpgfxSurfaceCommand gfxSurfaceCommand;
	pcRdpgfxEndFrame gfxEndFrame;
};

/* rr_settings.c */
BOOL rr_settings_parse(rrContext* rr, int argc, char** argv, int* exitCode);
void rr_settings_free(rrContext* rr);

/* rr_gfx.c */
BOOL rr_gfx_init(rrContext* rr, RdpgfxClientContext* gfx);
void rr_gfx_uninit(rrContext* rr, RdpgfxClientContext* gfx);

/* rr_disp.c */
BOOL rr_disp_init(rrContext* rr, DispClientContext* disp);
void rr_disp_uninit(rrContext* rr, DispClientContext* disp);
void rr_disp_tick(rrContext* rr);

/* rr_rail.c */
BOOL rr_rail_init(rrContext* rr, RailClientContext* rail);
void rr_rail_uninit(rrContext* rr, RailClientContext* rail);
void rr_rail_register_orders(rrContext* rr, rdpWindowUpdate* window);
/* Alle Fenster verwerfen und der Oberfläche melden. */
void rr_rail_reset(rrContext* rr);
/* Speicher freigeben, ohne Rückrufe. */
void rr_rail_free(rrContext* rr);
void rr_rail_map_surface(rrContext* rr, UINT32 windowId, UINT16 surfaceId, BOOL mapped);
/* TRUE, wenn die Fläche neu zugeordnet wurde und daher vollständig übernommen werden muss. */
BOOL rr_rail_take_surface_change(rrContext* rr, UINT32 windowId, UINT16 surfaceId);

#endif /* RR_PRIVATE_H */
