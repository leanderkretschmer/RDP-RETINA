/*
 * rdp-retina – Tastatur (P7)
 */
#import "RRKeyboard.h"
#import "RRInputSource.h"

#include <freerdp/scancode.h>

/* Virtuelle Tastencodes aus HIToolbox/Events.h und geräteabhängige Modifier-Bits aus
 * IOKit/hidsystem/IOLLEvent.h – als Zahlen, weil Carbon und WinPR nicht zusammenpassen. */
enum
{
	RR_VK_RightCommand = 0x36,
	RR_VK_Command = 0x37,
	RR_VK_Shift = 0x38,
	RR_VK_CapsLock = 0x39,
	RR_VK_Option = 0x3A,
	RR_VK_Control = 0x3B,
	RR_VK_RightShift = 0x3C,
	RR_VK_RightOption = 0x3D,
	RR_VK_RightControl = 0x3E,
	RR_VK_Function = 0x3F,
};

enum
{
	RR_NX_DEVICELCTLKEYMASK = 0x00000001,
	RR_NX_DEVICELSHIFTKEYMASK = 0x00000002,
	RR_NX_DEVICERSHIFTKEYMASK = 0x00000004,
	RR_NX_DEVICELCMDKEYMASK = 0x00000008,
	RR_NX_DEVICERCMDKEYMASK = 0x00000010,
	RR_NX_DEVICELALTKEYMASK = 0x00000020,
	RR_NX_DEVICERALTKEYMASK = 0x00000040,
	RR_NX_DEVICERCTLKEYMASK = 0x00002000,
};

static NSUInteger RRDeviceModifierMask(UInt16 keycode)
{
	switch (keycode)
	{
		case RR_VK_Shift:
			return RR_NX_DEVICELSHIFTKEYMASK;
		case RR_VK_RightShift:
			return RR_NX_DEVICERSHIFTKEYMASK;
		case RR_VK_Control:
			return RR_NX_DEVICELCTLKEYMASK;
		case RR_VK_RightControl:
			return RR_NX_DEVICERCTLKEYMASK;
		case RR_VK_Option:
			return RR_NX_DEVICELALTKEYMASK;
		case RR_VK_RightOption:
			return RR_NX_DEVICERALTKEYMASK;
		case RR_VK_Command:
			return RR_NX_DEVICELCMDKEYMASK;
		case RR_VK_RightCommand:
			return RR_NX_DEVICERCMDKEYMASK;
		default:
			return 0;
	}
}

@implementation RRKeyboard
{
	rrContext *_rr;
	BOOL _iso;
	NSMutableSet<NSNumber *> *_pressed;
	BOOL _modifierDown[128];
}

- (instancetype)initWithContext:(rrContext *)rr
{
	self = [super init];
	if (self)
	{
		_rr = rr;
		_commandAsControl = YES;
		_pressed = [NSMutableSet new];
		_iso = RRInputSourceIsISO();
	}
	return self;
}

+ (BOOL)isISOKeyboard
{
	return RRInputSourceIsISO();
}

+ (DWORD)currentLayoutId
{
	return RRInputSourceLayoutId();
}

/* RDP_SCANCODE_* nutzen TRUE/FALSE, die CoreFoundation und WinPR beide definieren. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wambiguous-macro"

- (UINT32)scancodeForKeycode:(UInt16)keycode
{
	switch (keycode)
	{
		case RR_VK_Command:
			return self.commandAsControl ? RDP_SCANCODE_LCONTROL : RDP_SCANCODE_LWIN;
		case RR_VK_RightCommand:
			return RDP_SCANCODE_RWIN;
		case RR_VK_Option:
			return RDP_SCANCODE_LMENU;
		case RR_VK_RightOption:
			return RDP_SCANCODE_RMENU;
		case RR_VK_Control:
			return RDP_SCANCODE_LCONTROL;
		case RR_VK_RightControl:
			return RDP_SCANCODE_RCONTROL;
		case RR_VK_Shift:
			return RDP_SCANCODE_LSHIFT;
		case RR_VK_RightShift:
			return RDP_SCANCODE_RSHIFT;
		case RR_VK_CapsLock:
			return RDP_SCANCODE_CAPSLOCK;
		case RR_VK_Function:
			return 0;
		default:
			return rr_scancode_from_apple_keycode(keycode, _iso);
	}
}

#pragma clang diagnostic pop

- (void)sendKeycode:(UInt16)keycode down:(BOOL)down repeat:(BOOL)repeat
{
	const UINT32 scancode = [self scancodeForKeycode:keycode];
	if (scancode == 0)
		return;

	if (down)
		[_pressed addObject:@(scancode)];
	else
		[_pressed removeObject:@(scancode)];
	(void)rr_key_scancode(_rr, scancode, down, repeat);
}

- (void)handleEvent:(NSEvent *)event
{
	switch (event.type)
	{
		case NSEventTypeKeyDown:
			[self sendKeycode:event.keyCode down:YES repeat:event.ARepeat];
			break;
		case NSEventTypeKeyUp:
			[self sendKeycode:event.keyCode down:NO repeat:NO];
			break;
		case NSEventTypeFlagsChanged:
			[self flagsChanged:event];
			break;
		default:
			break;
	}
}

- (void)flagsChanged:(NSEvent *)event
{
	const UInt16 keycode = event.keyCode;

	if (keycode == RR_VK_CapsLock)
	{
		/* macOS meldet nur den neuen Zustand, Windows erwartet einen Tastendruck. */
		[self sendKeycode:keycode down:YES repeat:NO];
		[self sendKeycode:keycode down:NO repeat:NO];
		return;
	}

	const NSUInteger mask = RRDeviceModifierMask(keycode);
	if ((mask == 0) || (keycode >= sizeof(_modifierDown)))
		return;

	/* Die geräteabhängigen Bits unterscheiden linke und rechte Taste. */
	const BOOL down = (event.modifierFlags & mask) != 0;
	if (down == _modifierDown[keycode])
		return;

	_modifierDown[keycode] = down;
	[self sendKeycode:keycode down:down repeat:NO];
}

- (void)releaseAll
{
	for (NSNumber *scancode in _pressed.allObjects)
		(void)rr_key_scancode(_rr, scancode.unsignedIntValue, NO, NO);
	[_pressed removeAllObjects];
	memset(_modifierDown, 0, sizeof(_modifierDown));
}

- (void)syncLockStates
{
	const BOOL capsLock = (NSEvent.modifierFlags & NSEventModifierFlagCapsLock) != 0;
	/* Der Mac-Ziffernblock liefert immer Ziffern, also NumLock an. */
	(void)rr_focus_in(_rr, capsLock, YES);
}

@end
