/*
 * rdp-retina – Display Control (MS-RDPEDISP)
 *
 * P3: Passt die Sitzung nicht zum Fenster, wird die Sitzung angepasst, nicht das Bild.
 * Die Oberfläche meldet die gewünschte Pixelgröße; hier wird entprellt und gesendet.
 */
#include <winpr/sysinfo.h>

#include <freerdp/settings.h>
#include <freerdp/channels/disp.h>

#include "rr_private.h"

/* Mindestabstand zwischen zwei Layout-Meldungen. Schneller verschluckt sich der Server. */
#define RR_DISP_MIN_INTERVAL_MS 300

static UINT rr_disp_caps(DispClientContext* disp, UINT32 maxNumMonitors,
                         UINT32 maxMonitorAreaFactorA, UINT32 maxMonitorAreaFactorB)
{
	rrContext* rr = (rrContext*)disp->custom;

	if (!rr)
		return CHANNEL_RC_OK;

	WLog_Print(rr->log, WLOG_DEBUG,
	           "Display Control bereit: bis %" PRIu32 " Bildschirme, Fläche %" PRIu32 "x%" PRIu32,
	           maxNumMonitors, maxMonitorAreaFactorA, maxMonitorAreaFactorB);

	EnterCriticalSection(&rr->dispLock);
	rr->dispReady = TRUE;
	LeaveCriticalSection(&rr->dispLock);

	rr_disp_tick(rr);
	return CHANNEL_RC_OK;
}

BOOL rr_disp_init(rrContext* rr, DispClientContext* disp)
{
	if (!disp)
		return FALSE;

	EnterCriticalSection(&rr->dispLock);
	rr->disp = disp;
	disp->custom = rr;
	disp->DisplayControlCaps = rr_disp_caps;
	LeaveCriticalSection(&rr->dispLock);
	return TRUE;
}

void rr_disp_uninit(rrContext* rr, DispClientContext* disp)
{
	EnterCriticalSection(&rr->dispLock);
	if (disp)
		disp->custom = NULL;
	rr->disp = NULL;
	rr->dispReady = FALSE;
	LeaveCriticalSection(&rr->dispLock);
}

BOOL rr_request_size(rrContext* rr, UINT32 width, UINT32 height)
{
	width = MIN(MAX(width, 200u), 8192u) & ~1u;
	height = MIN(MAX(height, 200u), 8192u) & ~1u;

	EnterCriticalSection(&rr->dispLock);
	rr->dispWantWidth = width;
	rr->dispWantHeight = height;
	LeaveCriticalSection(&rr->dispLock);

	rr_disp_tick(rr);
	return TRUE;
}

void rr_disp_tick(rrContext* rr)
{
	rdpSettings* settings = rr->common.context.settings;

	if (!freerdp_settings_get_bool(settings, FreeRDP_DynamicResolutionUpdate))
		return;

	EnterCriticalSection(&rr->dispLock);

	const UINT32 width = rr->dispWantWidth;
	const UINT32 height = rr->dispWantHeight;

	if (!rr->dispReady || !rr->disp || (width == 0) || (height == 0))
		goto out;

	/* Schon gesendet und noch nicht umgesetzt, oder bereits die aktuelle Größe */
	if ((width == rr->dispSentWidth) && (height == rr->dispSentHeight))
		goto out;
	if ((rr->dispSentWidth == 0) &&
	    (width == freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth)) &&
	    (height == freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight)))
	{
		rr->dispWantWidth = rr->dispWantHeight = 0;
		goto out;
	}

	const UINT64 now = GetTickCount64();
	if (now - rr->dispSentAt < RR_DISP_MIN_INTERVAL_MS)
		goto out;

	DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
	layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
	layout.Width = width;
	layout.Height = height;
	layout.Orientation = ORIENTATION_LANDSCAPE;
	layout.DesktopScaleFactor = freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);
	layout.DeviceScaleFactor = freerdp_settings_get_uint32(settings, FreeRDP_DeviceScaleFactor);

	const rrScreen* primary = &rr->primary;
	if ((primary->frame.width > 0) && (primary->frame.height > 0))
	{
		layout.PhysicalWidth =
		    (UINT32)((UINT64)primary->physicalWidthMm * width / primary->frame.width);
		layout.PhysicalHeight =
		    (UINT32)((UINT64)primary->physicalHeightMm * height / primary->frame.height);
	}

	const UINT rc = rr->disp->SendMonitorLayout(rr->disp, 1, &layout);
	if (rc == CHANNEL_RC_OK)
	{
		WLog_Print(rr->log, WLOG_INFO, "neue Sitzungsgröße angefordert: %" PRIu32 "x%" PRIu32,
		           width, height);
		rr->dispSentWidth = width;
		rr->dispSentHeight = height;
		rr->dispSentAt = now;
	}
	else
		WLog_Print(rr->log, WLOG_WARN, "Größenmeldung fehlgeschlagen: 0x%08" PRIX32, rc);

out:
	LeaveCriticalSection(&rr->dispLock);
}
