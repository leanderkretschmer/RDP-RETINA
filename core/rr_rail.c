/*
 * rdp-retina – RemoteApp (MS-RDPERP)
 *
 * Die Protokollschicht liefert FreeRDP (channels/rail). Hier liegt der Fensterzustand:
 * Anlegen, Aktualisieren, Löschen, Symbole, Fokus (ACTIVE_WND), Reihenfolge (ZORDER),
 * lokales Verschieben – und die Befehle in Gegenrichtung.
 *
 * Fensterbefehle kommen im RDP-Thread, Kanal-PDUs im Kanal-Thread, Befehle der Oberfläche
 * aus dem UI-Thread. Deshalb liegt alles unter railLock, und die Oberfläche bekommt nur
 * Kopien – ihre Rückrufe laufen ohne gehaltene Sperre.
 */
#include <stdlib.h>
#include <string.h>

#include <winpr/crt.h>

#include <freerdp/rail.h>
#include <freerdp/window.h>
#include <freerdp/settings.h>
#include <freerdp/codec/color.h>
#include <freerdp/client/rail.h>

#include "rr_private.h"

struct rr_rail_window
{
	UINT32 id;
	UINT32 ownerId;
	UINT32 style;
	UINT32 exStyle;
	UINT32 showState;
	rrRect rect;
	INT32 clientOffsetX;
	INT32 clientOffsetY;
	UINT32 clientWidth;
	UINT32 clientHeight;
	INT32 visibleOffsetX;
	INT32 visibleOffsetY;
	UINT32 numVisibilityRects;
	RECTANGLE_16* visibilityRects;
	UINT32 marginLeft;
	UINT32 marginTop;
	UINT32 marginRight;
	UINT32 marginBottom;
	char* title;
	UINT16 surfaceId;
	BOOL surfaceMapped;
	BOOL surfaceChanged;
};

typedef struct
{
	rrWindow view;
	char* title;
	RECTANGLE_16* rects;
} rrWindowCopy;

static rrContext* rr_from_rail(RailClientContext* rail)
{
	return rail ? (rrContext*)rail->custom : NULL;
}

/* ---- Fenstertabelle (railLock gehalten) ---------------------------------------------- */

static void rr_window_free(rrRailWindow* window)
{
	if (!window)
		return;
	free(window->visibilityRects);
	free(window->title);
	free(window);
}

static size_t rr_window_index(const rrContext* rr, UINT32 id)
{
	for (size_t i = 0; i < rr->windowCount; i++)
	{
		if (rr->windows[i]->id == id)
			return i;
	}
	return SIZE_MAX;
}

static rrRailWindow* rr_window_find(const rrContext* rr, UINT32 id)
{
	const size_t index = rr_window_index(rr, id);
	return (index == SIZE_MAX) ? NULL : rr->windows[index];
}

static rrRailWindow* rr_window_add(rrContext* rr, UINT32 id)
{
	if (rr->windowCount == rr->windowCapacity)
	{
		const size_t capacity = MAX(rr->windowCapacity * 2, 16);
		rrRailWindow** tmp = realloc(rr->windows, capacity * sizeof(rrRailWindow*));
		if (!tmp)
			return NULL;
		rr->windows = tmp;
		rr->windowCapacity = capacity;
	}

	rrRailWindow* window = calloc(1, sizeof(rrRailWindow));
	if (!window)
		return NULL;
	window->id = id;
	rr->windows[rr->windowCount++] = window;
	return window;
}

static BOOL rr_window_copy(const rrRailWindow* w, rrWindowCopy* copy)
{
	memset(copy, 0, sizeof(*copy));

	copy->title = _strdup(w->title ? w->title : "");
	if (!copy->title)
		return FALSE;

	if (w->numVisibilityRects > 0)
	{
		copy->rects = calloc(w->numVisibilityRects, sizeof(RECTANGLE_16));
		if (!copy->rects)
		{
			free(copy->title);
			return FALSE;
		}
		memcpy(copy->rects, w->visibilityRects, w->numVisibilityRects * sizeof(RECTANGLE_16));
	}

	rrWindow* v = &copy->view;
	v->id = w->id;
	v->ownerId = w->ownerId;
	v->style = w->style;
	v->exStyle = w->exStyle;
	v->showState = w->showState;
	v->rect = w->rect;
	v->client.x = w->clientOffsetX;
	v->client.y = w->clientOffsetY;
	v->client.width = w->clientWidth;
	v->client.height = w->clientHeight;
	v->visibleOffsetX = w->visibleOffsetX;
	v->visibleOffsetY = w->visibleOffsetY;
	v->numVisibilityRects = copy->rects ? w->numVisibilityRects : 0;
	v->visibilityRects = copy->rects;
	v->marginLeft = w->marginLeft;
	v->marginTop = w->marginTop;
	v->marginRight = w->marginRight;
	v->marginBottom = w->marginBottom;
	v->title = copy->title;
	v->surfaceMapped = w->surfaceMapped;
	return TRUE;
}

static void rr_window_copy_free(rrWindowCopy* copy)
{
	free(copy->title);
	free(copy->rects);
}

/* ---- Fensterbefehle (RDP-Thread) ----------------------------------------------------- */

static BOOL rr_window_common(rdpContext* context, const WINDOW_ORDER_INFO* info,
                             const WINDOW_STATE_ORDER* state)
{
	rrContext* rr = (rrContext*)context;
	const UINT32 f = info->fieldFlags;
	BOOL created = FALSE;
	rrWindowCopy copy;

	EnterCriticalSection(&rr->railLock);

	rrRailWindow* w = rr_window_find(rr, info->windowId);
	if (!w)
	{
		w = rr_window_add(rr, info->windowId);
		if (!w)
		{
			LeaveCriticalSection(&rr->railLock);
			return FALSE;
		}
		created = TRUE;
	}

	if (f & WINDOW_ORDER_FIELD_OWNER)
		w->ownerId = state->ownerWindowId;

	if (f & WINDOW_ORDER_FIELD_STYLE)
	{
		w->style = state->style;
		w->exStyle = state->extendedStyle;
	}

	if (f & WINDOW_ORDER_FIELD_SHOW)
		w->showState = state->showState;

	if (f & WINDOW_ORDER_FIELD_TITLE)
	{
		char* title = rail_string_to_utf8_string(&state->titleInfo);
		if (title)
		{
			free(w->title);
			w->title = title;
		}
	}

	if (f & WINDOW_ORDER_FIELD_CLIENT_AREA_OFFSET)
	{
		w->clientOffsetX = state->clientOffsetX;
		w->clientOffsetY = state->clientOffsetY;
	}

	if (f & WINDOW_ORDER_FIELD_CLIENT_AREA_SIZE)
	{
		w->clientWidth = state->clientAreaWidth;
		w->clientHeight = state->clientAreaHeight;
	}

	if (f & WINDOW_ORDER_FIELD_RESIZE_MARGIN_X)
	{
		w->marginLeft = state->resizeMarginLeft;
		w->marginRight = state->resizeMarginRight;
	}

	if (f & WINDOW_ORDER_FIELD_RESIZE_MARGIN_Y)
	{
		w->marginTop = state->resizeMarginTop;
		w->marginBottom = state->resizeMarginBottom;
	}

	if (f & WINDOW_ORDER_FIELD_WND_OFFSET)
	{
		w->rect.x = state->windowOffsetX;
		w->rect.y = state->windowOffsetY;
	}

	if (f & WINDOW_ORDER_FIELD_WND_SIZE)
	{
		w->rect.width = state->windowWidth;
		w->rect.height = state->windowHeight;
	}

	if (f & WINDOW_ORDER_FIELD_VIS_OFFSET)
	{
		w->visibleOffsetX = state->visibleOffsetX;
		w->visibleOffsetY = state->visibleOffsetY;
	}

	if (f & WINDOW_ORDER_FIELD_VISIBILITY)
	{
		free(w->visibilityRects);
		w->visibilityRects = NULL;
		w->numVisibilityRects = 0;

		if ((state->numVisibilityRects > 0) && state->visibilityRects)
		{
			w->visibilityRects = calloc(state->numVisibilityRects, sizeof(RECTANGLE_16));
			if (w->visibilityRects)
			{
				memcpy(w->visibilityRects, state->visibilityRects,
				       state->numVisibilityRects * sizeof(RECTANGLE_16));
				w->numVisibilityRects = state->numVisibilityRects;
			}
		}
	}

	const BOOL copied = rr_window_copy(w, &copy);
	LeaveCriticalSection(&rr->railLock);

	if (!copied)
		return FALSE;

	WLog_Print(rr->log, WLOG_DEBUG,
	           "Fenster 0x%08" PRIX32 " %s: %" PRId32 ",%" PRId32 " %" PRIu32 "x%" PRIu32
	           " show=%" PRIu32 " \"%s\"",
	           copy.view.id, created ? "neu" : "geändert", copy.view.rect.x, copy.view.rect.y,
	           copy.view.rect.width, copy.view.rect.height, copy.view.showState, copy.view.title);

	BOOL rc = TRUE;
	if (rr->fe.WindowChanged)
		rc = rr->fe.WindowChanged(rr, &copy.view, f, created);
	rr_window_copy_free(&copy);
	return rc;
}

static BOOL rr_window_delete(rdpContext* context, const WINDOW_ORDER_INFO* info)
{
	rrContext* rr = (rrContext*)context;
	rrRailWindow* window = NULL;

	EnterCriticalSection(&rr->railLock);
	const size_t index = rr_window_index(rr, info->windowId);
	if (index != SIZE_MAX)
	{
		window = rr->windows[index];
		memmove(&rr->windows[index], &rr->windows[index + 1],
		        (rr->windowCount - index - 1) * sizeof(rrRailWindow*));
		rr->windowCount--;
	}
	LeaveCriticalSection(&rr->railLock);

	if (!window)
		return TRUE;

	rr_window_free(window);
	WLog_Print(rr->log, WLOG_DEBUG, "Fenster 0x%08" PRIX32 " gelöscht", info->windowId);

	if (rr->fe.WindowDeleted)
		return rr->fe.WindowDeleted(rr, info->windowId);
	return TRUE;
}

/* MS-RDPERP 2.2.1.2.3: CacheId 0xFF heißt "nicht zwischenspeichern". */
static rrIcon* rr_icon_slot(rrContext* rr, UINT32 cacheId, UINT32 cacheEntry)
{
	if ((cacheId == 0xFF) || !rr->icons)
		return NULL;
	if ((cacheId >= rr->iconCaches) || (cacheEntry >= rr->iconEntries))
		return NULL;
	return &rr->icons[cacheId * rr->iconEntries + cacheEntry];
}

static BOOL rr_window_icon(rdpContext* context, const WINDOW_ORDER_INFO* info,
                          const WINDOW_ICON_ORDER* order)
{
	rrContext* rr = (rrContext*)context;
	const ICON_INFO* icon = order ? order->iconInfo : NULL;

	if (!icon || (icon->width == 0) || (icon->height == 0) || (icon->width > 1024) ||
	    (icon->height > 1024))
		return TRUE;

	const size_t size = 4ull * icon->width * icon->height;
	BYTE* bgra = calloc(1, size);
	if (!bgra)
		return FALSE;

	if (!freerdp_image_copy_from_icon_data(
	        bgra, PIXEL_FORMAT_BGRA32, 0, 0, 0, (UINT16)icon->width, (UINT16)icon->height,
	        icon->bitsColor, (UINT16)icon->cbBitsColor, icon->bitsMask, (UINT16)icon->cbBitsMask,
	        icon->colorTable, (UINT16)icon->cbColorTable, icon->bpp))
	{
		WLog_Print(rr->log, WLOG_WARN, "Symbol für Fenster 0x%08" PRIX32 " nicht lesbar",
		           info->windowId);
		free(bgra);
		return TRUE;
	}

	EnterCriticalSection(&rr->railLock);
	rrIcon* slot = rr_icon_slot(rr, icon->cacheId, icon->cacheEntry);
	if (slot)
	{
		BYTE* cached = malloc(size);
		if (cached)
		{
			memcpy(cached, bgra, size);
			free(slot->bgra);
			slot->bgra = cached;
			slot->width = icon->width;
			slot->height = icon->height;
		}
	}
	LeaveCriticalSection(&rr->railLock);

	BOOL rc = TRUE;
	if (rr->fe.WindowIcon)
		rc = rr->fe.WindowIcon(rr, info->windowId,
		                       (info->fieldFlags & WINDOW_ORDER_FIELD_ICON_BIG) != 0, bgra,
		                       icon->width, icon->height);
	free(bgra);
	return rc;
}

static BOOL rr_window_cached_icon(rdpContext* context, const WINDOW_ORDER_INFO* info,
                                 const WINDOW_CACHED_ICON_ORDER* order)
{
	rrContext* rr = (rrContext*)context;
	BYTE* bgra = NULL;
	UINT32 width = 0;
	UINT32 height = 0;

	EnterCriticalSection(&rr->railLock);
	const rrIcon* slot = rr_icon_slot(rr, order->cachedIcon.cacheId, order->cachedIcon.cacheEntry);
	if (slot && slot->bgra)
	{
		const size_t size = 4ull * slot->width * slot->height;
		bgra = malloc(size);
		if (bgra)
		{
			memcpy(bgra, slot->bgra, size);
			width = slot->width;
			height = slot->height;
		}
	}
	LeaveCriticalSection(&rr->railLock);

	if (!bgra)
		return TRUE;

	BOOL rc = TRUE;
	if (rr->fe.WindowIcon)
		rc = rr->fe.WindowIcon(rr, info->windowId,
		                       (info->fieldFlags & WINDOW_ORDER_FIELD_ICON_BIG) != 0, bgra, width,
		                       height);
	free(bgra);
	return rc;
}

/* Symbol nach BGRA wandeln und zwischenspeichern; Rückgabe gehört dem Aufrufer. */
static BYTE* rr_icon_copy(rrContext* rr, const ICON_INFO* icon, UINT32* width, UINT32* height)
{
	if (!icon || (icon->width == 0) || (icon->height == 0) || (icon->width > 1024) ||
	    (icon->height > 1024))
		return NULL;

	const size_t size = 4ull * icon->width * icon->height;
	BYTE* bgra = calloc(1, size);
	if (!bgra)
		return NULL;

	if (!freerdp_image_copy_from_icon_data(
	        bgra, PIXEL_FORMAT_BGRA32, 0, 0, 0, (UINT16)icon->width, (UINT16)icon->height,
	        icon->bitsColor, (UINT16)icon->cbBitsColor, icon->bitsMask, (UINT16)icon->cbBitsMask,
	        icon->colorTable, (UINT16)icon->cbColorTable, icon->bpp))
	{
		free(bgra);
		return NULL;
	}

	EnterCriticalSection(&rr->railLock);
	rrIcon* slot = rr_icon_slot(rr, icon->cacheId, icon->cacheEntry);
	if (slot)
	{
		BYTE* cached = malloc(size);
		if (cached)
		{
			memcpy(cached, bgra, size);
			free(slot->bgra);
			slot->bgra = cached;
			slot->width = icon->width;
			slot->height = icon->height;
		}
	}
	LeaveCriticalSection(&rr->railLock);

	*width = icon->width;
	*height = icon->height;
	return bgra;
}

static BYTE* rr_icon_cached(rrContext* rr, const CACHED_ICON_INFO* cached, UINT32* width,
                            UINT32* height)
{
	BYTE* bgra = NULL;

	EnterCriticalSection(&rr->railLock);
	const rrIcon* slot = rr_icon_slot(rr, cached->cacheId, cached->cacheEntry);
	if (slot && slot->bgra)
	{
		const size_t size = 4ull * slot->width * slot->height;
		bgra = malloc(size);
		if (bgra)
		{
			memcpy(bgra, slot->bgra, size);
			*width = slot->width;
			*height = slot->height;
		}
	}
	LeaveCriticalSection(&rr->railLock);
	return bgra;
}

static BOOL rr_notify_icon(rdpContext* context, const WINDOW_ORDER_INFO* info,
                           const NOTIFY_ICON_STATE_ORDER* state)
{
	rrContext* rr = (rrContext*)context;
	const UINT32 f = info->fieldFlags;
	char* tooltip = NULL;
	BYTE* bgra = NULL;
	UINT32 width = 0;
	UINT32 height = 0;

	if (!rr->fe.NotifyIconChanged || !state)
		return TRUE;

	if (f & WINDOW_ORDER_FIELD_NOTIFY_TIP)
		tooltip = rail_string_to_utf8_string(&state->toolTip);
	if (f & WINDOW_ORDER_ICON)
		bgra = rr_icon_copy(rr, &state->icon, &width, &height);
	else if (f & WINDOW_ORDER_CACHED_ICON)
		bgra = rr_icon_cached(rr, &state->cachedIcon, &width, &height);

	WLog_Print(rr->log, WLOG_DEBUG, "Tray-Symbol 0x%08" PRIX32 "/0x%08" PRIX32 " \"%s\"",
	           info->windowId, info->notifyIconId, tooltip ? tooltip : "");

	const BOOL rc = rr->fe.NotifyIconChanged(rr, info->windowId, info->notifyIconId, tooltip,
	                                         bgra, width, height);
	free(tooltip);
	free(bgra);
	return rc;
}

static BOOL rr_notify_icon_delete(rdpContext* context, const WINDOW_ORDER_INFO* info)
{
	rrContext* rr = (rrContext*)context;

	if (!rr->fe.NotifyIconDeleted)
		return TRUE;
	return rr->fe.NotifyIconDeleted(rr, info->windowId, info->notifyIconId);
}

static BOOL rr_monitored_desktop(rdpContext* context, const WINDOW_ORDER_INFO* info,
                                 const MONITORED_DESKTOP_ORDER* desktop)
{
	rrContext* rr = (rrContext*)context;
	const UINT32 f = info->fieldFlags;

	if ((f & WINDOW_ORDER_FIELD_DESKTOP_ARC_BEGAN) && (f & WINDOW_ORDER_FIELD_DESKTOP_HOOKED))
	{
		WLog_Print(rr->log, WLOG_DEBUG, "Server gleicht neu ab, alle Fenster verwerfen");
		rr_rail_reset(rr);
	}

	if ((f & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) && !rr->railActive)
	{
		rr->railActive = TRUE;
		WLog_Print(rr->log, WLOG_INFO, "RemoteApp-Modus aktiv");
		if (rr->fe.RailStarted && !rr->fe.RailStarted(rr))
			return FALSE;
	}

	const UINT32 mask = WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND | WINDOW_ORDER_FIELD_DESKTOP_ZORDER;
	if ((f & mask) && rr->fe.DesktopState)
	{
		const UINT32 active =
		    (f & WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND) ? desktop->activeWindowId : 0;
		const UINT32 count = (f & WINDOW_ORDER_FIELD_DESKTOP_ZORDER) ? desktop->numWindowIds : 0;
		return rr->fe.DesktopState(rr, f, active, count ? desktop->windowIds : NULL, count);
	}
	return TRUE;
}

static BOOL rr_non_monitored_desktop(rdpContext* context, const WINDOW_ORDER_INFO* info)
{
	rrContext* rr = (rrContext*)context;

	WINPR_UNUSED(info);
	WLog_Print(rr->log, WLOG_INFO, "Server überwacht den Desktop nicht mehr");
	rr_rail_reset(rr);
	rr->railActive = FALSE;
	return TRUE;
}

void rr_rail_register_orders(rrContext* rr, rdpWindowUpdate* window)
{
	WINPR_UNUSED(rr);
	if (!window)
		return;

	window->WindowCreate = rr_window_common;
	window->WindowUpdate = rr_window_common;
	window->WindowDelete = rr_window_delete;
	window->WindowIcon = rr_window_icon;
	window->WindowCachedIcon = rr_window_cached_icon;
	window->NotifyIconCreate = rr_notify_icon;
	window->NotifyIconUpdate = rr_notify_icon;
	window->NotifyIconDelete = rr_notify_icon_delete;
	window->MonitoredDesktop = rr_monitored_desktop;
	window->NonMonitoredDesktop = rr_non_monitored_desktop;
}

/* ---- Kanal-PDUs (Kanal-Thread) ------------------------------------------------------- */

static const char* rr_exec_error(UINT32 code)
{
	switch (code)
	{
		case RAIL_EXEC_E_HOOK_NOT_LOADED:
			return "Shell-Hook nicht geladen";
		case RAIL_EXEC_E_DECODE_FAILED:
			return "Aufruf nicht lesbar";
		case RAIL_EXEC_E_NOT_IN_ALLOWLIST:
			return "nicht als RemoteApp veröffentlicht";
		case RAIL_EXEC_E_FILE_NOT_FOUND:
			return "Datei nicht gefunden";
		case RAIL_EXEC_E_FAIL:
			return "Start fehlgeschlagen";
		case RAIL_EXEC_E_SESSION_LOCKED:
			return "Sitzung gesperrt";
		default:
			return "unbekannter Fehler";
	}
}

/* Nach dem Handshake schickt der Client Informationen, Systemparameter und den
 * Startbefehl (MS-RDPERP 1.3.2.1). Einmal je Verbindung. */
static UINT rr_rail_exec(rrContext* rr)
{
	rdpSettings* settings = rr->common.context.settings;

	if (rr->railExecSent || !rr->rail)
		return CHANNEL_RC_OK;

	const char* app = freerdp_settings_get_string(settings, FreeRDP_RemoteApplicationProgram);
	if (!app || (*app == '\0'))
		return CHANNEL_RC_OK;

	rr->railExecSent = TRUE;
	WLog_Print(rr->log, WLOG_INFO, "starte RemoteApp %s", app);

	const UINT rc = client_rail_server_start_cmd(rr->rail);
	if (rc != CHANNEL_RC_OK)
		return rc;

	/* Arbeitsbereiche ohne Menüleiste und Dock, damit Maximieren passt – je Bildschirm. */
	if (rr->multimon)
	{
		for (UINT32 i = 0; i < rr->screenCount; i++)
			(void)rr_rail_work_area(rr, &rr->screens[i].workArea);
	}
	else if ((rr->primary.workArea.width > 0) && (rr->primary.workArea.height > 0))
		(void)rr_rail_work_area(rr, &rr->primary.workArea);
	return CHANNEL_RC_OK;
}

static UINT rr_rail_send_client_handshake(rrContext* rr)
{
	const RAIL_HANDSHAKE_ORDER handshake = { .buildNumber = freerdp_settings_get_uint32(
		                                         rr->common.context.settings, FreeRDP_ClientBuild) };
	return rr->rail->ClientHandshake(rr->rail, &handshake);
}

static UINT rr_rail_server_handshake(RailClientContext* rail, const RAIL_HANDSHAKE_ORDER* handshake)
{
	rrContext* rr = rr_from_rail(rail);

	if (!rr)
		return CHANNEL_RC_OK;

	const UINT rc = rr->railHandshake ? rr->railHandshake(rail, handshake)
	                                  : rr_rail_send_client_handshake(rr);
	if (rc != CHANNEL_RC_OK)
		return rc;
	return rr_rail_exec(rr);
}

static UINT rr_rail_server_handshake_ex(RailClientContext* rail,
                                        const RAIL_HANDSHAKE_EX_ORDER* handshake)
{
	rrContext* rr = rr_from_rail(rail);

	if (!rr)
		return CHANNEL_RC_OK;

	const UINT rc = rr->railHandshakeEx ? rr->railHandshakeEx(rail, handshake)
	                                    : rr_rail_send_client_handshake(rr);
	if (rc != CHANNEL_RC_OK)
		return rc;
	return rr_rail_exec(rr);
}

static UINT rr_rail_server_execute_result(RailClientContext* rail,
                                          const RAIL_EXEC_RESULT_ORDER* result)
{
	rrContext* rr = rr_from_rail(rail);

	if (!rr)
		return CHANNEL_RC_OK;

	char* exe = rail_string_to_utf8_string(&result->exeOrFile);
	if (result->execResult != RAIL_EXEC_S_OK)
	{
		WLog_Print(rr->log, WLOG_ERROR, "RemoteApp %s: %s (0x%08" PRIX32 ")", exe ? exe : "",
		           rr_exec_error(result->execResult), result->rawResult);
		freerdp_abort_connect_context(&rr->common.context);
	}
	else
		WLog_Print(rr->log, WLOG_INFO, "RemoteApp %s gestartet", exe ? exe : "");
	free(exe);
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_system_param(RailClientContext* rail, const RAIL_SYSPARAM_ORDER* param)
{
	rrContext* rr = rr_from_rail(rail);

	if (rr)
		WLog_Print(rr->log, WLOG_DEBUG, "Systemparameter vom Server: 0x%08" PRIX32, param->param);
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_local_move_size(RailClientContext* rail,
                                           const RAIL_LOCALMOVESIZE_ORDER* order)
{
	rrContext* rr = rr_from_rail(rail);

	if (!rr)
		return CHANNEL_RC_OK;

	WLog_Print(rr->log, WLOG_DEBUG,
	           "lokales Verschieben 0x%08" PRIX32 " %s Typ %" PRIu16 " bei %" PRId16 ",%" PRId16,
	           order->windowId, order->isMoveSizeStart ? "Start" : "Ende", order->moveSizeType,
	           order->posX, order->posY);

	if (rr->fe.LocalMoveSize &&
	    !rr->fe.LocalMoveSize(rr, order->windowId, order->isMoveSizeStart, order->moveSizeType,
	                          order->posX, order->posY))
		return ERROR_INTERNAL_ERROR;
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_min_max_info(RailClientContext* rail,
                                        const RAIL_MINMAXINFO_ORDER* info)
{
	rrContext* rr = rr_from_rail(rail);

	if (rr && rr->fe.MinMaxInfo && !rr->fe.MinMaxInfo(rr, info))
		return ERROR_INTERNAL_ERROR;
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_language_bar_info(RailClientContext* rail,
                                             const RAIL_LANGBAR_INFO_ORDER* info)
{
	WINPR_UNUSED(rail);
	WINPR_UNUSED(info);
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_get_appid_response(RailClientContext* rail,
                                              const RAIL_GET_APPID_RESP_ORDER* response)
{
	WINPR_UNUSED(rail);
	WINPR_UNUSED(response);
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_zorder_sync(RailClientContext* rail, const RAIL_ZORDER_SYNC* zorder)
{
	rrContext* rr = rr_from_rail(rail);

	if (rr)
		WLog_Print(rr->log, WLOG_DEBUG, "Z-Order-Abgleich, oberstes Fenster 0x%08" PRIX32,
		           zorder->windowIdMarker);
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_cloak(RailClientContext* rail, const RAIL_CLOAK* cloak)
{
	rrContext* rr = rr_from_rail(rail);

	if (rr && rr->fe.WindowCloak && !rr->fe.WindowCloak(rr, cloak->windowId, cloak->cloak))
		return ERROR_INTERNAL_ERROR;
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_power_display_request(RailClientContext* rail,
                                                 const RAIL_POWER_DISPLAY_REQUEST* request)
{
	rrContext* rr = rr_from_rail(rail);

	if (rr)
		WLog_Print(rr->log, WLOG_DEBUG, "Anzeige wach halten: %" PRIu32, request->active);
	return CHANNEL_RC_OK;
}

static UINT rr_rail_server_taskbar_info(RailClientContext* rail,
                                        const RAIL_TASKBAR_INFO_ORDER* info)
{
	WINPR_UNUSED(rail);
	WINPR_UNUSED(info);
	return CHANNEL_RC_OK;
}

BOOL rr_rail_init(rrContext* rr, RailClientContext* rail)
{
	rdpSettings* settings = rr->common.context.settings;

	if (!rail)
		return FALSE;

	rr->rail = rail;
	rr->railExecSent = FALSE;
	rr->railHandshake = rail->ServerHandshake;
	rr->railHandshakeEx = rail->ServerHandshakeEx;

	rail->custom = rr;
	rail->ServerHandshake = rr_rail_server_handshake;
	rail->ServerHandshakeEx = rr_rail_server_handshake_ex;
	rail->ServerExecuteResult = rr_rail_server_execute_result;
	rail->ServerSystemParam = rr_rail_server_system_param;
	rail->ServerLocalMoveSize = rr_rail_server_local_move_size;
	rail->ServerMinMaxInfo = rr_rail_server_min_max_info;
	rail->ServerLanguageBarInfo = rr_rail_server_language_bar_info;
	rail->ServerGetAppIdResponse = rr_rail_server_get_appid_response;
	rail->ServerZOrderSync = rr_rail_server_zorder_sync;
	rail->ServerCloak = rr_rail_server_cloak;
	rail->ServerPowerDisplayRequest = rr_rail_server_power_display_request;
	rail->ServerTaskBarInfo = rr_rail_server_taskbar_info;

	EnterCriticalSection(&rr->railLock);
	if (!rr->icons)
	{
		rr->iconCaches = freerdp_settings_get_uint32(settings, FreeRDP_RemoteAppNumIconCaches);
		rr->iconEntries =
		    freerdp_settings_get_uint32(settings, FreeRDP_RemoteAppNumIconCacheEntries);
		if ((rr->iconCaches > 0) && (rr->iconEntries > 0))
			rr->icons = calloc(1ull * rr->iconCaches * rr->iconEntries, sizeof(rrIcon));
	}
	LeaveCriticalSection(&rr->railLock);
	return TRUE;
}

void rr_rail_uninit(rrContext* rr, RailClientContext* rail)
{
	if (rail)
		rail->custom = NULL;
	rr->rail = NULL;
	rr->railActive = FALSE;
	rr->railExecSent = FALSE;
}

void rr_rail_reset(rrContext* rr)
{
	EnterCriticalSection(&rr->railLock);
	rrRailWindow** windows = rr->windows;
	const size_t count = rr->windowCount;
	rr->windows = NULL;
	rr->windowCount = 0;
	rr->windowCapacity = 0;
	LeaveCriticalSection(&rr->railLock);

	for (size_t i = 0; i < count; i++)
	{
		const UINT32 id = windows[i]->id;
		rr_window_free(windows[i]);
		if (rr->fe.WindowDeleted)
			(void)rr->fe.WindowDeleted(rr, id);
	}
	free(windows);
}

void rr_rail_free(rrContext* rr)
{
	for (size_t i = 0; i < rr->windowCount; i++)
		rr_window_free(rr->windows[i]);
	free(rr->windows);
	rr->windows = NULL;
	rr->windowCount = rr->windowCapacity = 0;

	if (rr->icons)
	{
		for (UINT32 i = 0; i < rr->iconCaches * rr->iconEntries; i++)
			free(rr->icons[i].bgra);
		free(rr->icons);
		rr->icons = NULL;
	}
}

void rr_rail_map_surface(rrContext* rr, UINT32 windowId, UINT16 surfaceId, BOOL mapped)
{
	EnterCriticalSection(&rr->railLock);
	rrRailWindow* w = rr_window_find(rr, windowId);
	if (w)
	{
		w->surfaceMapped = mapped;
		w->surfaceId = surfaceId;
		w->surfaceChanged = mapped;
	}
	LeaveCriticalSection(&rr->railLock);
}

BOOL rr_rail_take_surface_change(rrContext* rr, UINT32 windowId, UINT16 surfaceId)
{
	BOOL changed = FALSE;

	EnterCriticalSection(&rr->railLock);
	rrRailWindow* w = rr_window_find(rr, windowId);
	if (w)
	{
		if (!w->surfaceMapped || (w->surfaceId != surfaceId))
		{
			w->surfaceMapped = TRUE;
			w->surfaceId = surfaceId;
			w->surfaceChanged = TRUE;
		}
		changed = w->surfaceChanged;
		w->surfaceChanged = FALSE;
	}
	LeaveCriticalSection(&rr->railLock);
	return changed;
}

/* ---- Befehle der Oberfläche (beliebiger Thread) -------------------------------------- */

BOOL rr_rail_activate(rrContext* rr, UINT32 windowId, BOOL active)
{
	RailClientContext* rail = rr->rail;

	if (!rail || !rail->ClientActivate)
		return FALSE;

	const RAIL_ACTIVATE_ORDER order = { .windowId = windowId, .enabled = active };
	return rail->ClientActivate(rail, &order) == CHANNEL_RC_OK;
}

BOOL rr_rail_command(rrContext* rr, UINT32 windowId, UINT16 command)
{
	RailClientContext* rail = rr->rail;

	if (!rail || !rail->ClientSystemCommand)
		return FALSE;

	const RAIL_SYSCOMMAND_ORDER order = { .windowId = windowId, .command = command };
	return rail->ClientSystemCommand(rail, &order) == CHANNEL_RC_OK;
}

static INT16 rr_int16(INT64 value)
{
	return (INT16)MIN(MAX(value, (INT64)INT16_MIN), (INT64)INT16_MAX);
}

BOOL rr_rail_move(rrContext* rr, UINT32 windowId, const rrRect* rect)
{
	RailClientContext* rail = rr->rail;
	UINT32 left = 0;
	UINT32 top = 0;
	UINT32 right = 0;
	UINT32 bottom = 0;

	if (!rail || !rail->ClientWindowMove || !rect)
		return FALSE;

	EnterCriticalSection(&rr->railLock);
	rrRailWindow* w = rr_window_find(rr, windowId);
	if (w)
	{
		left = w->marginLeft;
		top = w->marginTop;
		right = w->marginRight;
		bottom = w->marginBottom;
		/* Vorab übernehmen: die Bestätigung des Servers soll das Fenster nicht zurückschieben. */
		w->rect = *rect;
	}
	LeaveCriticalSection(&rr->railLock);

	/* Der Server erwartet das Rechteck samt unsichtbarer Ränder. */
	const RAIL_WINDOW_MOVE_ORDER order = {
		.windowId = windowId,
		.left = rr_int16((INT64)rect->x - left),
		.top = rr_int16((INT64)rect->y - top),
		.right = rr_int16((INT64)rect->x + rect->width + right),
		.bottom = rr_int16((INT64)rect->y + rect->height + bottom),
	};
	return rail->ClientWindowMove(rail, &order) == CHANNEL_RC_OK;
}

BOOL rr_rail_end_local_move(rrContext* rr, UINT32 windowId, const rrRect* rect, INT32 cursorX,
                            INT32 cursorY, BOOL keyboard)
{
	if (!rr_rail_move(rr, windowId, rect))
		return FALSE;
	if (keyboard)
		return TRUE;
	return rr_mouse_button(rr, 0, FALSE, cursorX, cursorY);
}

BOOL rr_rail_system_menu(rrContext* rr, UINT32 windowId, INT32 x, INT32 y)
{
	RailClientContext* rail = rr->rail;

	if (!rail || !rail->ClientSystemMenu)
		return FALSE;

	const RAIL_SYSMENU_ORDER order = { .windowId = windowId, .left = rr_int16(x), .top = rr_int16(y) };
	return rail->ClientSystemMenu(rail, &order) == CHANNEL_RC_OK;
}

BOOL rr_rail_work_area(rrContext* rr, const rrRect* area)
{
	RailClientContext* rail = rr->rail;

	if (!rail || !rail->ClientSystemParam || !area)
		return FALSE;

	/* Bildschirme links oder oberhalb des primären haben negative Koordinaten; das Feld ist
	 * vorzeichenlos, der Server liest es als INT16. */
	RAIL_SYSPARAM_ORDER order = { 0 };
	order.params = SPI_MASK_SET_WORK_AREA;
	order.workArea.left = (UINT16)rr_int16(area->x);
	order.workArea.top = (UINT16)rr_int16(area->y);
	order.workArea.right = (UINT16)rr_int16((INT64)area->x + area->width);
	order.workArea.bottom = (UINT16)rr_int16((INT64)area->y + area->height);

	WLog_Print(rr->log, WLOG_DEBUG, "Arbeitsbereich %" PRId32 ",%" PRId32 " %" PRIu32 "x%" PRIu32,
	           area->x, area->y, area->width, area->height);
	return rail->ClientSystemParam(rail, &order) == CHANNEL_RC_OK;
}

BOOL rr_rail_notify_event(rrContext* rr, UINT32 windowId, UINT32 iconId, UINT32 message)
{
	RailClientContext* rail = rr->rail;

	if (!rail || !rail->ClientNotifyEvent)
		return FALSE;

	const RAIL_NOTIFY_EVENT_ORDER order = { .windowId = windowId,
		                                    .notifyIconId = iconId,
		                                    .message = message };
	return rail->ClientNotifyEvent(rail, &order) == CHANNEL_RC_OK;
}

BOOL rr_rail_get_window(rrContext* rr, UINT32 windowId, rrWindow* window)
{
	if (!window)
		return FALSE;

	EnterCriticalSection(&rr->railLock);
	const rrRailWindow* w = rr_window_find(rr, windowId);
	if (w)
	{
		memset(window, 0, sizeof(*window));
		window->id = w->id;
		window->ownerId = w->ownerId;
		window->style = w->style;
		window->exStyle = w->exStyle;
		window->showState = w->showState;
		window->rect = w->rect;
		window->client.x = w->clientOffsetX;
		window->client.y = w->clientOffsetY;
		window->client.width = w->clientWidth;
		window->client.height = w->clientHeight;
		window->visibleOffsetX = w->visibleOffsetX;
		window->visibleOffsetY = w->visibleOffsetY;
		window->marginLeft = w->marginLeft;
		window->marginTop = w->marginTop;
		window->marginRight = w->marginRight;
		window->marginBottom = w->marginBottom;
		window->surfaceMapped = w->surfaceMapped;
	}
	LeaveCriticalSection(&rr->railLock);
	return w != NULL;
}
