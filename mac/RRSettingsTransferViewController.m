/*
 * rdp-retina – Bereich „Übertragung“ des Hauptfensters
 *
 * Einstellungen für neue Verbindungen: Höchstzahl offener RemoteApps, Wiederverbinden, Ton,
 * Mikrofon, Zwischenablage, Bildschirme und Skalierung. Jede Änderung wird sofort gespeichert.
 */
#import "RRSettingsTransferViewController.h"
#import "RRConfig.h"
#import "RRSettingsForm.h"

static const NSInteger RRTransferMaxApps = 50;
static const NSInteger RRTransferMaxAttempts = 1000;

@interface RRSettingsTransferViewController () <NSTextFieldDelegate>
- (void)controlChanged:(id)sender;
- (void)stepperChanged:(NSStepper *)sender;
- (void)configDidChange:(NSNotification *)notification;
@end

@implementation RRSettingsTransferViewController
{
	NSTextField *_maxAppsField;
	NSStepper *_maxAppsStepper;
	NSButton *_reconnectCheckbox;
	NSTextField *_attemptsField;
	NSStepper *_attemptsStepper;
	NSPopUpButton *_soundPopup;
	NSButton *_microphoneCheckbox;
	NSButton *_clipboardCheckbox;
	NSButton *_multimonCheckbox;
	NSPopUpButton *_scalePopup;
	BOOL _updating;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

/* ---- Aufbau ---------------------------------------------------------------------------- */

- (NSTextField *)makeNumberField
{
	NSTextField *field = [NSTextField textFieldWithString:@"0"];
	field.alignment = NSTextAlignmentRight;
	field.delegate = self;
	field.translatesAutoresizingMaskIntoConstraints = NO;
	[field.widthAnchor constraintEqualToConstant:64].active = YES;
	return field;
}

- (NSStepper *)makeStepperFrom:(double)minimum to:(double)maximum
{
	NSStepper *stepper = [NSStepper new];
	stepper.minValue = minimum;
	stepper.maxValue = maximum;
	stepper.increment = 1;
	stepper.valueWraps = NO;
	stepper.autorepeat = YES;
	stepper.target = self;
	stepper.action = @selector(stepperChanged:);
	return stepper;
}

- (NSPopUpButton *)makePopupWithTitles:(NSArray<NSString *> *)titles tags:(NSArray<NSNumber *> *)tags
{
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	popup.autoenablesItems = NO;
	for (NSUInteger i = 0; (i < titles.count) && (i < tags.count); i++)
	{
		NSMenuItem *item = [popup.menu addItemWithTitle:titles[i] action:NULL keyEquivalent:@""];
		item.tag = tags[i].integerValue;
	}
	popup.target = self;
	popup.action = @selector(controlChanged:);
	return popup;
}

- (NSButton *)makeCheckbox:(NSString *)title
{
	return [NSButton checkboxWithTitle:title target:self action:@selector(controlChanged:)];
}

- (void)loadView
{
	_maxAppsField = [self makeNumberField];
	_maxAppsStepper = [self makeStepperFrom:0 to:RRTransferMaxApps];
	_reconnectCheckbox = [self makeCheckbox:@"Automatisch neu verbinden"];
	_attemptsField = [self makeNumberField];
	_attemptsStepper = [self makeStepperFrom:1 to:RRTransferMaxAttempts];
	_soundPopup = [self makePopupWithTitles:@[ @"Auf diesem Mac", @"Auf dem Server", @"Aus" ]
	                                   tags:@[ @(RRSoundModeMac), @(RRSoundModeServer), @(RRSoundModeOff) ]];
	_microphoneCheckbox = [self makeCheckbox:@"Mikrofon übertragen"];
	_clipboardCheckbox = [self makeCheckbox:@"Zwischenablage teilen"];
	_multimonCheckbox = [self makeCheckbox:@"Alle Bildschirme verwenden"];
	_scalePopup = [self makePopupWithTitles:@[
		@"Wie der Bildschirm", @"100 %", @"125 %", @"150 %", @"175 %", @"200 %", @"250 %", @"300 %"
	]
	                                   tags:@[ @0, @100, @125, @150, @175, @200, @250, @300 ]];

	NSGridView *grid = RRFormGrid(@[
		@[
			RRFormLabel(@"Gleichzeitig offene RemoteApps:"),
			RRFormRow(@[ _maxAppsField, _maxAppsStepper, RRFormHint(@"0 = unbegrenzt") ])
		],
		@[ NSGridCell.emptyContentView, _reconnectCheckbox ],
		@[ RRFormLabel(@"Versuche:"), RRFormRow(@[ _attemptsField, _attemptsStepper ]) ],
		@[ RRFormLabel(@"Ton:"), _soundPopup ],
		@[ NSGridCell.emptyContentView, _microphoneCheckbox ],
		@[ NSGridCell.emptyContentView, _clipboardCheckbox ],
		@[ NSGridCell.emptyContentView, _multimonCheckbox ],
		@[ RRFormLabel(@"Skalierung:"), _scalePopup ],
	]);
	for (NSNumber *index in @[ @0, @2, @3, @7 ])
	{
		NSGridRow *row = [grid rowAtIndex:index.integerValue];
		row.rowAlignment = NSGridRowAlignmentNone;
		row.yPlacement = NSGridCellPlacementCenter;
	}
	[grid rowAtIndex:3].topPadding = 8;
	[grid rowAtIndex:7].topPadding = 8;

	NSStackView *column = RRFormColumn(@[
		RRFormHeadline(@"Übertragung"), grid, RRFormHint(@"Gilt für neue Verbindungen.")
	]);
	self.view = RRFormPage(column);

	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(configDidChange:)
	                                           name:RRConfigDidChangeNotification
	                                         object:nil];
	[self updateControls];
}

/* ---- Anzeige und Speichern --------------------------------------------------------------- */

- (void)updateControls
{
	RRTransferConfig *transfer = [RRConfig shared].transfer;
	const BOOL reconnect = transfer.autoReconnect;

	_updating = YES;
	if (!_maxAppsField.currentEditor)
		_maxAppsField.integerValue = transfer.maxApps;
	_maxAppsStepper.integerValue = transfer.maxApps;
	_reconnectCheckbox.state = reconnect ? NSControlStateValueOn : NSControlStateValueOff;
	if (!_attemptsField.currentEditor)
		_attemptsField.integerValue = transfer.reconnectAttempts;
	_attemptsStepper.integerValue = transfer.reconnectAttempts;
	_attemptsField.enabled = reconnect;
	_attemptsStepper.enabled = reconnect;
	[_soundPopup selectItemWithTag:transfer.sound];
	_microphoneCheckbox.state = transfer.microphone ? NSControlStateValueOn : NSControlStateValueOff;
	_clipboardCheckbox.state = transfer.clipboard ? NSControlStateValueOn : NSControlStateValueOff;
	_multimonCheckbox.state = transfer.multimon ? NSControlStateValueOn : NSControlStateValueOff;
	if (![_scalePopup selectItemWithTag:transfer.scalePercent])
	{
		/* Wert, den die Auswahl nicht kennt (z.B. von Hand gesetzt): trotzdem anzeigen */
		NSMenuItem *item = [_scalePopup.menu
		    addItemWithTitle:[NSString stringWithFormat:@"%ld %%", (long)transfer.scalePercent]
		              action:NULL
		       keyEquivalent:@""];
		item.tag = transfer.scalePercent;
		[_scalePopup selectItem:item];
	}
	_updating = NO;
}

- (void)save
{
	RRTransferConfig *transfer = [RRConfig shared].transfer;
	transfer.maxApps = MIN(MAX(_maxAppsField.integerValue, (NSInteger)0), RRTransferMaxApps);
	transfer.autoReconnect = (_reconnectCheckbox.state == NSControlStateValueOn);
	transfer.reconnectAttempts =
	    MIN(MAX(_attemptsField.integerValue, (NSInteger)1), RRTransferMaxAttempts);
	transfer.sound = (RRSoundMode)_soundPopup.selectedTag;
	transfer.microphone = (_microphoneCheckbox.state == NSControlStateValueOn);
	transfer.clipboard = (_clipboardCheckbox.state == NSControlStateValueOn);
	transfer.multimon = (_multimonCheckbox.state == NSControlStateValueOn);
	transfer.scalePercent = _scalePopup.selectedTag;
	[[RRConfig shared] saveTransfer:transfer];
}

/* ---- Aktionen ---------------------------------------------------------------------------- */

- (void)controlChanged:(id)sender
{
	if (!_updating)
		[self save];
}

- (void)stepperChanged:(NSStepper *)sender
{
	if (_updating)
		return;
	if (sender == _maxAppsStepper)
		_maxAppsField.integerValue = sender.integerValue;
	else if (sender == _attemptsStepper)
		_attemptsField.integerValue = sender.integerValue;
	[self save];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	if (!_updating)
		[self save];
	[self updateControls];
}

- (void)configDidChange:(NSNotification *)notification
{
	[self updateControls];
}

@end
