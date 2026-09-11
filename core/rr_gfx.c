/*
 * rdp-retina – Grafik-Pipeline (MS-RDPEGFX)
 *
 * Die Dekodierung übernimmt FreeRDPs GDI. Hier wird nur eingehängt:
 *   - Fensterflächen im RemoteApp-Modus an die Oberfläche geben
 *   - mitzählen, welche Codecs der Server wirklich schickt (Abnahme P8)
 */
#include <stdlib.h>

#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/codec/region.h>
#include <freerdp/channels/rdpgfx.h>

#include "rr_private.h"

static rrContext* rr_from_gfx(RdpgfxClientContext* gfx)
{
	const rdpGdi* gdi = gfx ? (rdpGdi*)gfx->custom : NULL;
	return gdi ? (rrContext*)gdi->context : NULL;
}

const char* rr_codec_name(UINT32 codecId)
{
	switch (codecId)
	{
		case RDPGFX_CODECID_UNCOMPRESSED:
			return "unkomprimiert";
		case RDPGFX_CODECID_CAVIDEO:
			return "RemoteFX";
		case RDPGFX_CODECID_CLEARCODEC:
			return "ClearCodec";
		case RDPGFX_CODECID_CAPROGRESSIVE:
			return "Progressive";
		case RDPGFX_CODECID_PLANAR:
			return "Planar";
		case RDPGFX_CODECID_AVC420:
			return "AVC420";
		case RDPGFX_CODECID_ALPHA:
			return "Alpha";
		case RDPGFX_CODECID_CAPROGRESSIVE_V2:
			return "ProgressiveV2";
		case RDPGFX_CODECID_AVC444:
			return "AVC444";
		case RDPGFX_CODECID_AVC444v2:
			return "AVC444v2";
		default:
			return "?";
	}
}

static UINT rr_gfx_surface_command(RdpgfxClientContext* gfx, const RDPGFX_SURFACE_COMMAND* cmd)
{
	rrContext* rr = rr_from_gfx(gfx);

	if (!rr)
		return ERROR_INTERNAL_ERROR;

	EnterCriticalSection(&rr->statsLock);
	rr->stats.surfaceCommands++;
	if (cmd->codecId < ARRAYSIZE(rr->stats.codec))
		rr->stats.codec[cmd->codecId]++;
	LeaveCriticalSection(&rr->statsLock);

	if (!rr->gfxSurfaceCommand)
		return CHANNEL_RC_OK;
	return rr->gfxSurfaceCommand(gfx, cmd);
}

static UINT rr_gfx_end_frame(RdpgfxClientContext* gfx, const RDPGFX_END_FRAME_PDU* endFrame)
{
	rrContext* rr = rr_from_gfx(gfx);

	if (!rr)
		return ERROR_INTERNAL_ERROR;

	EnterCriticalSection(&rr->statsLock);
	rr->stats.frames++;
	LeaveCriticalSection(&rr->statsLock);

	if (!rr->gfxEndFrame)
		return CHANNEL_RC_OK;
	return rr->gfxEndFrame(gfx, endFrame);
}

static UINT rr_gfx_caps_confirm(RdpgfxClientContext* gfx, const RDPGFX_CAPS_CONFIRM_PDU* pdu)
{
	rrContext* rr = rr_from_gfx(gfx);

	if (!rr || !pdu || !pdu->capsSet)
		return CHANNEL_RC_OK;

	EnterCriticalSection(&rr->statsLock);
	rr->stats.capsVersion = pdu->capsSet->version;
	rr->stats.capsFlags = pdu->capsSet->flags;
	LeaveCriticalSection(&rr->statsLock);

	WLog_Print(rr->log, WLOG_INFO, "GFX bestätigt: Version 0x%08" PRIX32 ", Flags 0x%08" PRIX32,
	           pdu->capsSet->version, pdu->capsSet->flags);
	return CHANNEL_RC_OK;
}

static UINT rr_gfx_update_window(RdpgfxClientContext* gfx, gdiGfxSurface* surface)
{
	rrContext* rr = rr_from_gfx(gfx);

	if (!rr || !surface)
		return ERROR_INTERNAL_ERROR;

	const UINT32 windowId = (UINT32)surface->windowId;
	const UINT32 width = MIN(surface->mappedWidth, surface->width);
	const UINT32 height = MIN(surface->mappedHeight, surface->height);
	const BOOL full = rr_rail_take_surface_change(rr, windowId, surface->surfaceId);
	UINT32 nrects = 0;
	const RECTANGLE_16* invalid = region16_rects(&surface->invalidRegion, &nrects);
	UINT rc = CHANNEL_RC_OK;

	if ((full || (nrects > 0)) && rr->fe.WindowSurface)
	{
		rrRect local[32];
		rrRect* rects = local;
		UINT32 count = 0;

		if (nrects > ARRAYSIZE(local))
			rects = calloc(nrects, sizeof(rrRect));

		if (rects)
		{
			for (UINT32 i = 0; i < nrects; i++)
			{
				const UINT32 left = MIN(invalid[i].left, width);
				const UINT32 top = MIN(invalid[i].top, height);
				const UINT32 right = MIN(invalid[i].right, width);
				const UINT32 bottom = MIN(invalid[i].bottom, height);

				if ((right <= left) || (bottom <= top))
					continue;
				rects[count].x = (INT32)left;
				rects[count].y = (INT32)top;
				rects[count].width = right - left;
				rects[count].height = bottom - top;
				count++;
			}

			if (!rr->fe.WindowSurface(rr, windowId, surface->data, surface->scanline, width,
			                          height, rects, count, full,
			                          FreeRDPColorHasAlpha(surface->format)))
				rc = ERROR_INTERNAL_ERROR;

			if (rects != local)
				free(rects);
		}
	}

	/* Anders als bei Ausgabeflächen löscht FreeRDP die Region hier nicht selbst. */
	region16_clear(&surface->invalidRegion);
	return rc;
}

static UINT rr_gfx_map_window(RdpgfxClientContext* gfx, UINT16 surfaceId, UINT64 windowId)
{
	rrContext* rr = rr_from_gfx(gfx);

	if (!rr)
		return ERROR_INTERNAL_ERROR;

	WLog_Print(rr->log, WLOG_DEBUG, "Fläche %" PRIu16 " -> Fenster 0x%08" PRIX64, surfaceId,
	           windowId);
	rr_rail_map_surface(rr, (UINT32)windowId, surfaceId, TRUE);
	return CHANNEL_RC_OK;
}

static UINT rr_gfx_unmap_window(RdpgfxClientContext* gfx, UINT64 windowId)
{
	rrContext* rr = rr_from_gfx(gfx);

	if (!rr)
		return ERROR_INTERNAL_ERROR;

	rr_rail_map_surface(rr, (UINT32)windowId, 0, FALSE);
	if (rr->fe.WindowSurfaceUnmapped)
		rr->fe.WindowSurfaceUnmapped(rr, (UINT32)windowId);
	return CHANNEL_RC_OK;
}

BOOL rr_gfx_init(rrContext* rr, RdpgfxClientContext* gfx)
{
	rdpGdi* gdi = rr->common.context.gdi;

	if (!gdi || !gfx)
		return FALSE;

	if (!gdi_graphics_pipeline_init_ex(gdi, gfx, rr_gfx_map_window, rr_gfx_unmap_window, NULL))
		return FALSE;

	rr->gfx = gfx;
	rr->gfxSurfaceCommand = gfx->SurfaceCommand;
	rr->gfxEndFrame = gfx->EndFrame;
	if (gfx->SurfaceCommand)
		gfx->SurfaceCommand = rr_gfx_surface_command;
	if (gfx->EndFrame)
		gfx->EndFrame = rr_gfx_end_frame;
	gfx->CapsConfirm = rr_gfx_caps_confirm;
	gfx->UpdateWindowFromSurface = rr_gfx_update_window;
	return TRUE;
}

void rr_gfx_uninit(rrContext* rr, RdpgfxClientContext* gfx)
{
	gdi_graphics_pipeline_uninit(rr->common.context.gdi, gfx);
	rr->gfx = NULL;
}

BOOL rr_gfx_stats(rrContext* rr, rrGfxStats* stats)
{
	if (!rr || !stats)
		return FALSE;

	EnterCriticalSection(&rr->statsLock);
	*stats = rr->stats;
	LeaveCriticalSection(&rr->statsLock);
	return TRUE;
}
