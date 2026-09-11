/*
 * rdp-retina – Metal-Ausgabe ohne Skalierung
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "rr_core.h"

NS_ASSUME_NONNULL_BEGIN

/* Eine Textur im Format BGRA8, Pixel für Pixel wie vom Server geliefert. */
@interface RRTexture : NSObject
@property (nonatomic, readonly) id<MTLTexture> texture;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@end

/*
 * P2: Ein empfangenes Pixel landet auf genau einem physischen Pixel. Der Fragment-Shader
 * liest mit texture.read() das Texel unter jedem Ausgabepixel – kein Sampler, keine
 * Interpolation, keine Mipmaps. Die Drawable hat exakt die Pixelgröße der View.
 *
 * Hochladen und Zeichnen laufen in einer seriellen Queue, damit nie ein halb
 * hochgeladenes Bild auf den Schirm kommt.
 */
@interface RRRenderer : NSObject

- (nullable instancetype)init;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) dispatch_queue_t queue;
/* Anzahl ausgegebener Bilder (für /retina-stats) */
@property (atomic, readonly) uint64_t presentedFrames;

- (nullable RRTexture *)newTextureWithWidth:(NSUInteger)width height:(NSUInteger)height;

/* Nur innerhalb von `queue` aufrufen. */
- (void)upload:(RRTexture *)texture
         bytes:(const uint8_t *)bytes
        stride:(NSUInteger)stride
         rects:(const rrRect *)rects
         count:(NSUInteger)count;

/* Nur innerhalb von `queue` aufrufen. originX/Y: Texel, das links oben erscheint. */
- (void)renderLayer:(CAMetalLayer *)layer
            texture:(nullable RRTexture *)texture
            originX:(NSInteger)originX
            originY:(NSInteger)originY
              alpha:(BOOL)alpha;

/* Selbsttest (P2), nur innerhalb von `queue`: zeichnet wie renderLayer:, aber in eine
 * lesbare Textur, und vergleicht jedes Ausgabepixel mit dem Quelltexel darunter.
 * Rückgabe: Zahl abweichender Pixel, -1 bei Fehler. */
- (NSInteger)verifyTexture:(RRTexture *)texture
                   originX:(NSInteger)originX
                   originY:(NSInteger)originY
                     width:(NSUInteger)width
                    height:(NSUInteger)height
                     alpha:(BOOL)alpha;

@end

NS_ASSUME_NONNULL_END
