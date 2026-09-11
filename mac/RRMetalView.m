/*
 * rdp-retina – View mit CAMetalLayer und Eingabeweitergabe
 */
#import <QuartzCore/QuartzCore.h>

#import "RRMetalView.h"
#import "RRRenderer.h"

#include <os/lock.h>

/* Was die Render-Queue über eine View wissen muss, ohne die View selbst festzuhalten
 * (NSView darf nicht außerhalb des Hauptthreads freigegeben werden). */
@interface RRRenderTarget : NSObject
@property (atomic, strong, nullable) CAMetalLayer *layer;
@property (atomic, strong, nullable) RRTexture *texture;
@property (atomic) NSInteger originX;
@property (atomic) NSInteger originY;
@property (atomic) BOOL alpha;
@property (atomic) BOOL visible;
- (BOOL)markQueued;
- (void)clearQueued;
@end

@implementation RRRenderTarget
{
	os_unfair_lock _lock;
	BOOL _queued;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_lock = OS_UNFAIR_LOCK_INIT;
		_visible = YES;
	}
	return self;
}

- (BOOL)markQueued
{
	os_unfair_lock_lock(&_lock);
	const BOOL wasQueued = _queued;
	_queued = YES;
	os_unfair_lock_unlock(&_lock);
	return !wasQueued;
}

- (void)clearQueued
{
	os_unfair_lock_lock(&_lock);
	_queued = NO;
	os_unfair_lock_unlock(&_lock);
}

@end

@implementation RRMetalView
{
	RRRenderer *_renderer;
	RRRenderTarget *_target;
	NSTrackingArea *_trackingArea;
	BOOL _alpha;
}

- (instancetype)initWithFrame:(NSRect)frame renderer:(RRRenderer *)renderer
{
	self = [super initWithFrame:frame];
	if (self)
	{
		_renderer = renderer;
		_target = [RRRenderTarget new];
		self.wantsLayer = YES;
		self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (CALayer *)makeBackingLayer
{
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = _renderer.device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.framebufferOnly = YES;
	layer.opaque = !_alpha;
	layer.contentsGravity = kCAGravityTopLeft;
	layer.magnificationFilter = kCAFilterNearest;
	layer.minificationFilter = kCAFilterNearest;
	layer.allowsNextDrawableTimeout = YES;
	layer.maximumDrawableCount = 3;

	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	layer.colorspace = space;
	CGColorSpaceRelease(space);

	_target.layer = layer;
	return layer;
}

- (BOOL)isFlipped
{
	return YES;
}

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
	return YES;
}

- (BOOL)mouseDownCanMoveWindow
{
	return NO;
}

- (BOOL)wantsUpdateLayer
{
	return YES;
}

- (void)updateLayer
{
	[self setNeedsRender];
}

/* ---- Quelle ---------------------------------------------------------------------------- */

- (RRTexture *)texture
{
	return _target.texture;
}

- (void)setTexture:(RRTexture *)texture
{
	_target.texture = texture;
}

- (NSInteger)textureOriginX
{
	return _target.originX;
}

- (void)setTextureOriginX:(NSInteger)originX
{
	_target.originX = originX;
}

- (NSInteger)textureOriginY
{
	return _target.originY;
}

- (void)setTextureOriginY:(NSInteger)originY
{
	_target.originY = originY;
}

- (BOOL)alpha
{
	return _alpha;
}

- (void)setAlpha:(BOOL)alpha
{
	if (_alpha == alpha)
		return;
	_alpha = alpha;
	_target.alpha = alpha;
	_target.layer.opaque = !alpha;
	[self setNeedsRender];
}

/* ---- Größe und Sichtbarkeit ------------------------------------------------------------ */

- (void)updateDrawableSize
{
	CAMetalLayer *layer = _target.layer;
	if (!layer)
		return;

	const CGFloat scale =
	    self.window ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
	const NSSize size = self.bounds.size;

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	layer.contentsScale = scale;
	layer.drawableSize =
	    CGSizeMake(MAX(1.0, round(size.width * scale)), MAX(1.0, round(size.height * scale)));
	[CATransaction commit];

	[self setNeedsRender];
}

- (void)setFrameSize:(NSSize)newSize
{
	[super setFrameSize:newSize];
	[self updateDrawableSize];
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];

	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
	if (self.window)
	{
		[center addObserver:self
		           selector:@selector(occlusionChanged:)
		               name:NSWindowDidChangeOcclusionStateNotification
		             object:self.window];
		[self occlusionChanged:nil];
	}
	[self updateDrawableSize];
}

- (void)occlusionChanged:(NSNotification *)notification
{
	/* Verdeckte Fenster nicht zeichnen: nextDrawable würde sonst blockieren. */
	const BOOL visible = (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
	_target.visible = visible;
	if (visible)
		[self setNeedsRender];
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	[self updateDrawableSize];
	if ([self.input respondsToSelector:@selector(metalViewDidChangeBacking:)])
		[self.input metalViewDidChangeBacking:self];
}

- (void)setNeedsRender
{
	RRRenderTarget *target = _target;
	if (![target markQueued])
		return;

	RRRenderer *renderer = _renderer;
	dispatch_async(renderer.queue, ^{
		[target clearQueued];
		CAMetalLayer *layer = target.layer;
		if (!target.visible || !layer)
			return;
		[renderer renderLayer:layer
		              texture:target.texture
		              originX:target.originX
		              originY:target.originY
		                alpha:target.alpha];
	});
}

/* ---- Maus ------------------------------------------------------------------------------ */

- (NSPoint)serverPointForEvent:(NSEvent *)event
{
	const NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
	const CGFloat scale = self.window ? self.window.backingScaleFactor : 1.0;
	return NSMakePoint((CGFloat)self.serverOriginX + floor(local.x * scale),
	                   (CGFloat)self.serverOriginY + floor(local.y * scale));
}

- (void)mouseMoved:(NSEvent *)event
{
	[self.input metalView:self mouseMovedTo:[self serverPointForEvent:event]];
}

- (void)mouseDragged:(NSEvent *)event
{
	[self mouseMoved:event];
}

- (void)rightMouseDragged:(NSEvent *)event
{
	[self mouseMoved:event];
}

- (void)otherMouseDragged:(NSEvent *)event
{
	[self mouseMoved:event];
}

- (void)mouseDown:(NSEvent *)event
{
	[self.input metalView:self button:0 down:YES at:[self serverPointForEvent:event]];
}

- (void)mouseUp:(NSEvent *)event
{
	[self.input metalView:self button:0 down:NO at:[self serverPointForEvent:event]];
}

- (void)rightMouseDown:(NSEvent *)event
{
	[self.input metalView:self button:1 down:YES at:[self serverPointForEvent:event]];
}

- (void)rightMouseUp:(NSEvent *)event
{
	[self.input metalView:self button:1 down:NO at:[self serverPointForEvent:event]];
}

static NSUInteger RRButtonForOtherEvent(NSEvent *event)
{
	switch (event.buttonNumber)
	{
		case 2:
			return 2; /* Mitte */
		case 3:
			return 3; /* X1 (zurück) */
		default:
			return 4; /* X2 (vor) */
	}
}

- (void)otherMouseDown:(NSEvent *)event
{
	[self.input metalView:self
	               button:RRButtonForOtherEvent(event)
	                 down:YES
	                   at:[self serverPointForEvent:event]];
}

- (void)otherMouseUp:(NSEvent *)event
{
	[self.input metalView:self
	               button:RRButtonForOtherEvent(event)
	                 down:NO
	                   at:[self serverPointForEvent:event]];
}

- (void)scrollWheel:(NSEvent *)event
{
	[self.input metalView:self scrollWheel:event];
}

/* ---- Tastatur -------------------------------------------------------------------------- */

- (void)keyDown:(NSEvent *)event
{
	[self.input metalView:self keyEvent:event];
}

- (void)keyUp:(NSEvent *)event
{
	[self.input metalView:self keyEvent:event];
}

- (void)flagsChanged:(NSEvent *)event
{
	[self.input metalView:self keyEvent:event];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
	/* Cmd-Kombinationen gehören der Sitzung, nicht einem Menü. */
	return NO;
}

/* ---- Mauszeiger ------------------------------------------------------------------------ */

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_trackingArea)
		[self removeTrackingArea:_trackingArea];
	_trackingArea = [[NSTrackingArea alloc]
	    initWithRect:NSZeroRect
	         options:(NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect |
	                  NSTrackingCursorUpdate | NSTrackingMouseEnteredAndExited)
	           owner:self
	        userInfo:nil];
	[self addTrackingArea:_trackingArea];
}

- (NSCursor *)currentCursor
{
	NSCursor *cursor = [self.input cursorForMetalView:self];
	return cursor ?: NSCursor.arrowCursor;
}

- (void)cursorUpdate:(NSEvent *)event
{
	[[self currentCursor] set];
}

- (void)mouseEntered:(NSEvent *)event
{
	[[self currentCursor] set];
}

- (void)resetCursorRects
{
	[self addCursorRect:self.bounds cursor:[self currentCursor]];
}

/* ---- Selbsttest ------------------------------------------------------------------------ */

- (void)verifyPixelExact:(void (^)(NSString *report, BOOL exact))completion
{
	CAMetalLayer *layer = _target.layer;
	RRTexture *texture = _target.texture;
	const CGFloat scale = self.window ? self.window.backingScaleFactor : 0;
	const NSSize points = self.bounds.size;
	const CGSize drawable = layer.drawableSize;
	const CGFloat contentsScale = layer.contentsScale;
	const NSInteger originX = _target.originX;
	const NSInteger originY = _target.originY;
	const BOOL alpha = _target.alpha;
	const BOOL geometry = (scale > 0) && (fabs(drawable.width - points.width * scale) < 0.5) &&
	                      (fabs(drawable.height - points.height * scale) < 0.5) &&
	                      (fabs(contentsScale - scale) < 0.001);
	RRRenderer *renderer = _renderer;

	dispatch_async(renderer.queue, ^{
		NSInteger mismatches = -1;
		NSUInteger width = 0;
		NSUInteger height = 0;

		if (texture && (originX >= 0) && (originY >= 0) && ((NSUInteger)originX < texture.width) &&
		    ((NSUInteger)originY < texture.height))
		{
			width = MIN((NSUInteger)drawable.width, texture.width - (NSUInteger)originX);
			height = MIN((NSUInteger)drawable.height, texture.height - (NSUInteger)originY);
			mismatches = [renderer verifyTexture:texture
			                             originX:originX
			                             originY:originY
			                               width:width
			                              height:height
			                               alpha:alpha];
		}

		NSString *report = [NSString
		    stringWithFormat:@"%.0fx%.0f pt × %.2f = Drawable %.0fx%.0f px (contentsScale %.2f), "
		                     @"Quelle %lux%lu ab %ld,%ld: %lu Pixel verglichen, %ld abweichend",
		                     points.width, points.height, scale, drawable.width, drawable.height,
		                     contentsScale, (unsigned long)texture.width,
		                     (unsigned long)texture.height, (long)originX, (long)originY,
		                     (unsigned long)(width * height), (long)mismatches];
		const BOOL exact = geometry && (mismatches == 0);
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(report, exact);
		});
	});
}

@end
