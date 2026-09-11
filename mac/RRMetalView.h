/*
 * rdp-retina – View mit CAMetalLayer und Eingabeweitergabe
 */
#import <AppKit/AppKit.h>

@class RRMetalView;
@class RRRenderer;
@class RRTexture;

NS_ASSUME_NONNULL_BEGIN

@protocol RRMetalViewInput <NSObject>
/* Koordinaten in Server-Pixeln */
- (void)metalView:(RRMetalView *)view mouseMovedTo:(NSPoint)point;
- (void)metalView:(RRMetalView *)view button:(NSUInteger)button down:(BOOL)down at:(NSPoint)point;
- (void)metalView:(RRMetalView *)view scrollWheel:(NSEvent *)event;
- (void)metalView:(RRMetalView *)view keyEvent:(NSEvent *)event;
- (NSCursor *)cursorForMetalView:(RRMetalView *)view;
@optional
- (void)metalViewDidChangeBacking:(RRMetalView *)view;
@end

/*
 * Die Drawable hat stets Punktgröße × backingScaleFactor, der Layer skaliert nie
 * (contentsGravity oben links, Filter nearest). Stimmt die Größe kurz nicht, wird
 * beschnitten – nicht gestreckt.
 */
@interface RRMetalView : NSView

- (instancetype)initWithFrame:(NSRect)frame renderer:(RRRenderer *)renderer NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<RRMetalViewInput> input;

/* Quelle: Textur und das Texel, das links oben erscheint. Aus jedem Thread setzbar. */
@property (atomic, strong, nullable) RRTexture *texture;
@property (atomic) NSInteger textureOriginX;
@property (atomic) NSInteger textureOriginY;

/* Server-Pixel der linken oberen Ecke, für Mauskoordinaten */
@property (atomic) NSInteger serverOriginX;
@property (atomic) NSInteger serverOriginY;

/* Inhalt trägt Transparenz (RemoteApp-Flächen). Nur im Hauptthread setzen. */
@property (nonatomic) BOOL alpha;

/* Neu zeichnen, aus jedem Thread; mehrere Anforderungen werden zusammengefasst. */
- (void)setNeedsRender;

/* Selbsttest (P2), Hauptthread: prüft Geometrie (Punkte × Faktor = Drawable) und rechnet
 * den sichtbaren Ausschnitt pixelgenau gegen die Quelle nach. completion im Hauptthread. */
- (void)verifyPixelExact:(void (^)(NSString *report, BOOL exact))completion;

@end

NS_ASSUME_NONNULL_END
