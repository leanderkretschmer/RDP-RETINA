/*
 * rdp-retina – Verbindung, Zeichenrückrufe, Mauszeiger
 */
#include <string.h>

#include <winpr/crt.h>
#include <winpr/synch.h>
#include <winpr/thread.h>

#include <freerdp/freerdp.h>
#include <freerdp/constants.h>
#include <freerdp/error.h>
#include <freerdp/event.h>
#include <freerdp/graphics.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/codec/color.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/channels/disp.h>

#include "rr_private.h"

typedef struct
{
	rdpPointer pointer;
	void* handle;
} rrPointer;

/* ---- Zeichnen ------------------------------------------------------------------------ */

static HGDI_WND rr_hwnd(rdpContext* context)
{
	rdpGdi* gdi = context->gdi;

	if (!gdi || !gdi->primary || !gdi->primary->hdc)
		return NULL;
	return gdi->primary->hdc->hwnd;
}

static BOOL rr_begin_paint(rdpContext* context)
{
	HGDI_WND hwnd = rr_hwnd(context);

	if (hwnd && hwnd->invalid)
	{
		hwnd->invalid->null = TRUE;
		hwnd->ninvalid = 0;
	}
	return TRUE;
}

static BOOL rr_clip(const rdpGdi* gdi, INT64 x, INT64 y, INT64 w, INT64 h, rrRect* out)
{
	const INT64 left = MAX(x, 0);
	const INT64 top = MAX(y, 0);
	const INT64 right = MIN(x + w, (INT64)gdi->width);
	const INT64 bottom = MIN(y + h, (INT64)gdi->height);

	if ((right <= left) || (bottom <= top))
		return FALSE;

	out->x = (INT32)left;
	out->y = (INT32)top;
	out->width = (UINT32)(right - left);
	out->height = (UINT32)(bottom - top);
	return TRUE;
}

static BOOL rr_end_paint(rdpContext* context)
{
	rrContext* rr = (rrContext*)context;
	rdpGdi* gdi = context->gdi;
	HGDI_WND hwnd = rr_hwnd(context);

	if (!hwnd || !hwnd->invalid || hwnd->invalid->null || (hwnd->ninvalid <= 0))
		return TRUE;

	const UINT32 ninvalid = (UINT32)hwnd->ninvalid;
	rrRect bounds = { 0 };
	const rrRect* rects = &bounds;
	UINT32 count = 0;

	if (ninvalid > rr->dirtyCapacity)
	{
		const UINT32 capacity = MAX(ninvalid, 64);
		rrRect* tmp = realloc(rr->dirty, capacity * sizeof(rrRect));
		if (tmp)
		{
			rr->dirty = tmp;
			rr->dirtyCapacity = capacity;
		}
	}

	/* Viele kleine Rechtecke kosten beim Hochladen mehr als ihr Umriss. */
	if ((ninvalid > 64) || (ninvalid > rr->dirtyCapacity))
	{
		const GDI_RGN* inv = hwnd->invalid;
		if (rr_clip(gdi, inv->x, inv->y, inv->w, inv->h, &bounds))
			count = 1;
	}
	else
	{
		for (UINT32 i = 0; i < ninvalid; i++)
		{
			const GDI_RGN* r = &hwnd->cinvalid[i];
			if (rr_clip(gdi, r->x, r->y, r->w, r->h, &rr->dirty[count]))
				count++;
		}
		rects = rr->dirty;
	}

	hwnd->invalid->null = TRUE;
	hwnd->ninvalid = 0;

	if ((count == 0) || !rr->fe.DesktopUpdated)
		return TRUE;
	return rr->fe.DesktopUpdated(rr, gdi->primary_buffer, gdi->stride, rects, count);
}

static BOOL rr_desktop_resize(rdpContext* context)
{
	rrContext* rr = (rrContext*)context;
	const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
	const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);

	if (!context->gdi)
		return TRUE;

	if (!gdi_resize(context->gdi, width, height))
		return FALSE;

	WLog_Print(rr->log, WLOG_INFO, "Sitzung jetzt %" PRIu32 "x%" PRIu32 " Pixel", width, height);

	if (rr->fe.DesktopResized)
		return rr->fe.DesktopResized(rr, width, height);
	return TRUE;
}

/* ---- Mauszeiger ---------------------------------------------------------------------- */

static BOOL rr_pointer_new(rdpContext* context, rdpPointer* pointer)
{
	rrContext* rr = (rrContext*)context;
	rrPointer* p = (rrPointer*)pointer;

	p->handle = NULL;
	if (!rr->fe.PointerNew || (pointer->width == 0) || (pointer->height == 0))
		return TRUE;

	const size_t size = 4ull * pointer->width * pointer->height;
	BYTE* bgra = winpr_aligned_malloc(size, 16);
	if (!bgra)
		return FALSE;

	if (!freerdp_image_copy_from_pointer_data(
	        bgra, PIXEL_FORMAT_BGRA32, 0, 0, 0, pointer->width, pointer->height,
	        pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData,
	        pointer->lengthAndMask, pointer->xorBpp, context->gdi ? &context->gdi->palette : NULL))
	{
		winpr_aligned_free(bgra);
		return FALSE;
	}

	p->handle = rr->fe.PointerNew(rr, bgra, pointer->width, pointer->height, pointer->xPos,
	                              pointer->yPos);
	winpr_aligned_free(bgra);
	return TRUE;
}

static void rr_pointer_free(rdpContext* context, rdpPointer* pointer)
{
	rrContext* rr = (rrContext*)context;
	rrPointer* p = (rrPointer*)pointer;

	if (p->handle && rr->fe.PointerFree)
		rr->fe.PointerFree(rr, p->handle);
	p->handle = NULL;
}

static BOOL rr_pointer_set(rdpContext* context, rdpPointer* pointer)
{
	rrContext* rr = (rrContext*)context;
	const rrPointer* p = (const rrPointer*)pointer;

	if (!rr->fe.PointerSet)
		return TRUE;
	return rr->fe.PointerSet(rr, p->handle);
}

static BOOL rr_pointer_set_null(rdpContext* context)
{
	rrContext* rr = (rrContext*)context;

	if (!rr->fe.PointerSet)
		return TRUE;
	return rr->fe.PointerSet(rr, NULL);
}

static BOOL rr_pointer_set_default(rdpContext* context)
{
	rrContext* rr = (rrContext*)context;

	if (!rr->fe.PointerSetDefault)
		return TRUE;
	return rr->fe.PointerSetDefault(rr);
}

static BOOL rr_pointer_set_position(rdpContext* context, UINT32 x, UINT32 y)
{
	rrContext* rr = (rrContext*)context;

	if (!rr->fe.PointerSetPosition)
		return TRUE;
	return rr->fe.PointerSetPosition(rr, x, y);
}

/* ---- Kanäle -------------------------------------------------------------------------- */

static void rr_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	rrContext* rr = (rrContext*)context;

	if (strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0)
		(void)rr_rail_init(rr, (RailClientContext*)e->pInterface);
	else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
	{
		if (!rr_gfx_init(rr, (RdpgfxClientContext*)e->pInterface))
			WLog_Print(rr->log, WLOG_ERROR, "Grafik-Pipeline ließ sich nicht einrichten");
	}
	else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
		(void)rr_disp_init(rr, (DispClientContext*)e->pInterface);
	else
	{
		freerdp_client_OnChannelConnectedEventHandler(context, e);
		if (rr->fe.ChannelConnected)
			rr->fe.ChannelConnected(rr, e->name, e->pInterface);
	}
}

static void rr_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	rrContext* rr = (rrContext*)context;

	if (strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0)
		rr_rail_uninit(rr, (RailClientContext*)e->pInterface);
	else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
		rr_gfx_uninit(rr, (RdpgfxClientContext*)e->pInterface);
	else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
		rr_disp_uninit(rr, (DispClientContext*)e->pInterface);
	else
	{
		if (rr->fe.ChannelDisconnected)
			rr->fe.ChannelDisconnected(rr, e->name, e->pInterface);
		freerdp_client_OnChannelDisconnectedEventHandler(context, e);
	}
}

/* ---- Verbindung ---------------------------------------------------------------------- */

static BOOL rr_pre_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	rrContext* rr = (rrContext*)context;
	rdpSettings* settings = context->settings;

	if (!freerdp_settings_get_string(settings, FreeRDP_ServerHostname))
	{
		WLog_Print(rr->log, WLOG_ERROR, "kein Server angegeben: /v:<server>[:port]");
		return FALSE;
	}

#if defined(__APPLE__)
	const UINT32 major = OSMAJORTYPE_MACINTOSH;
	const UINT32 minor = OSMINORTYPE_MACINTOSH;
#else
	const UINT32 major = OSMAJORTYPE_UNIX;
	const UINT32 minor = OSMINORTYPE_NATIVE_XSERVER;
#endif
	if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, major) ||
	    !freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, minor))
		return FALSE;

	if ((PubSub_SubscribeChannelConnected(context->pubSub, rr_channel_connected) < 0) ||
	    (PubSub_SubscribeChannelDisconnected(context->pubSub, rr_channel_disconnected) < 0))
		return FALSE;

	return TRUE;
}

static BOOL rr_post_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	rrContext* rr = (rrContext*)context;

	if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
		return FALSE;

	rdpUpdate* update = context->update;
	update->BeginPaint = rr_begin_paint;
	update->EndPaint = rr_end_paint;
	update->DesktopResize = rr_desktop_resize;
	rr_rail_register_orders(rr, update->window);

	rdpPointer pointer = { 0 };
	pointer.size = sizeof(rrPointer);
	pointer.New = rr_pointer_new;
	pointer.Free = rr_pointer_free;
	pointer.Set = rr_pointer_set;
	pointer.SetNull = rr_pointer_set_null;
	pointer.SetDefault = rr_pointer_set_default;
	pointer.SetPosition = rr_pointer_set_position;
	graphics_register_pointer(context->graphics, &pointer);

	const rdpGdi* gdi = context->gdi;
	WLog_Print(rr->log, WLOG_INFO, "verbunden, Sitzung %" PRId32 "x%" PRId32 " Pixel", gdi->width,
	           gdi->height);

	if (rr->fe.Connected && !rr->fe.Connected(rr, (UINT32)gdi->width, (UINT32)gdi->height))
		return FALSE;
	return TRUE;
}

static void rr_post_disconnect(freerdp* instance)
{
	if (!instance || !instance->context)
		return;

	rdpContext* context = instance->context;
	PubSub_UnsubscribeChannelConnected(context->pubSub, rr_channel_connected);
	PubSub_UnsubscribeChannelDisconnected(context->pubSub, rr_channel_disconnected);
	gdi_free(instance);
}

static DWORD WINAPI rr_thread(LPVOID arg)
{
	rdpContext* context = (rdpContext*)arg;
	rrContext* rr = (rrContext*)context;
	freerdp* instance = context->instance;
	UINT32 error = 0;

	if (!freerdp_connect(instance))
	{
		error = freerdp_get_last_error(context);
		WLog_Print(rr->log, WLOG_ERROR, "Verbindung fehlgeschlagen: %s",
		           freerdp_get_last_error_string(error));
		goto out;
	}

	while (!freerdp_shall_disconnect_context(context))
	{
		HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
		const DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));

		if (count == 0)
		{
			WLog_Print(rr->log, WLOG_ERROR, "freerdp_get_event_handles fehlgeschlagen");
			break;
		}

		/* Kurzes Zeitlimit, damit aufgeschobene Größenmeldungen rausgehen. */
		const DWORD status = WaitForMultipleObjects(count, handles, FALSE, 250);
		if (status == WAIT_FAILED)
		{
			WLog_Print(rr->log, WLOG_ERROR, "WaitForMultipleObjects fehlgeschlagen");
			break;
		}

		if (!freerdp_check_event_handles(context))
		{
			/* W4: nach einem Netzabbruch neu verbinden (AutoReconnectionEnabled), nie nach einem
			 * gewollten Abbruch. PostConnect läuft dabei nicht erneut, die Kanäle schon. */
			if (!freerdp_shall_disconnect_context(context) &&
			    client_auto_reconnect_ex(instance, NULL))
			{
				WLog_Print(rr->log, WLOG_INFO, "Verbindung wiederhergestellt");
				continue;
			}
			break;
		}

		rr_disp_tick(rr);
	}

	error = freerdp_get_last_error(context);

out:
	freerdp_disconnect(instance);
	if (rr->fe.Disconnected)
		rr->fe.Disconnected(rr, error);
	return 0;
}

/* ---- Einstiegspunkte für FreeRDP ----------------------------------------------------- */

static BOOL rr_client_new(freerdp* instance, rdpContext* context)
{
	rrContext* rr = (rrContext*)context;

	rr->log = WLog_Get(RR_TAG);
	instance->PreConnect = rr_pre_connect;
	instance->PostConnect = rr_post_connect;
	instance->PostDisconnect = rr_post_disconnect;
	instance->AuthenticateEx = client_cli_authenticate_ex;
	instance->VerifyCertificateEx = client_cli_verify_certificate_ex;
	instance->VerifyChangedCertificateEx = client_cli_verify_changed_certificate_ex;
	instance->LogonErrorInfo = client_cli_logon_error_info;
	instance->PresentGatewayMessage = client_cli_present_gateway_message;

	InitializeCriticalSection(&rr->railLock);
	InitializeCriticalSection(&rr->dispLock);
	InitializeCriticalSection(&rr->statsLock);
	return TRUE;
}

static void rr_client_free(freerdp* instance, rdpContext* context)
{
	rrContext* rr = (rrContext*)context;

	WINPR_UNUSED(instance);
	if (!rr)
		return;

	rr_rail_free(rr);
	rr_settings_free(rr);
	free(rr->dirty);
	rr->dirty = NULL;
	DeleteCriticalSection(&rr->railLock);
	DeleteCriticalSection(&rr->dispLock);
	DeleteCriticalSection(&rr->statsLock);
}

static int rr_client_start(rdpContext* context)
{
	rrContext* rr = (rrContext*)context;

	rr->common.thread = CreateThread(NULL, 0, rr_thread, context, 0, NULL);
	return rr->common.thread ? 0 : -1;
}

static int rr_client_stop(rdpContext* context)
{
	return freerdp_client_common_stop(context);
}

/* ---- Öffentliche Schnittstelle ------------------------------------------------------- */

rrContext* rr_new(const rrFrontend* frontend, void* user, int argc, char** argv, int* exitCode)
{
	RDP_CLIENT_ENTRY_POINTS entry = { 0 };
	int code = 1;

	entry.Size = sizeof(entry);
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.ContextSize = sizeof(rrContext);
	entry.ClientNew = rr_client_new;
	entry.ClientFree = rr_client_free;
	entry.ClientStart = rr_client_start;
	entry.ClientStop = rr_client_stop;

	rdpContext* context = freerdp_client_context_new(&entry);
	if (!context)
		goto fail;

	rrContext* rr = (rrContext*)context;
	if (frontend)
		rr->fe = *frontend;
	rr->user = user;

	if (!rr_settings_parse(rr, argc, argv, &code))
	{
		freerdp_client_context_free(context);
		goto fail;
	}

	if (exitCode)
		*exitCode = 0;
	return rr;

fail:
	if (exitCode)
		*exitCode = code;
	return NULL;
}

void rr_free(rrContext* rr)
{
	if (rr)
		freerdp_client_context_free(&rr->common.context);
}

void* rr_user(rrContext* rr)
{
	return rr ? rr->user : NULL;
}

rdpContext* rr_rdp(rrContext* rr)
{
	return rr ? &rr->common.context : NULL;
}

rdpSettings* rr_settings(rrContext* rr)
{
	return rr ? rr->common.context.settings : NULL;
}

rrMode rr_mode(rrContext* rr)
{
	return rr->mode;
}

BOOL rr_size_given(rrContext* rr)
{
	return rr->sizeGiven;
}

BOOL rr_start(rrContext* rr)
{
	return freerdp_client_start(&rr->common.context) == 0;
}

void rr_stop(rrContext* rr)
{
	(void)freerdp_client_stop(&rr->common.context);
}

BOOL rr_suppress_output(rrContext* rr, BOOL suppress)
{
	rdpGdi* gdi = rr->common.context.gdi;

	if (!gdi)
		return FALSE;
	return gdi_send_suppress_output(gdi, suppress);
}
