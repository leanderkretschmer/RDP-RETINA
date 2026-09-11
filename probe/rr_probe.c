/*
 * rdp-probe – Prüf-Client ohne Fenster
 *
 * Nutzt denselben Kern wie die Mac-App und protokolliert, was der Server liefert:
 * Sitzungsgröße, Skalierung, GFX-Codecs, RemoteApp-Fenster samt Fokus und Reihenfolge.
 * Ein Ablaufskript spielt Benutzeraktionen durch (klicken, ziehen, minimieren, ...).
 *
 *   rdp-probe /v:host /u:user /p:pw [FreeRDP-Schalter]
 *       /probe-screen:5120x2880@200   Bildschirm, wie ihn die Mac-App meldet
 *       /probe-work:x,y,w,h           nutzbare Fläche (Vorgabe: ohne Menüleiste und Dock)
 *       /probe-seconds:30             Laufzeit nach dem Verbinden
 *       /probe-out:DIR                Ziel für "dump"
 *       /probe-script:"2000 click top 60,12; 4000 minimize top"
 *
 * Zeiten im Skript in Millisekunden ab Verbindungsaufbau. Aktionen:
 *   click|dblclick SEL DX,DY    Mausklick relativ zur linken oberen Fensterecke
 *   drag SEL DX,DY MX,MY        Maustaste bei DX,DY drücken, um MX,MY ziehen, loslassen
 *                               (lokales Verschieben, wenn der Server es startet)
 *   move SEL X,Y | resize SEL W,H
 *   minimize|maximize|restore|close|activate SEL
 *   key SCANCODE | type TEXT | size WxH | dump NAME | state | stats | quit
 * SEL: top (aktives Fenster), 0x<id> oder title=<Teil des Titels>
 */
#include <ctype.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <winpr/crt.h>
#include <winpr/image.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>

#include <freerdp/channels/rdpgfx.h>
#include <freerdp/error.h>
#include <freerdp/rail.h>
#include <freerdp/settings.h>
#include <freerdp/window.h>

#include "rr_core.h"

#define MAX_WINDOWS 128
#define MAX_STEPS 256

typedef struct
{
	UINT32 id;
	BOOL alive;
	rrRect rect;
	UINT32 showState;
	UINT32 style;
	UINT32 exStyle;
	UINT32 ownerId;
	char title[160];
	BYTE* surface;
	UINT32 surfaceWidth;
	UINT32 surfaceHeight;
} ProbeWindow;

typedef struct
{
	UINT64 at;
	char action[32];
	char args[256];
} Step;

typedef struct
{
	rrContext* rr;
	CRITICAL_SECTION lock;
	HANDLE done;
	UINT64 start;
	UINT64 connectedAt;
	UINT32 error;
	const char* outDir;

	BYTE* desktop;
	UINT32 desktopWidth;
	UINT32 desktopHeight;
	UINT64 desktopUpdates;
	UINT64 desktopPixels;
	UINT64 surfaceUpdates;
	UINT64 surfacePixels;
	UINT32 pointers;

	ProbeWindow windows[MAX_WINDOWS];
	UINT32 activeWindow;
	UINT32 zorder[MAX_WINDOWS];
	UINT32 zorderCount;

	BOOL moveActive;
	UINT32 moveWindow;
	UINT16 moveType;
} Probe;

static volatile sig_atomic_t g_interrupted = 0;

static void probe_log(Probe* p, const char* fmt, ...)
{
	va_list ap;
	const double t = (double)(GetTickCount64() - p->start) / 1000.0;

	printf("[%8.3f] ", t);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fflush(stdout);
}

static const char* show_name(UINT32 state)
{
	switch (state)
	{
		case WINDOW_HIDE:
			return "versteckt";
		case WINDOW_SHOW_MINIMIZED:
			return "minimiert";
		case WINDOW_SHOW_MAXIMIZED:
			return "maximiert";
		case WINDOW_SHOW:
			return "normal";
		default:
			return "?";
	}
}

static const char* move_name(UINT16 type)
{
	switch (type)
	{
		case RAIL_WMSZ_LEFT:
			return "links";
		case RAIL_WMSZ_RIGHT:
			return "rechts";
		case RAIL_WMSZ_TOP:
			return "oben";
		case RAIL_WMSZ_TOPLEFT:
			return "oben-links";
		case RAIL_WMSZ_TOPRIGHT:
			return "oben-rechts";
		case RAIL_WMSZ_BOTTOM:
			return "unten";
		case RAIL_WMSZ_BOTTOMLEFT:
			return "unten-links";
		case RAIL_WMSZ_BOTTOMRIGHT:
			return "unten-rechts";
		case RAIL_WMSZ_MOVE:
			return "verschieben";
		case RAIL_WMSZ_KEYMOVE:
			return "tastatur-verschieben";
		case RAIL_WMSZ_KEYSIZE:
			return "tastatur-groesse";
		default:
			return "?";
	}
}

/* lock gehalten */
static ProbeWindow* find_window(Probe* p, UINT32 id, BOOL create)
{
	ProbeWindow* free_slot = NULL;

	for (size_t i = 0; i < MAX_WINDOWS; i++)
	{
		ProbeWindow* w = &p->windows[i];
		if (w->alive && (w->id == id))
			return w;
		if (!w->alive && !free_slot)
			free_slot = w;
	}

	if (!create || !free_slot)
		return NULL;

	free(free_slot->surface);
	memset(free_slot, 0, sizeof(*free_slot));
	free_slot->id = id;
	free_slot->alive = TRUE;
	return free_slot;
}

static void copy_rects(BYTE* dst, UINT32 dstWidth, UINT32 dstHeight, const BYTE* src,
                       UINT32 srcStride, const rrRect* rects, UINT32 count)
{
	for (UINT32 i = 0; i < count; i++)
	{
		const rrRect* r = &rects[i];
		const UINT32 right = MIN((UINT32)r->x + r->width, dstWidth);
		const UINT32 bottom = MIN((UINT32)r->y + r->height, dstHeight);

		for (UINT32 y = (UINT32)r->y; y < bottom; y++)
			memcpy(&dst[4ull * y * dstWidth + 4ull * (UINT32)r->x],
			       &src[1ull * y * srcStride + 4ull * (UINT32)r->x], 4ull * (right - (UINT32)r->x));
	}
}

/* ---- Rückrufe des Kerns -------------------------------------------------------------- */

static BOOL on_connected(rrContext* rr, UINT32 width, UINT32 height)
{
	Probe* p = rr_user(rr);
	rdpSettings* s = rr_settings(rr);

	EnterCriticalSection(&p->lock);
	free(p->desktop);
	p->desktop = calloc(4ull * width, height);
	p->desktopWidth = width;
	p->desktopHeight = height;
	p->connectedAt = GetTickCount64();
	LeaveCriticalSection(&p->lock);

	probe_log(p,
	          "VERBUNDEN sitzung=%ux%u desktopScale=%u deviceScale=%u physisch=%ux%umm gfx=%d "
	          "h264=%d avc444=%d remoteapp=%d kbd=0x%08X",
	          width, height, freerdp_settings_get_uint32(s, FreeRDP_DesktopScaleFactor),
	          freerdp_settings_get_uint32(s, FreeRDP_DeviceScaleFactor),
	          freerdp_settings_get_uint32(s, FreeRDP_DesktopPhysicalWidth),
	          freerdp_settings_get_uint32(s, FreeRDP_DesktopPhysicalHeight),
	          freerdp_settings_get_bool(s, FreeRDP_SupportGraphicsPipeline),
	          freerdp_settings_get_bool(s, FreeRDP_GfxH264),
	          freerdp_settings_get_bool(s, FreeRDP_GfxAVC444),
	          freerdp_settings_get_bool(s, FreeRDP_RemoteApplicationMode),
	          freerdp_settings_get_uint32(s, FreeRDP_KeyboardLayout));
	return TRUE;
}

static void on_disconnected(rrContext* rr, UINT32 error)
{
	Probe* p = rr_user(rr);

	probe_log(p, "GETRENNT %s (0x%08X)", freerdp_get_last_error_string(error), error);
	p->error = error;
	(void)SetEvent(p->done);
}

static BOOL on_desktop_resized(rrContext* rr, UINT32 width, UINT32 height)
{
	Probe* p = rr_user(rr);

	EnterCriticalSection(&p->lock);
	free(p->desktop);
	p->desktop = calloc(4ull * width, height);
	p->desktopWidth = width;
	p->desktopHeight = height;
	LeaveCriticalSection(&p->lock);

	probe_log(p, "SITZUNG NEU %ux%u", width, height);
	return TRUE;
}

static BOOL on_desktop_updated(rrContext* rr, const BYTE* buffer, UINT32 stride,
                               const rrRect* rects, UINT32 count)
{
	Probe* p = rr_user(rr);

	EnterCriticalSection(&p->lock);
	if (p->desktop)
		copy_rects(p->desktop, p->desktopWidth, p->desktopHeight, buffer, stride, rects, count);
	p->desktopUpdates++;
	for (UINT32 i = 0; i < count; i++)
		p->desktopPixels += 1ull * rects[i].width * rects[i].height;
	LeaveCriticalSection(&p->lock);
	return TRUE;
}

static BOOL on_rail_started(rrContext* rr)
{
	probe_log(rr_user(rr), "REMOTEAPP aktiv");
	return TRUE;
}

static BOOL on_window_changed(rrContext* rr, const rrWindow* window, UINT32 fieldFlags,
                              BOOL created)
{
	Probe* p = rr_user(rr);

	EnterCriticalSection(&p->lock);
	ProbeWindow* w = find_window(p, window->id, TRUE);
	if (w)
	{
		w->rect = window->rect;
		w->showState = window->showState;
		w->style = window->style;
		w->exStyle = window->exStyle;
		w->ownerId = window->ownerId;
		(void)_snprintf(w->title, sizeof(w->title), "%s", window->title);
	}
	LeaveCriticalSection(&p->lock);

	probe_log(p,
	          "FENSTER %s 0x%08X \"%s\" %d,%d %ux%u %s style=0x%08X ex=0x%08X owner=0x%08X "
	          "ränder=%u/%u/%u/%u sichtbar=%u felder=0x%08X",
	          created ? "NEU" : "ÄNDERUNG", window->id, window->title, window->rect.x,
	          window->rect.y, window->rect.width, window->rect.height,
	          show_name(window->showState), window->style, window->exStyle, window->ownerId,
	          window->marginLeft, window->marginTop, window->marginRight, window->marginBottom,
	          window->numVisibilityRects, fieldFlags);
	return TRUE;
}

static BOOL on_window_deleted(rrContext* rr, UINT32 windowId)
{
	Probe* p = rr_user(rr);

	EnterCriticalSection(&p->lock);
	ProbeWindow* w = find_window(p, windowId, FALSE);
	if (w)
	{
		free(w->surface);
		w->surface = NULL;
		w->alive = FALSE;
	}
	LeaveCriticalSection(&p->lock);

	probe_log(p, "FENSTER WEG 0x%08X", windowId);
	return TRUE;
}

static BOOL on_window_icon(rrContext* rr, UINT32 windowId, BOOL big, const BYTE* bgra,
                           UINT32 width, UINT32 height)
{
	probe_log(rr_user(rr), "SYMBOL 0x%08X %ux%u%s", windowId, width, height, big ? " groß" : "");
	return TRUE;
}

static BOOL on_desktop_state(rrContext* rr, UINT32 fieldFlags, UINT32 activeWindowId,
                             const UINT32* zorder, UINT32 count)
{
	Probe* p = rr_user(rr);
	char list[1024] = "";
	size_t len = 0;

	EnterCriticalSection(&p->lock);
	if (fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND)
		p->activeWindow = activeWindowId;
	if (fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ZORDER)
	{
		p->zorderCount = MIN(count, (UINT32)MAX_WINDOWS);
		memcpy(p->zorder, zorder, p->zorderCount * sizeof(UINT32));
	}
	LeaveCriticalSection(&p->lock);

	for (UINT32 i = 0; (i < count) && (len + 12 < sizeof(list)); i++)
		len += (size_t)_snprintf(&list[len], sizeof(list) - len, "%s0x%08X", i ? " " : "",
		                         zorder[i]);

	probe_log(p, "DESKTOP%s%s aktiv=0x%08X reihenfolge=[%s]",
	          (fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND) ? " ACTIVE_WND" : "",
	          (fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ZORDER) ? " ZORDER" : "", activeWindowId,
	          list);
	return TRUE;
}

static BOOL on_window_surface(rrContext* rr, UINT32 windowId, const BYTE* data, UINT32 stride,
                              UINT32 width, UINT32 height, const rrRect* rects, UINT32 count,
                              BOOL full, BOOL alpha)
{
	Probe* p = rr_user(rr);
	BOOL resized = FALSE;

	EnterCriticalSection(&p->lock);
	ProbeWindow* w = find_window(p, windowId, TRUE);
	if (w)
	{
		if ((w->surfaceWidth != width) || (w->surfaceHeight != height) || !w->surface)
		{
			free(w->surface);
			w->surface = calloc(4ull * width, height);
			w->surfaceWidth = width;
			w->surfaceHeight = height;
			resized = TRUE;
		}
		if (w->surface)
		{
			if (full || resized)
			{
				const rrRect all = { 0, 0, width, height };
				copy_rects(w->surface, width, height, data, stride, &all, 1);
			}
			else
				copy_rects(w->surface, width, height, data, stride, rects, count);
		}
	}
	p->surfaceUpdates++;
	for (UINT32 i = 0; i < count; i++)
		p->surfacePixels += 1ull * rects[i].width * rects[i].height;
	LeaveCriticalSection(&p->lock);

	if (full || resized)
		probe_log(p, "FLÄCHE 0x%08X %ux%u%s%s", windowId, width, height,
		          alpha ? " mit Alpha" : "", full ? " (neu zugeordnet)" : "");
	return TRUE;
}

static void on_window_surface_unmapped(rrContext* rr, UINT32 windowId)
{
	probe_log(rr_user(rr), "FLÄCHE LOS 0x%08X", windowId);
}

static BOOL on_local_move_size(rrContext* rr, UINT32 windowId, BOOL start, UINT16 type, INT32 x,
                               INT32 y)
{
	Probe* p = rr_user(rr);

	EnterCriticalSection(&p->lock);
	p->moveActive = start;
	p->moveWindow = windowId;
	p->moveType = type;
	LeaveCriticalSection(&p->lock);

	probe_log(p, "LOKAL %s 0x%08X %s bei %d,%d", start ? "START" : "ENDE", windowId,
	          move_name(type), x, y);
	return TRUE;
}

static BOOL on_min_max_info(rrContext* rr, const RAIL_MINMAXINFO_ORDER* info)
{
	probe_log(rr_user(rr), "MINMAX 0x%08X max=%dx%d@%d,%d ziehen=%dx%d..%dx%d", info->windowId,
	          info->maxWidth, info->maxHeight, info->maxPosX, info->maxPosY, info->minTrackWidth,
	          info->minTrackHeight, info->maxTrackWidth, info->maxTrackHeight);
	return TRUE;
}

static BOOL on_window_cloak(rrContext* rr, UINT32 windowId, BOOL cloaked)
{
	probe_log(rr_user(rr), "VERHÜLLT 0x%08X %s", windowId, cloaked ? "ja" : "nein");
	return TRUE;
}

static void* on_pointer_new(rrContext* rr, const BYTE* bgra, UINT32 width, UINT32 height,
                            UINT32 hotX, UINT32 hotY)
{
	Probe* p = rr_user(rr);
	const UINT32 n = ++p->pointers;

	if (n <= 3)
		probe_log(p, "ZEIGER %ux%u Hotspot %u,%u", width, height, hotX, hotY);
	return (void*)(uintptr_t)n;
}

/* ---- Skript -------------------------------------------------------------------------- */

static size_t parse_script(const char* script, Step* steps, size_t max)
{
	size_t count = 0;
	char* copy = _strdup(script);
	char* context = NULL;

	if (!copy)
		return 0;

	for (char* tok = strtok_r(copy, ";\n", &context); tok && (count < max);
	     tok = strtok_r(NULL, ";\n", &context))
	{
		unsigned long long at = 0;
		Step* s = &steps[count];

		while (isspace((unsigned char)*tok))
			tok++;
		if (*tok == '\0' || *tok == '#')
			continue;

		memset(s, 0, sizeof(*s));
		if (sscanf(tok, "%llu %31s %255[^\n]", &at, s->action, s->args) < 2)
		{
			fprintf(stderr, "Skriptschritt unverständlich: %s\n", tok);
			continue;
		}
		s->at = at;
		count++;
	}

	free(copy);
	return count;
}

static BOOL pick_window(Probe* p, const char* selector, ProbeWindow* out)
{
	ProbeWindow* found = NULL;

	EnterCriticalSection(&p->lock);
	if (strcmp(selector, "top") == 0)
	{
		found = find_window(p, p->activeWindow, FALSE);
		for (UINT32 i = 0; !found && (i < p->zorderCount); i++)
		{
			ProbeWindow* w = find_window(p, p->zorder[i], FALSE);
			if (w && (w->showState != WINDOW_HIDE) && ((w->exStyle & WS_EX_TOOLWINDOW) == 0))
				found = w;
		}
		for (size_t i = 0; !found && (i < MAX_WINDOWS); i++)
		{
			ProbeWindow* w = &p->windows[i];
			if (w->alive && (w->showState != WINDOW_HIDE) && (w->rect.width > 0))
				found = w;
		}
	}
	else if (strncmp(selector, "0x", 2) == 0)
		found = find_window(p, (UINT32)strtoul(selector, NULL, 16), FALSE);
	else if (strncmp(selector, "title=", 6) == 0)
	{
		for (size_t i = 0; !found && (i < MAX_WINDOWS); i++)
		{
			ProbeWindow* w = &p->windows[i];
			if (w->alive && strstr(w->title, &selector[6]))
				found = w;
		}
	}

	if (found)
	{
		*out = *found;
		out->surface = NULL;
	}
	LeaveCriticalSection(&p->lock);

	if (!found)
		probe_log(p, "AKTION kein Fenster für \"%s\"", selector);
	return found != NULL;
}

static void write_bitmap(Probe* p, const char* name, const BYTE* data, UINT32 width,
                         UINT32 height)
{
	char path[1024];

	(void)_snprintf(path, sizeof(path), "%s/%s.bmp", p->outDir ? p->outDir : ".", name);
	if (winpr_bitmap_write(path, data, width, height, 32) < 0)
		probe_log(p, "DUMP fehlgeschlagen: %s", path);
	else
		probe_log(p, "DUMP %s (%ux%u)", path, width, height);
}

static void dump(Probe* p, const char* name)
{
	char file[256];

	EnterCriticalSection(&p->lock);
	if (p->desktop)
	{
		(void)_snprintf(file, sizeof(file), "%s-desktop", name);
		write_bitmap(p, file, p->desktop, p->desktopWidth, p->desktopHeight);
	}

	for (size_t i = 0; i < MAX_WINDOWS; i++)
	{
		const ProbeWindow* w = &p->windows[i];

		if (!w->alive)
			continue;

		if (w->surface)
		{
			(void)_snprintf(file, sizeof(file), "%s-flaeche-%08X", name, w->id);
			write_bitmap(p, file, w->surface, w->surfaceWidth, w->surfaceHeight);
		}
		else if (p->desktop && (w->rect.width > 0) && (w->rect.height > 0) && (w->rect.x >= 0) &&
		         (w->rect.y >= 0) && ((UINT32)w->rect.x + w->rect.width <= p->desktopWidth) &&
		         ((UINT32)w->rect.y + w->rect.height <= p->desktopHeight))
		{
			BYTE* crop = calloc(4ull * w->rect.width, w->rect.height);
			if (crop)
			{
				for (UINT32 y = 0; y < w->rect.height; y++)
					memcpy(&crop[4ull * y * w->rect.width],
					       &p->desktop[4ull * ((UINT32)w->rect.y + y) * p->desktopWidth +
					                   4ull * (UINT32)w->rect.x],
					       4ull * w->rect.width);
				(void)_snprintf(file, sizeof(file), "%s-fenster-%08X", name, w->id);
				write_bitmap(p, file, crop, w->rect.width, w->rect.height);
				free(crop);
			}
		}
	}
	LeaveCriticalSection(&p->lock);
}

static void print_state(Probe* p)
{
	EnterCriticalSection(&p->lock);
	probe_log(p, "ZUSTAND aktiv=0x%08X, %u in Reihenfolge", p->activeWindow, p->zorderCount);
	for (size_t i = 0; i < MAX_WINDOWS; i++)
	{
		const ProbeWindow* w = &p->windows[i];
		if (w->alive)
			probe_log(p, "  0x%08X \"%s\" %d,%d %ux%u %s%s", w->id, w->title, w->rect.x,
			          w->rect.y, w->rect.width, w->rect.height, show_name(w->showState),
			          w->surface ? " eigene Fläche" : "");
	}
	probe_log(p, "  Desktop: %llu Aktualisierungen, %llu Pixel; Flächen: %llu / %llu Pixel",
	          (unsigned long long)p->desktopUpdates, (unsigned long long)p->desktopPixels,
	          (unsigned long long)p->surfaceUpdates, (unsigned long long)p->surfacePixels);
	LeaveCriticalSection(&p->lock);
}

static void print_stats(Probe* p)
{
	rrGfxStats stats = { 0 };

	if (!rr_gfx_stats(p->rr, &stats))
		return;

	probe_log(p, "GFX version=0x%08X flags=0x%08X bilder=%llu flächenbefehle=%llu",
	          stats.capsVersion, stats.capsFlags, (unsigned long long)stats.frames,
	          (unsigned long long)stats.surfaceCommands);
	for (UINT32 i = 0; i < ARRAYSIZE(stats.codec); i++)
	{
		if (stats.codec[i] > 0)
			probe_log(p, "  Codec %-14s %llu", rr_codec_name(i),
			          (unsigned long long)stats.codec[i]);
	}
}

static void apply_move(UINT16 type, rrRect* r, INT32 dx, INT32 dy)
{
	switch (type)
	{
		case RAIL_WMSZ_MOVE:
			r->x += dx;
			r->y += dy;
			break;
		case RAIL_WMSZ_LEFT:
			r->x += dx;
			r->width = (UINT32)((INT32)r->width - dx);
			break;
		case RAIL_WMSZ_RIGHT:
			r->width = (UINT32)((INT32)r->width + dx);
			break;
		case RAIL_WMSZ_TOP:
			r->y += dy;
			r->height = (UINT32)((INT32)r->height - dy);
			break;
		case RAIL_WMSZ_BOTTOM:
			r->height = (UINT32)((INT32)r->height + dy);
			break;
		case RAIL_WMSZ_TOPLEFT:
			apply_move(RAIL_WMSZ_TOP, r, dx, dy);
			apply_move(RAIL_WMSZ_LEFT, r, dx, dy);
			break;
		case RAIL_WMSZ_TOPRIGHT:
			apply_move(RAIL_WMSZ_TOP, r, dx, dy);
			apply_move(RAIL_WMSZ_RIGHT, r, dx, dy);
			break;
		case RAIL_WMSZ_BOTTOMLEFT:
			apply_move(RAIL_WMSZ_BOTTOM, r, dx, dy);
			apply_move(RAIL_WMSZ_LEFT, r, dx, dy);
			break;
		case RAIL_WMSZ_BOTTOMRIGHT:
			apply_move(RAIL_WMSZ_BOTTOM, r, dx, dy);
			apply_move(RAIL_WMSZ_RIGHT, r, dx, dy);
			break;
		default:
			break;
	}
}

static BOOL wait_move_state(Probe* p, UINT32 windowId, BOOL active, DWORD timeoutMs)
{
	const UINT64 until = GetTickCount64() + timeoutMs;

	while (GetTickCount64() < until)
	{
		EnterCriticalSection(&p->lock);
		const BOOL match = (p->moveActive == active) && (p->moveWindow == windowId);
		LeaveCriticalSection(&p->lock);
		if (match)
			return TRUE;
		Sleep(10);
	}
	return FALSE;
}

static void click(Probe* p, INT32 x, INT32 y)
{
	(void)rr_mouse_move(p->rr, x, y);
	Sleep(30);
	(void)rr_mouse_button(p->rr, 0, TRUE, x, y);
	Sleep(60);
	(void)rr_mouse_button(p->rr, 0, FALSE, x, y);
}

static BOOL run_step(Probe* p, const Step* step)
{
	char sel[128] = "";
	int a = 0;
	int b = 0;
	int c = 0;
	int d = 0;
	ProbeWindow w;

	(void)sscanf(step->args, "%127s %d,%d %d,%d", sel, &a, &b, &c, &d);
	probe_log(p, "AKTION %s %s", step->action, step->args);

	if ((strcmp(step->action, "click") == 0) || (strcmp(step->action, "dblclick") == 0))
	{
		if (!pick_window(p, sel, &w))
			return TRUE;
		click(p, w.rect.x + a, w.rect.y + b);
		if (strcmp(step->action, "dblclick") == 0)
			click(p, w.rect.x + a, w.rect.y + b);
	}
	else if (strcmp(step->action, "drag") == 0)
	{
		if (!pick_window(p, sel, &w))
			return TRUE;

		const INT32 x0 = w.rect.x + a;
		const INT32 y0 = w.rect.y + b;
		(void)rr_mouse_move(p->rr, x0, y0);
		Sleep(30);
		(void)rr_mouse_button(p->rr, 0, TRUE, x0, y0);

		if (wait_move_state(p, w.id, TRUE, 1500))
		{
			/* So verhält sich die Mac-App: das Fenster wandert lokal, der Server erfährt
			 * am Ende die neue Lage und das Loslassen der Taste. */
			EnterCriticalSection(&p->lock);
			const UINT16 type = p->moveType;
			LeaveCriticalSection(&p->lock);

			rrRect rect = w.rect;
			apply_move(type, &rect, c, d);
			probe_log(p, "AKTION lokal %s -> %d,%d %ux%u", move_name(type), rect.x, rect.y,
			          rect.width, rect.height);
			Sleep(200);
			(void)rr_rail_end_local_move(p->rr, w.id, &rect, x0 + c, y0 + d, FALSE);
			if (!wait_move_state(p, w.id, FALSE, 2000))
				probe_log(p, "AKTION Server hat das lokale Verschieben nicht beendet");
		}
		else
		{
			probe_log(p, "AKTION kein lokales Verschieben, ziehe über den Server");
			for (int i = 1; i <= 10; i++)
			{
				(void)rr_mouse_move(p->rr, x0 + c * i / 10, y0 + d * i / 10);
				Sleep(16);
			}
			(void)rr_mouse_button(p->rr, 0, FALSE, x0 + c, y0 + d);
		}
	}
	else if (strcmp(step->action, "move") == 0)
	{
		if (!pick_window(p, sel, &w))
			return TRUE;
		w.rect.x = a;
		w.rect.y = b;
		(void)rr_rail_move(p->rr, w.id, &w.rect);
	}
	else if (strcmp(step->action, "resize") == 0)
	{
		if (!pick_window(p, sel, &w))
			return TRUE;
		w.rect.width = (UINT32)a;
		w.rect.height = (UINT32)b;
		(void)rr_rail_move(p->rr, w.id, &w.rect);
	}
	else if ((strcmp(step->action, "minimize") == 0) || (strcmp(step->action, "maximize") == 0) ||
	         (strcmp(step->action, "restore") == 0) || (strcmp(step->action, "close") == 0))
	{
		UINT16 command = SC_RESTORE;
		if (strcmp(step->action, "minimize") == 0)
			command = SC_MINIMIZE;
		else if (strcmp(step->action, "maximize") == 0)
			command = SC_MAXIMIZE;
		else if (strcmp(step->action, "close") == 0)
			command = SC_CLOSE;

		if (!pick_window(p, sel, &w))
			return TRUE;
		(void)rr_rail_command(p->rr, w.id, command);
	}
	else if (strcmp(step->action, "activate") == 0)
	{
		if (!pick_window(p, sel, &w))
			return TRUE;
		(void)rr_rail_activate(p->rr, w.id, TRUE);
	}
	else if ((strcmp(step->action, "klick") == 0) || (strcmp(step->action, "rklick") == 0))
	{
		/* Klick an einer festen Stelle des Desktoppuffers: klick X,Y */
		int x = 0;
		int y = 0;
		if (sscanf(step->args, "%d,%d", &x, &y) == 2)
		{
			const UINT32 button = (step->action[0] == 'r') ? 1 : 0;
			(void)rr_mouse_move(p->rr, x, y);
			Sleep(30);
			(void)rr_mouse_button(p->rr, button, TRUE, x, y);
			Sleep(60);
			(void)rr_mouse_button(p->rr, button, FALSE, x, y);
		}
	}
	else if (strcmp(step->action, "key") == 0)
	{
		const UINT32 scancode = (UINT32)strtoul(sel, NULL, 16);
		(void)rr_key_scancode(p->rr, scancode, TRUE, FALSE);
		Sleep(40);
		(void)rr_key_scancode(p->rr, scancode, FALSE, FALSE);
	}
	else if (strcmp(step->action, "type") == 0)
	{
		for (const char* ch = step->args; *ch; ch++)
		{
			(void)rr_key_unicode(p->rr, (UINT16)(unsigned char)*ch, TRUE);
			(void)rr_key_unicode(p->rr, (UINT16)(unsigned char)*ch, FALSE);
			Sleep(20);
		}
	}
	else if (strcmp(step->action, "size") == 0)
	{
		unsigned width = 0;
		unsigned height = 0;
		if (sscanf(sel, "%ux%u", &width, &height) == 2)
			(void)rr_request_size(p->rr, width, height);
	}
	else if (strcmp(step->action, "dump") == 0)
		dump(p, sel[0] ? sel : "dump");
	else if (strcmp(step->action, "state") == 0)
		print_state(p);
	else if (strcmp(step->action, "stats") == 0)
		print_stats(p);
	else if (strcmp(step->action, "quit") == 0)
		return FALSE;
	else
		probe_log(p, "AKTION unbekannt: %s", step->action);

	return TRUE;
}

static char* read_file(const char* path)
{
	FILE* fp = fopen(path, "rb");
	char* data = NULL;

	if (!fp)
		return NULL;
	if (fseek(fp, 0, SEEK_END) == 0)
	{
		const long size = ftell(fp);
		if ((size >= 0) && (fseek(fp, 0, SEEK_SET) == 0))
		{
			data = calloc((size_t)size + 1, 1);
			if (data && (fread(data, 1, (size_t)size, fp) != (size_t)size))
			{
				free(data);
				data = NULL;
			}
		}
	}
	fclose(fp);
	return data;
}

static void on_signal(int sig)
{
	WINPR_UNUSED(sig);
	g_interrupted = 1;
}

int main(int argc, char* argv[])
{
	static Probe probe = { 0 };
	static Step steps[MAX_STEPS];
	Probe* p = &probe;
	int exitCode = 0;

	rrFrontend frontend = { 0 };
	frontend.Connected = on_connected;
	frontend.Disconnected = on_disconnected;
	frontend.DesktopResized = on_desktop_resized;
	frontend.DesktopUpdated = on_desktop_updated;
	frontend.RailStarted = on_rail_started;
	frontend.WindowChanged = on_window_changed;
	frontend.WindowDeleted = on_window_deleted;
	frontend.WindowIcon = on_window_icon;
	frontend.DesktopState = on_desktop_state;
	frontend.WindowSurface = on_window_surface;
	frontend.WindowSurfaceUnmapped = on_window_surface_unmapped;
	frontend.LocalMoveSize = on_local_move_size;
	frontend.MinMaxInfo = on_min_max_info;
	frontend.WindowCloak = on_window_cloak;
	frontend.PointerNew = on_pointer_new;

	p->start = GetTickCount64();
	InitializeCriticalSection(&p->lock);
	p->done = CreateEvent(NULL, TRUE, FALSE, NULL);

	p->rr = rr_new(&frontend, p, argc, argv, &exitCode);
	if (!p->rr)
		return exitCode;

	unsigned screenWidth = 5120;
	unsigned screenHeight = 2880;
	unsigned scale = 200;
	const char* option = rr_option(p->rr, "probe-screen");
	if (option)
		(void)sscanf(option, "%ux%u@%u", &screenWidth, &screenHeight, &scale);

	/* Wie auf dem Mac: 30 pt Menüleiste oben, 56 pt Dock unten */
	rrScreen screen = { 0 };
	screen.frame.width = screenWidth;
	screen.frame.height = screenHeight;
	screen.workArea.y = (INT32)(30 * scale / 100);
	screen.workArea.width = screenWidth;
	screen.workArea.height = screenHeight - (30 + 56) * scale / 100;
	screen.physicalWidthMm = 597;
	screen.physicalHeightMm = 336;
	screen.scalePercent = scale;
	screen.primary = TRUE;

	option = rr_option(p->rr, "probe-work");
	if (option)
		(void)sscanf(option, "%d,%d,%u,%u", &screen.workArea.x, &screen.workArea.y,
		             &screen.workArea.width, &screen.workArea.height);

	const char* seconds = rr_option(p->rr, "probe-seconds");
	const UINT64 runtime = (seconds ? strtoull(seconds, NULL, 10) : 20) * 1000;

	p->outDir = rr_option(p->rr, "probe-out");
	if (p->outDir)
		(void)mkdir(p->outDir, 0755);

	size_t stepCount = 0;
	option = rr_option(p->rr, "probe-script");
	if (option)
		stepCount = parse_script(option, steps, MAX_STEPS);
	option = rr_option(p->rr, "probe-script-file");
	if (option)
	{
		char* text = read_file(option);
		if (!text)
		{
			fprintf(stderr, "Skriptdatei nicht lesbar: %s\n", option);
			rr_free(p->rr);
			return 1;
		}
		stepCount = parse_script(text, steps, MAX_STEPS);
		free(text);
	}

	/* Zweiter Bildschirm für W3, Lage in Server-Pixeln relativ zum primären:
	 * /probe-screen2:2560x1440@100+-2560+0 */
	rrScreen screens[2];
	memset(screens, 0, sizeof(screens));
	screens[0] = screen;
	UINT32 screenCount = 1;
	option = rr_option(p->rr, "probe-screen2");
	if (option)
	{
		unsigned w2 = 0;
		unsigned h2 = 0;
		unsigned scale2 = 100;
		int x2 = 0;
		int y2 = 0;
		if (sscanf(option, "%ux%u@%u+%d+%d", &w2, &h2, &scale2, &x2, &y2) == 5)
		{
			rrScreen* s2 = &screens[1];
			s2->frame.x = x2;
			s2->frame.y = y2;
			s2->frame.width = w2;
			s2->frame.height = h2;
			s2->workArea = s2->frame;
			s2->physicalWidthMm = 300;
			s2->physicalHeightMm = 190;
			s2->scalePercent = scale2;
			screenCount = 2;
		}
	}

	if (!rr_configure(p->rr, screens, screenCount, 0, 0))
	{
		fprintf(stderr, "Konfiguration fehlgeschlagen\n");
		rr_free(p->rr);
		return 1;
	}

	(void)signal(SIGINT, on_signal);
	(void)signal(SIGTERM, on_signal);

	if (!rr_start(p->rr))
	{
		fprintf(stderr, "Start fehlgeschlagen\n");
		rr_free(p->rr);
		return 1;
	}

	size_t next = 0;
	UINT64 lastReport = 0;
	BOOL running = TRUE;

	while (running && !g_interrupted)
	{
		if (WaitForSingleObject(p->done, 20) == WAIT_OBJECT_0)
			break;

		EnterCriticalSection(&p->lock);
		const UINT64 connectedAt = p->connectedAt;
		LeaveCriticalSection(&p->lock);
		if (connectedAt == 0)
			continue;

		const UINT64 elapsed = GetTickCount64() - connectedAt;
		while (running && (next < stepCount) && (steps[next].at <= elapsed))
			running = run_step(p, &steps[next++]);

		if (elapsed >= runtime)
			break;

		if (elapsed - lastReport >= 5000)
		{
			lastReport = elapsed;
			EnterCriticalSection(&p->lock);
			const UINT64 updates = p->desktopUpdates + p->surfaceUpdates;
			LeaveCriticalSection(&p->lock);
			probe_log(p, "LAUF %llus, %llu Bildaktualisierungen",
			          (unsigned long long)(elapsed / 1000), (unsigned long long)updates);
		}
	}

	print_state(p);
	print_stats(p);

	rr_stop(p->rr);
	rr_free(p->rr);
	(void)CloseHandle(p->done);
	DeleteCriticalSection(&p->lock);
	return ((p->error != 0) && !g_interrupted) ? 2 : 0;
}
