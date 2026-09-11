/*
 * rdp-retina – Metal-Ausgabe ohne Skalierung
 */
#import "RRRenderer.h"

/* Vollbild-Dreieck; der Fragment-Shader liest Texel exakt, außerhalb der Textur schwarz
 * (bzw. durchsichtig bei Fenstern mit Alphakanal). */
static NSString *const RRShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "\n"
     "struct RRVertexOut { float4 position [[position]]; };\n"
     "struct RRParams { int originX; int originY; int width; int height; uint alpha; };\n"
     "\n"
     "vertex RRVertexOut rr_vertex(uint vid [[vertex_id]])\n"
     "{\n"
     "    float2 uv = float2(float((vid << 1) & 2u), float(vid & 2u));\n"
     "    RRVertexOut out;\n"
     "    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);\n"
     "    return out;\n"
     "}\n"
     "\n"
     "fragment float4 rr_fragment(RRVertexOut in [[stage_in]],\n"
     "                            texture2d<float, access::read> source [[texture(0)]],\n"
     "                            constant RRParams &p [[buffer(0)]])\n"
     "{\n"
     "    int x = int(in.position.x) + p.originX;\n"
     "    int y = int(in.position.y) + p.originY;\n"
     "    if (x < 0 || y < 0 || x >= p.width || y >= p.height)\n"
     "        return p.alpha != 0 ? float4(0.0) : float4(0.0, 0.0, 0.0, 1.0);\n"
     "    float4 c = source.read(uint2(x, y));\n"
     "    if (p.alpha == 0)\n"
     "        return float4(c.rgb, 1.0);\n"
     "    return float4(c.rgb * c.a, c.a);\n"
     "}\n";

typedef struct
{
	int32_t originX;
	int32_t originY;
	int32_t width;
	int32_t height;
	uint32_t alpha;
} RRParams;

@implementation RRTexture

- (instancetype)initWithTexture:(id<MTLTexture>)texture
{
	self = [super init];
	if (self)
	{
		_texture = texture;
		_width = texture.width;
		_height = texture.height;
	}
	return self;
}

@end

@interface RRRenderer ()
@property (atomic, readwrite) uint64_t presentedFrames;
@end

@implementation RRRenderer
{
	id<MTLCommandQueue> _commandQueue;
	id<MTLRenderPipelineState> _pipeline;
	RRTexture *_empty;
}

- (instancetype)init
{
	self = [super init];
	if (!self)
		return nil;

	_device = MTLCreateSystemDefaultDevice();
	if (!_device)
	{
		fprintf(stderr, "rdp-retina: kein Metal-Gerät gefunden\n");
		return nil;
	}

	_commandQueue = [_device newCommandQueue];

	NSError *error = nil;
	id<MTLLibrary> library = [_device newLibraryWithSource:RRShaderSource options:nil error:&error];
	if (!library)
	{
		fprintf(stderr, "rdp-retina: Shader: %s\n", error.localizedDescription.UTF8String);
		return nil;
	}

	MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
	descriptor.vertexFunction = [library newFunctionWithName:@"rr_vertex"];
	descriptor.fragmentFunction = [library newFunctionWithName:@"rr_fragment"];
	descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	_pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
	if (!_pipeline)
	{
		fprintf(stderr, "rdp-retina: Pipeline: %s\n", error.localizedDescription.UTF8String);
		return nil;
	}

	_queue = dispatch_queue_create("rdp-retina.render", DISPATCH_QUEUE_SERIAL);
	_empty = [self newTextureWithWidth:1 height:1];
	return self;
}

- (RRTexture *)newTextureWithWidth:(NSUInteger)width height:(NSUInteger)height
{
	if ((width == 0) || (height == 0))
		return nil;

	MTLTextureDescriptor *descriptor =
	    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                       width:width
	                                                      height:height
	                                                   mipmapped:NO];
	descriptor.usage = MTLTextureUsageShaderRead;
	/* Diskrete GPU (Intel-Mac): gemanagt, Metal gleicht nur die ersetzten Bereiche ab. */
	descriptor.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;

	id<MTLTexture> texture = [_device newTextureWithDescriptor:descriptor];
	return texture ? [[RRTexture alloc] initWithTexture:texture] : nil;
}

- (void)upload:(RRTexture *)texture
         bytes:(const uint8_t *)bytes
        stride:(NSUInteger)stride
         rects:(const rrRect *)rects
         count:(NSUInteger)count
{
	const NSUInteger textureWidth = texture.width;
	const NSUInteger textureHeight = texture.height;

	for (NSUInteger i = 0; i < count; i++)
	{
		const rrRect *r = &rects[i];
		if ((r->x < 0) || (r->y < 0))
			continue;

		const NSUInteger x = (NSUInteger)r->x;
		const NSUInteger y = (NSUInteger)r->y;
		if ((x >= textureWidth) || (y >= textureHeight))
			continue;

		const NSUInteger width = MIN((NSUInteger)r->width, textureWidth - x);
		const NSUInteger height = MIN((NSUInteger)r->height, textureHeight - y);
		if ((width == 0) || (height == 0))
			continue;

		[texture.texture replaceRegion:MTLRegionMake2D(x, y, width, height)
		                   mipmapLevel:0
		                     withBytes:bytes + y * stride + x * 4
		                   bytesPerRow:stride];
	}
}

- (void)renderLayer:(CAMetalLayer *)layer
            texture:(RRTexture *)texture
            originX:(NSInteger)originX
            originY:(NSInteger)originY
              alpha:(BOOL)alpha
{
	@autoreleasepool
	{
		const CGSize size = layer.drawableSize;
		if ((size.width < 1) || (size.height < 1))
			return;

		id<CAMetalDrawable> drawable = [layer nextDrawable];
		if (!drawable)
			return;

		const RRParams params = {
			.originX = (int32_t)originX,
			.originY = (int32_t)originY,
			.width = texture ? (int32_t)texture.width : 0,
			.height = texture ? (int32_t)texture.height : 0,
			.alpha = alpha ? 1 : 0,
		};

		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = drawable.texture;
		pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;

		id<MTLCommandBuffer> commands = [_commandQueue commandBuffer];
		id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
		[encoder setRenderPipelineState:_pipeline];
		[encoder setFragmentTexture:(texture ?: _empty).texture atIndex:0];
		[encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[encoder endEncoding];
		[commands presentDrawable:drawable];
		[commands commit];
		self.presentedFrames = self.presentedFrames + 1;
	}
}

- (NSInteger)verifyTexture:(RRTexture *)texture
                   originX:(NSInteger)originX
                   originY:(NSInteger)originY
                     width:(NSUInteger)width
                    height:(NSUInteger)height
                     alpha:(BOOL)alpha
{
	if (!texture || (width == 0) || (height == 0) || (originX < 0) || (originY < 0) ||
	    ((NSUInteger)originX + width > texture.width) || ((NSUInteger)originY + height > texture.height))
		return -1;

	@autoreleasepool
	{
		MTLTextureDescriptor *descriptor =
		    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                                                       width:width
		                                                      height:height
		                                                   mipmapped:NO];
		descriptor.usage = MTLTextureUsageRenderTarget;
		descriptor.storageMode =
		    _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
		id<MTLTexture> target = [_device newTextureWithDescriptor:descriptor];
		if (!target)
			return -1;

		const RRParams params = {
			.originX = (int32_t)originX,
			.originY = (int32_t)originY,
			.width = (int32_t)texture.width,
			.height = (int32_t)texture.height,
			.alpha = alpha ? 1 : 0,
		};

		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = target;
		pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;

		id<MTLCommandBuffer> commands = [_commandQueue commandBuffer];
		id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
		[encoder setRenderPipelineState:_pipeline];
		[encoder setFragmentTexture:texture.texture atIndex:0];
		[encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[encoder endEncoding];
		if (target.storageMode == MTLStorageModeManaged)
		{
			id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
			[blit synchronizeResource:target];
			[blit endEncoding];
		}
		[commands commit];
		[commands waitUntilCompleted];

		const NSUInteger stride = 4 * width;
		NSMutableData *expected = [NSMutableData dataWithLength:stride * height];
		NSMutableData *actual = [NSMutableData dataWithLength:stride * height];
		[texture.texture getBytes:expected.mutableBytes
		              bytesPerRow:stride
		               fromRegion:MTLRegionMake2D((NSUInteger)originX, (NSUInteger)originY, width, height)
		              mipmapLevel:0];
		[target getBytes:actual.mutableBytes
		     bytesPerRow:stride
		      fromRegion:MTLRegionMake2D(0, 0, width, height)
		     mipmapLevel:0];

		const uint8_t *e = expected.bytes;
		const uint8_t *a = actual.bytes;
		NSInteger mismatches = 0;
		for (NSUInteger i = 0; i < width * height; i++, e += 4, a += 4)
		{
			if (!alpha)
			{
				if ((e[0] != a[0]) || (e[1] != a[1]) || (e[2] != a[2]) || (a[3] != 255))
					mismatches++;
				continue;
			}
			/* Mit Alpha gibt der Shader vormultipliziert aus; Rundung darf um 1 abweichen. */
			for (int c = 0; c < 3; c++)
			{
				const long want = lround(e[c] * e[3] / 255.0);
				if (labs(want - (long)a[c]) > 1)
				{
					mismatches++;
					break;
				}
			}
		}
		return mismatches;
	}
}

@end
