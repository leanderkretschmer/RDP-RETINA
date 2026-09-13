/*
 * rdp-retina – Kommandozeile und Sitzungsgeometrie
 *
 * Hier fallen die Entscheidungen, die Schärfe ausmachen:
 *   P2  Sitzungsgröße in Pixeln, nicht in Punkten
 *   P4  desktopScaleFactor an den Server, damit Windows größer rendert
 *   P6  RemoteApp bekommt ausdrücklich die Bildschirmgröße (sonst 1024x768)
 *   P8  H.264 4:4:4
 */
#include <stdlib.h>
#include <string.h>

#include <winpr/crt.h>

#include <freerdp/settings.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/locale/locale.h>

#include "rr_private.h"

static const char* rr_arg_name(const char* arg)
{
	while ((*arg == '/') || (*arg == '-') || (*arg == '+'))
		arg++;
	return arg;
}

static BOOL rr_arg_is(const char* arg, const char* name)
{
	const char* a = rr_arg_name(arg);
	const size_t len = strlen(name);
	return (strncmp(a, name, len) == 0) && ((a[len] == '\0') || (a[len] == ':'));
}

static BOOL rr_is_own_option(const char* arg)
{
	if ((arg[0] != '/') && (arg[0] != '-'))
		return FALSE;

	const char* a = rr_arg_name(arg);
	return (strncmp(a, "retina-", 7) == 0) || (strncmp(a, "probe-", 6) == 0);
}

BOOL rr_settings_parse(rrContext* rr, int argc, char** argv, int* exitCode)
{
	rdpSettings* settings = rr->common.context.settings;
	char** args = calloc((size_t)argc + 1, sizeof(char*));
	int count = 0;

	*exitCode = 1;
	if (!args)
		return FALSE;

	for (int i = 0; i < argc; i++)
	{
		const char* arg = argv[i];

		if ((i > 0) && rr_is_own_option(arg))
		{
			char** tmp = realloc(rr->options, (rr->optionCount + 1) * sizeof(char*));
			if (!tmp)
				goto fail;
			rr->options = tmp;
			rr->options[rr->optionCount] = _strdup(rr_arg_name(arg));
			if (!rr->options[rr->optionCount])
				goto fail;
			rr->optionCount++;
			continue;
		}

		if ((i > 0) && rr_arg_is(arg, "app"))
		{
			/* /app: darf mehrfach stehen, FreeRDP bekommt nur die erste Angabe. */
			const char* value = rr_arg_name(arg) + 3;
			if (*value == ':')
				value++;

			char** tmp = realloc(rr->apps, (rr->appCount + 1) * sizeof(char*));
			if (!tmp)
				goto fail;
			rr->apps = tmp;
			rr->apps[rr->appCount] = _strdup(value);
			if (!rr->apps[rr->appCount])
				goto fail;
			if (rr->appCount++ > 0)
				continue;
		}

		if (i > 0)
		{
			if (rr_arg_is(arg, "size") || rr_arg_is(arg, "w") || rr_arg_is(arg, "h"))
				rr->sizeGiven = TRUE;
			if (rr_arg_is(arg, "gfx") || rr_arg_is(arg, "rfx"))
				rr->gfxGiven = TRUE;
			if (rr_arg_is(arg, "auto-reconnect"))
				rr->reconnectGiven = TRUE;
		}
		args[count++] = argv[i];
	}

	const int status = freerdp_client_settings_parse_command_line(settings, count, args, FALSE);
	if (status != 0)
	{
		*exitCode =
		    freerdp_client_settings_command_line_status_print(settings, status, count, args);
		goto fail;
	}

	free(args);
	*exitCode = 0;
	return TRUE;

fail:
	free(args);
	return FALSE;
}

void rr_settings_free(rrContext* rr)
{
	for (size_t i = 0; i < rr->optionCount; i++)
		free(rr->options[i]);
	free(rr->options);
	rr->options = NULL;
	rr->optionCount = 0;

	for (size_t i = 0; i < rr->appCount; i++)
		free(rr->apps[i]);
	free(rr->apps);
	rr->apps = NULL;
	rr->appCount = 0;
}

size_t rr_app_count(rrContext* rr)
{
	return rr ? rr->appCount : 0;
}

const char* rr_app(rrContext* rr, size_t index)
{
	return (rr && (index < rr->appCount)) ? rr->apps[index] : NULL;
}

BOOL rr_multimon(rrContext* rr)
{
	return rr->multimon;
}

void rr_desktop_origin(rrContext* rr, INT32* x, INT32* y)
{
	if (x)
		*x = rr->originX;
	if (y)
		*y = rr->originY;
}

const char* rr_option(rrContext* rr, const char* name)
{
	const size_t len = strlen(name);

	for (size_t i = 0; i < rr->optionCount; i++)
	{
		const char* option = rr->options[i];

		if (strncmp(option, name, len) != 0)
			continue;
		if (option[len] == '\0')
			return "";
		if (option[len] == ':')
			return &option[len + 1];
	}
	return NULL;
}

/* Display Control verlangt gerade Maße zwischen 200 und 8192; gerade Pixelzahlen ergeben
 * auf Retina außerdem ganzzahlige Punkte. */
static UINT32 rr_session_dimension(UINT32 value)
{
	value = MAX(value, 200u);
	value = MIN(value, 8192u);
	return value & ~1u;
}

static UINT32 rr_device_scale(UINT32 desktopScale)
{
	if (desktopScale >= 180)
		return 180;
	if (desktopScale >= 140)
		return 140;
	return 100;
}

BOOL rr_configure(rrContext* rr, const rrScreen* screens, UINT32 count, UINT32 defaultWidth,
                  UINT32 defaultHeight)
{
	rdpSettings* settings = rr->common.context.settings;

	if (!screens || (count == 0))
		return FALSE;

	count = MIN(count, (UINT32)RR_MAX_SCREENS);
	memcpy(rr->screens, screens, count * sizeof(rrScreen));
	rr->screenCount = count;
	rr->primary = screens[0];
	for (UINT32 i = 0; i < count; i++)
	{
		if (screens[i].primary)
		{
			rr->primary = screens[i];
			break;
		}
	}
	const rrScreen* primary = &rr->primary;

	const BOOL remoteApp = freerdp_settings_get_bool(settings, FreeRDP_RemoteApplicationMode);
	rr->mode = remoteApp ? RR_MODE_REMOTEAPP : RR_MODE_DESKTOP;

	UINT32 width = 0;
	UINT32 height = 0;
	const char* origin = NULL;
	const UINT32 percent = freerdp_settings_get_uint32(settings, FreeRDP_PercentScreen);

	if (remoteApp)
	{
		/* P6: ohne Desktopfenster gibt es nichts, dessen Größe gemeldet werden könnte. */
		width = primary->frame.width;
		height = primary->frame.height;
		origin = "RemoteApp, primärer Bildschirm";
	}
	else if (freerdp_settings_get_bool(settings, FreeRDP_Fullscreen))
	{
		width = primary->frame.width;
		height = primary->frame.height;
		origin = "Vollbild";
	}
	else if (percent > 0)
	{
		BOOL useWidth = freerdp_settings_get_bool(settings, FreeRDP_PercentScreenUseWidth);
		BOOL useHeight = freerdp_settings_get_bool(settings, FreeRDP_PercentScreenUseHeight);
		if (!useWidth && !useHeight)
			useWidth = useHeight = TRUE;
		width = primary->workArea.width;
		height = primary->workArea.height;
		if (useWidth)
			width = width * percent / 100;
		if (useHeight)
			height = height * percent / 100;
		origin = "Anteil der nutzbaren Fläche";
	}
	else if (rr->sizeGiven)
	{
		width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
		height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
		origin = "wie angegeben";
	}
	else
	{
		width = defaultWidth ? defaultWidth : primary->workArea.width;
		height = defaultHeight ? defaultHeight : primary->workArea.height;
		origin = "nutzbare Fläche";
	}

	/* W3: mit /multimon alle Bildschirme (nur Vollbild und RemoteApp). */
	rr->multimon = FALSE;
	rr->originX = 0;
	rr->originY = 0;
	if (freerdp_settings_get_bool(settings, FreeRDP_UseMultimon) && (count > 1) &&
	    (remoteApp || freerdp_settings_get_bool(settings, FreeRDP_Fullscreen)))
	{
		const UINT64 overrideFlags =
		    freerdp_settings_get_uint64(settings, FreeRDP_MonitorOverrideFlags);
		rdpMonitor monitors[RR_MAX_SCREENS] = { 0 };
		INT64 left = INT32_MAX;
		INT64 top = INT32_MAX;
		INT64 right = INT32_MIN;
		INT64 bottom = INT32_MIN;

		for (UINT32 i = 0; i < count; i++)
		{
			const rrScreen* s = &rr->screens[i];
			rdpMonitor* m = &monitors[i];
			UINT32 scale = MIN(MAX(s->scalePercent, 100u), 500u);
			if (overrideFlags & FREERDP_MONITOR_OVERRIDE_DESKTOP_SCALE)
				scale = freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);

			m->x = s->frame.x;
			m->y = s->frame.y;
			m->width = (INT32)s->frame.width;
			m->height = (INT32)s->frame.height;
			m->is_primary = s->primary ? 1 : 0;
			m->orig_screen = i;
			m->attributes.physicalWidth = s->physicalWidthMm;
			m->attributes.physicalHeight = s->physicalHeightMm;
			m->attributes.orientation = ORIENTATION_LANDSCAPE;
			m->attributes.desktopScaleFactor = scale;
			m->attributes.deviceScaleFactor = rr_device_scale(scale);

			left = MIN(left, (INT64)s->frame.x);
			top = MIN(top, (INT64)s->frame.y);
			right = MAX(right, (INT64)s->frame.x + s->frame.width);
			bottom = MAX(bottom, (INT64)s->frame.y + s->frame.height);
		}

		if (!freerdp_settings_set_monitor_def_array_sorted(settings, monitors, count))
			return FALSE;

		rr->multimon = TRUE;
		rr->originX = (INT32)left;
		rr->originY = (INT32)top;
		width = (UINT32)(right - left);
		height = (UINT32)(bottom - top);
		origin = "alle Bildschirme";
	}

	const UINT32 sessionWidth = rr->multimon ? (MIN(width, 32766u) & ~1u) : rr_session_dimension(width);
	const UINT32 sessionHeight =
	    rr->multimon ? (MIN(height, 32766u) & ~1u) : rr_session_dimension(height);
	if ((sessionWidth != width) || (sessionHeight != height))
		WLog_Print(rr->log, WLOG_WARN,
		           "Sitzungsgröße %" PRIu32 "x%" PRIu32 " auf %" PRIu32 "x%" PRIu32 " angepasst",
		           width, height, sessionWidth, sessionHeight);

	if (!freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, sessionWidth) ||
	    !freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, sessionHeight))
		return FALSE;

	/* P4: Windows soll selbst größer rendern. Ohne /scale gilt der Faktor des Bildschirms. */
	const UINT64 overrides = freerdp_settings_get_uint64(settings, FreeRDP_MonitorOverrideFlags);
	UINT32 desktopScale = freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);
	UINT32 deviceScale = freerdp_settings_get_uint32(settings, FreeRDP_DeviceScaleFactor);

	if (((overrides & FREERDP_MONITOR_OVERRIDE_DESKTOP_SCALE) == 0) &&
	    (primary->scalePercent >= 100))
		desktopScale = MIN(primary->scalePercent, 500u);
	if ((overrides & FREERDP_MONITOR_OVERRIDE_DEVICE_SCALE) == 0)
		deviceScale = rr_device_scale(desktopScale);
	/* Der Server ignoriert desktopScaleFactor, wenn deviceScaleFactor ungültig ist. */
	if ((deviceScale != 100) && (deviceScale != 140) && (deviceScale != 180))
		deviceScale = 100;

	if (!freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, desktopScale) ||
	    !freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, deviceScale))
		return FALSE;

	/* Physische Größe der Sitzungsfläche; außerhalb 10..10000 mm verwirft der Server sie. */
	if ((primary->physicalWidthMm >= 10) && (primary->physicalHeightMm >= 10) &&
	    (primary->frame.width > 0) && (primary->frame.height > 0))
	{
		const UINT32 mmWidth =
		    (UINT32)((UINT64)primary->physicalWidthMm * sessionWidth / primary->frame.width);
		const UINT32 mmHeight =
		    (UINT32)((UINT64)primary->physicalHeightMm * sessionHeight / primary->frame.height);
		if ((mmWidth >= 10) && (mmHeight >= 10) && (mmWidth <= 10000) && (mmHeight <= 10000))
		{
			if (!freerdp_settings_set_uint32(settings, FreeRDP_DesktopPhysicalWidth, mmWidth) ||
			    !freerdp_settings_set_uint32(settings, FreeRDP_DesktopPhysicalHeight, mmHeight))
				return FALSE;
		}
	}

	/* P8: ohne 4:4:4 verschmiert farbiges Subpixel-Antialiasing. */
	if (!rr->gfxGiven)
	{
		if (!freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) ||
		    !freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE) ||
		    !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, TRUE) ||
		    !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, TRUE))
			return FALSE;
	}
	else if (!freerdp_settings_get_bool(settings, FreeRDP_GfxAVC444))
		WLog_Print(rr->log, WLOG_WARN,
		           "ohne /gfx:AVC444 wird farbiges Text-Antialiasing unscharf übertragen");

	/* W4: nach einer Netzunterbrechung neu verbinden, sofern nicht ausdrücklich abgeschaltet */
	if (!rr->reconnectGiven &&
	    !freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, TRUE))
		return FALSE;

	if (remoteApp)
	{
		/* Symbole in Retina-Auflösung */
		const UINT32 flags = freerdp_settings_get_uint32(settings, FreeRDP_RemoteAppFeatureFlags);
		if (!freerdp_settings_set_uint32(settings, FreeRDP_RemoteAppFeatureFlags,
		                                 flags | TS_RAIL_CLIENTSTATUS_HIGH_DPI_ICONS_SUPPORTED))
			return FALSE;
	}

	if (freerdp_settings_get_uint32(settings, FreeRDP_KeyboardLayout) == 0)
	{
		DWORD layout = 0;
		if ((freerdp_detect_keyboard_layout_from_system_locale(&layout) >= 0) && (layout != 0))
			(void)freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, layout);
	}

	WLog_Print(rr->log, WLOG_INFO,
	           "Sitzung %" PRIu32 "x%" PRIu32 " Pixel (%s), Skalierung %" PRIu32 " %%/%" PRIu32
	           " %%, H.264 %s, AVC444 %s, RemoteApp %s",
	           sessionWidth, sessionHeight, origin, desktopScale, deviceScale,
	           freerdp_settings_get_bool(settings, FreeRDP_GfxH264) ? "an" : "aus",
	           freerdp_settings_get_bool(settings, FreeRDP_GfxAVC444) ? "an" : "aus",
	           remoteApp ? "ja" : "nein");
	return TRUE;
}
