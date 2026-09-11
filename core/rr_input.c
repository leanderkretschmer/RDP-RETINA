/*
 * rdp-retina – Eingabe
 *
 * Maus in Server-Pixeln, Tastatur als Scancodes. Welche Taste welches Zeichen ergibt,
 * entscheidet das Tastaturlayout der Sitzung (/kbd bzw. Systemsprache) – der Client
 * schickt nur die Lage der Taste. Das deutsche Layout funktioniert dadurch ohne Tabelle.
 */
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <winpr/input.h>

#include "rr_private.h"

/* Die Schnittstelle rechnet im virtuellen Bildschirm (primärer bei 0,0), der Server erwartet
 * Eingaben relativ zur linken oberen Ecke der Sitzung – bei /multimon ist das ein Unterschied
 * (gemessen: Rechtsklick auf den Desktop öffnet das Menü an der Pufferkoordinate).
 * Außerhalb der Sitzung bräche der Server die Koordinate als UINT16 um. */
static void rr_clamp_point(rrContext* rr, INT32* x, INT32* y)
{
	const rdpSettings* settings = rr->common.context.settings;
	const INT32 width = (INT32)freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
	const INT32 height = (INT32)freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);

	*x = MIN(MAX(*x - rr->originX, 0), MAX(width - 1, 0));
	*y = MIN(MAX(*y - rr->originY, 0), MAX(height - 1, 0));
}

BOOL rr_mouse_move(rrContext* rr, INT32 x, INT32 y)
{
	rr_clamp_point(rr, &x, &y);
	return freerdp_client_send_button_event(&rr->common, FALSE, PTR_FLAGS_MOVE, x, y);
}

BOOL rr_mouse_button(rrContext* rr, UINT32 button, BOOL down, INT32 x, INT32 y)
{
	rr_clamp_point(rr, &x, &y);
	switch (button)
	{
		case 0:
			return freerdp_client_send_button_event(
			    &rr->common, FALSE, PTR_FLAGS_BUTTON1 | (down ? PTR_FLAGS_DOWN : 0), x, y);
		case 1:
			return freerdp_client_send_button_event(
			    &rr->common, FALSE, PTR_FLAGS_BUTTON2 | (down ? PTR_FLAGS_DOWN : 0), x, y);
		case 2:
			return freerdp_client_send_button_event(
			    &rr->common, FALSE, PTR_FLAGS_BUTTON3 | (down ? PTR_FLAGS_DOWN : 0), x, y);
		case 3:
			return freerdp_client_send_extended_button_event(
			    &rr->common, FALSE, PTR_XFLAGS_BUTTON1 | (down ? PTR_XFLAGS_DOWN : 0), x, y);
		case 4:
			return freerdp_client_send_extended_button_event(
			    &rr->common, FALSE, PTR_XFLAGS_BUTTON2 | (down ? PTR_XFLAGS_DOWN : 0), x, y);
		default:
			return TRUE;
	}
}

BOOL rr_mouse_wheel(rrContext* rr, BOOL horizontal, INT32 units)
{
	/* Ein Ereignis trägt höchstens 255 Einheiten als 9-Bit-Zweierkomplement. */
	while (units != 0)
	{
		const INT32 step = (units > 0) ? MIN(units, 0xFF) : MAX(units, -0xFF);
		UINT16 flags = horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;

		if (step < 0)
			flags |= PTR_FLAGS_WHEEL_NEGATIVE | (UINT16)((0x100 + step) & 0xFF);
		else
			flags |= (UINT16)(step & 0xFF);

		if (!freerdp_client_send_wheel_event(&rr->common, flags))
			return FALSE;
		units -= step;
	}
	return TRUE;
}

BOOL rr_key_scancode(rrContext* rr, UINT32 rdpScancode, BOOL down, BOOL repeat)
{
	return freerdp_input_send_keyboard_event_ex(rr->common.context.input, down, repeat,
	                                            rdpScancode);
}

BOOL rr_key_unicode(rrContext* rr, UINT16 codeUnit, BOOL down)
{
	return freerdp_input_send_unicode_keyboard_event(rr->common.context.input,
	                                                 down ? 0 : KBD_FLAGS_RELEASE, codeUnit);
}

BOOL rr_focus_in(rrContext* rr, BOOL capsLock, BOOL numLock)
{
	const UINT16 toggles =
	    (UINT16)((capsLock ? KBD_SYNC_CAPS_LOCK : 0) | (numLock ? KBD_SYNC_NUM_LOCK : 0));
	return freerdp_input_send_focus_in_event(rr->common.context.input, toggles);
}

UINT32 rr_scancode_from_apple_keycode(UINT32 keycode, BOOL iso)
{
	/* Apple-ISO-Tastaturen melden ^ und < mit vertauschten Codes. */
	if (iso)
	{
		if (keycode == APPLE_VK_ISO_Section)
			keycode = APPLE_VK_ANSI_Grave;
		else if (keycode == APPLE_VK_ANSI_Grave)
			keycode = APPLE_VK_ISO_Section;
	}

	switch (keycode)
	{
		/* In der WinPR-Tabelle stehen hier Windows-Tasten; beides ist falsch. */
		case APPLE_VK_RightControl:
			return RDP_SCANCODE_RCONTROL;
		case APPLE_VK_Function:
			return 0;
		default:
			break;
	}

	const DWORD vkcode = GetVirtualKeyCodeFromKeycode(keycode, WINPR_KEYCODE_TYPE_APPLE);
	if (vkcode == 0)
		return 0;
	return GetVirtualScanCodeFromVirtualKeyCode(vkcode, WINPR_KBD_TYPE_IBM_ENHANCED);
}
