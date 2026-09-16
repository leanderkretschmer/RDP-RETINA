/*
 * rdp-retina – Bausteine für die Formulare des Hauptfensters
 */
#import "RRSettingsForm.h"

const CGFloat RRFormFieldWidth = 300;
const CGFloat RRFormTextWidth = 520;

NSString *RRFormTrimmed(NSString *text)
{
	return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSTextField *RRFormLabel(NSString *text)
{
	NSTextField *label = [NSTextField labelWithString:text];
	label.alignment = NSTextAlignmentRight;
	return label;
}

static void RRFormPrepareField(NSTextField *field, NSString *placeholder,
                               id<NSTextFieldDelegate> delegate)
{
	field.placeholderString = placeholder;
	field.delegate = delegate;
	field.lineBreakMode = NSLineBreakByTruncatingTail;
	field.translatesAutoresizingMaskIntoConstraints = NO;
	[field.widthAnchor constraintEqualToConstant:RRFormFieldWidth].active = YES;
}

NSTextField *RRFormTextField(NSString *placeholder, id<NSTextFieldDelegate> delegate)
{
	NSTextField *field = [NSTextField textFieldWithString:@""];
	RRFormPrepareField(field, placeholder, delegate);
	return field;
}

NSSecureTextField *RRFormSecureField(NSString *placeholder, id<NSTextFieldDelegate> delegate)
{
	NSSecureTextField *field = [NSSecureTextField textFieldWithString:@""];
	RRFormPrepareField(field, placeholder, delegate);
	return field;
}

NSTextField *RRFormHint(NSString *text)
{
	NSTextField *hint = [NSTextField wrappingLabelWithString:text];
	hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	hint.textColor = NSColor.secondaryLabelColor;
	hint.selectable = NO;
	hint.preferredMaxLayoutWidth = RRFormTextWidth;
	hint.translatesAutoresizingMaskIntoConstraints = NO;
	[hint.widthAnchor constraintLessThanOrEqualToConstant:RRFormTextWidth].active = YES;
	return hint;
}

NSTextField *RRFormHeadline(NSString *text)
{
	NSTextField *label = [NSTextField labelWithString:text];
	label.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize + 2];
	return label;
}

NSGridView *RRFormGrid(NSArray<NSArray<NSView *> *> *rows)
{
	NSGridView *grid = [NSGridView gridViewWithViews:rows];
	grid.translatesAutoresizingMaskIntoConstraints = NO;
	grid.rowSpacing = 10;
	grid.columnSpacing = 10;
	grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
	if (grid.numberOfColumns > 0)
		[grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	return grid;
}

NSStackView *RRFormRow(NSArray<NSView *> *views)
{
	NSStackView *row = [NSStackView stackViewWithViews:views];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	row.alignment = NSLayoutAttributeCenterY;
	row.spacing = 8;
	row.translatesAutoresizingMaskIntoConstraints = NO;
	return row;
}

NSStackView *RRFormColumn(NSArray<NSView *> *views)
{
	NSStackView *column = [NSStackView stackViewWithViews:views];
	column.orientation = NSUserInterfaceLayoutOrientationVertical;
	column.alignment = NSLayoutAttributeLeading;
	column.spacing = 14;
	column.translatesAutoresizingMaskIntoConstraints = NO;
	return column;
}

NSScrollView *RRFormTableScrollView(NSTableView *tableView, CGFloat rowHeight)
{
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
	column.width = 200;
	column.resizingMask = NSTableColumnAutoresizingMask;
	[tableView addTableColumn:column];

	tableView.headerView = nil;
	tableView.style = NSTableViewStyleInset;
	tableView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
	tableView.usesAutomaticRowHeights = NO;
	tableView.rowHeight = rowHeight;
	tableView.allowsEmptySelection = YES;
	tableView.allowsMultipleSelection = NO;

	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 230, 400)];
	scroll.documentView = tableView;
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = YES;
	scroll.borderType = NSBezelBorder;
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	return scroll;
}

NSSegmentedControl *RRFormAddRemoveControl(id target, SEL action)
{
	NSImage *add = [NSImage imageNamed:NSImageNameAddTemplate] ?: [NSImage new];
	NSImage *remove = [NSImage imageNamed:NSImageNameRemoveTemplate] ?: [NSImage new];
	NSSegmentedControl *control =
	    [NSSegmentedControl segmentedControlWithImages:@[ add, remove ]
	                                      trackingMode:NSSegmentSwitchTrackingMomentary
	                                            target:target
	                                            action:action];
	control.segmentStyle = NSSegmentStyleSmallSquare;
	[control setWidth:28 forSegment:0];
	[control setWidth:28 forSegment:1];
	[control setToolTip:@"Hinzufügen" forSegment:0];
	[control setToolTip:@"Entfernen" forSegment:1];
	control.translatesAutoresizingMaskIntoConstraints = NO;
	return control;
}

/* Die Tab-Ansicht richtet das Fenster nach der Größe der Seite aus; kleiner als das Fenster
 * selbst darf sie deshalb nicht werden. */
static void RRFormMinimumPageSize(NSView *page)
{
	[NSLayoutConstraint activateConstraints:@[
		[page.widthAnchor constraintGreaterThanOrEqualToConstant:760],
		[page.heightAnchor constraintGreaterThanOrEqualToConstant:480],
	]];
}

NSView *RRFormMasterDetail(NSScrollView *list, NSSegmentedControl *buttons, NSView *detail)
{
	NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 820, 560)];

	list.translatesAutoresizingMaskIntoConstraints = NO;
	buttons.translatesAutoresizingMaskIntoConstraints = NO;
	detail.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:list];
	[container addSubview:buttons];
	[container addSubview:detail];

	[NSLayoutConstraint activateConstraints:@[
		[list.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
		[list.topAnchor constraintEqualToAnchor:container.topAnchor constant:20],
		[list.widthAnchor constraintEqualToConstant:230],
		[buttons.leadingAnchor constraintEqualToAnchor:list.leadingAnchor],
		[buttons.topAnchor constraintEqualToAnchor:list.bottomAnchor constant:6],
		[buttons.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-20],
		[detail.leadingAnchor constraintEqualToAnchor:list.trailingAnchor constant:24],
		[detail.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],
		[detail.topAnchor constraintEqualToAnchor:container.topAnchor constant:20],
		[detail.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-20],
	]];
	RRFormMinimumPageSize(container);
	return container;
}

NSView *RRFormPage(NSView *content)
{
	NSView *page = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 820, 560)];

	content.translatesAutoresizingMaskIntoConstraints = NO;
	[page addSubview:content];
	[NSLayoutConstraint activateConstraints:@[
		[content.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:28],
		[content.topAnchor constraintEqualToAnchor:page.topAnchor constant:24],
		[content.trailingAnchor constraintLessThanOrEqualToAnchor:page.trailingAnchor constant:-28],
		[content.bottomAnchor constraintLessThanOrEqualToAnchor:page.bottomAnchor constant:-24],
	]];
	RRFormMinimumPageSize(page);
	return page;
}

void RRFormSetString(NSTextField *field, NSString *value)
{
	if (field.currentEditor)
		return;
	if (![field.stringValue isEqualToString:value])
		field.stringValue = value;
}

BOOL RRFormEndEditing(NSWindow *window)
{
	if (!window)
		return YES;
	return [window makeFirstResponder:nil];
}

NSImage *RRFormDotImage(NSColor *color)
{
	return [NSImage imageWithSize:NSMakeSize(10, 10)
	                      flipped:NO
	               drawingHandler:^BOOL(NSRect rect) {
		               [color setFill];
		               [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1, 1)] fill];
		               return YES;
	               }];
}

void RRFormShowAlert(NSWindow *window, NSString *message, NSString *information, NSAlertStyle style)
{
	NSAlert *alert = [NSAlert new];
	alert.alertStyle = style;
	alert.messageText = message;
	if (information.length > 0)
		alert.informativeText = information;

	if (window)
		[alert beginSheetModalForWindow:window completionHandler:nil];
	else
		(void)[alert runModal];
}

void RRFormShowError(NSWindow *window, NSString *message, NSError *error)
{
	RRFormShowAlert(window, message, error.localizedDescription, NSAlertStyleWarning);
}
