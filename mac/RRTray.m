/*
 * rdp-retina – Tray-Symbole entfernter Anwendungen in der Menüleiste (Stufe 4)
 *
 * Ein Klick geht als Notify-Event an Windows; Kontextmenüs öffnet Windows selbst als
 * RemoteApp-Fenster an der Mausposition der Sitzung.
 */
#import "RRTray.h"
#import "RRSession.h"

#include <freerdp/rail.h>

static NSString *RRTrayKey(UINT32 windowId, UINT32 iconId)
{
	return [NSString stringWithFormat:@"%u/%u", windowId, iconId];
}

@implementation RRTray
{
	__weak RRSession *_session;
	NSMutableDictionary<NSString *, NSStatusItem *> *_items;
}

- (instancetype)initWithSession:(RRSession *)session
{
	self = [super init];
	if (self)
	{
		_session = session;
		_items = [NSMutableDictionary new];
	}
	return self;
}

- (void)iconChanged:(UINT32)windowId
             iconId:(UINT32)iconId
            tooltip:(NSString *)tooltip
              image:(NSImage *)image
{
	NSString *key = RRTrayKey(windowId, iconId);
	NSStatusItem *item = _items[key];

	if (!item)
	{
		item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
		item.button.identifier = key;
		item.button.target = self;
		item.button.action = @selector(clicked:);
		[item.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];
		_items[key] = item;
	}

	if (image)
	{
		NSImage *icon = [image copy];
		icon.size = NSMakeSize(18, 18);
		item.button.image = icon;
	}
	if (tooltip)
		item.button.toolTip = tooltip;
}

- (void)iconDeleted:(UINT32)windowId iconId:(UINT32)iconId
{
	NSString *key = RRTrayKey(windowId, iconId);
	NSStatusItem *item = _items[key];
	if (!item)
		return;

	[NSStatusBar.systemStatusBar removeStatusItem:item];
	[_items removeObjectForKey:key];
}

- (void)removeAll
{
	for (NSStatusItem *item in _items.allValues)
		[NSStatusBar.systemStatusBar removeStatusItem:item];
	[_items removeAllObjects];
}

- (void)clicked:(NSStatusBarButton *)sender
{
	RRSession *session = _session;
	NSArray<NSString *> *parts = [sender.identifier componentsSeparatedByString:@"/"];
	if (!session || (parts.count != 2))
		return;

	const UINT32 windowId = (UINT32)parts[0].longLongValue;
	const UINT32 iconId = (UINT32)parts[1].longLongValue;
	NSEvent *event = NSApp.currentEvent;
	const BOOL secondary = (event.type == NSEventTypeRightMouseUp) ||
	                       ((event.modifierFlags & NSEventModifierFlagControl) != 0);
	rrContext *rr = session.rr;

	const NSPoint point = [session serverPointFromScreenPoint:NSEvent.mouseLocation];
	(void)rr_mouse_move(rr, (INT32)point.x, (INT32)point.y);

	if (secondary)
	{
		(void)rr_rail_notify_event(rr, windowId, iconId, WM_RBUTTONDOWN);
		(void)rr_rail_notify_event(rr, windowId, iconId, WM_RBUTTONUP);
		(void)rr_rail_notify_event(rr, windowId, iconId, WM_CONTEXTMENU);
	}
	else
	{
		(void)rr_rail_notify_event(rr, windowId, iconId, WM_LBUTTONDOWN);
		(void)rr_rail_notify_event(rr, windowId, iconId, WM_LBUTTONUP);
		(void)rr_rail_notify_event(rr, windowId, iconId, NIN_SELECT);
	}
}

@end
