//
//  MatrixView.m
//  Matrix
//
//  Created by Jacob Howard on 2/2/26.
//

#import "MatrixView.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <math.h>

/// The vertex data for a full-screen quad.
typedef struct {
    /// The clip-space vertex position.
    vector_float2 position;
    /// The UV coordinate associated with the vertex position.
    vector_float2 uv;
} MatrixVertex;

/// The uniforms for blur passes.
typedef struct {
    /// The source texture texel size in UV space.
    vector_float2 texelSize;
    /// The blur direction for the current blur pass.
    vector_float2 direction;
} MatrixBlurUniforms;

/// The fragment uniforms for MSDF rendering.
typedef struct {
    /// The number of glyph cells in the X and Y directions.
    vector_float2 gridSize;
    /// The aspect-correction scale used by the classic non-volumetric path.
    vector_float2 screenSize;
    /// The glyph height-to-width ratio.
    float glyphHeightToWidth;
    /// The in-cell glyph scale factor.
    float glyphScale;
    /// The MSDF pixel range baked into the glyph atlas.
    float msdfPxRange;
    /// The elapsed animation time in seconds.
    float time;
    /// The glyph atlas grid dimensions.
    vector_float2 atlasGridSize;
} MatrixMSDFUniforms;

/// The defaults key for the "Skip Intro" setting.
static NSString *const kMatrixSkipIntroKey = @"SkipIntro";
/// The number of levels in the bloom pyramid.
enum {
    /// The fixed number of bloom levels from the classic REGL pipeline.
    kMatrixBloomPyramidHeight = 5,
};
/// The pixel format used for offscreen render targets.
static const MTLPixelFormat kMatrixOffscreenPixelFormat =
    MTLPixelFormatRGBA16Float;

@interface MatrixView () {
    /// The ping-pong texture pair for intro timing state.
    id<MTLTexture> _introState[2];
    /// The ping-pong texture pair for raindrop brightness state.
    id<MTLTexture> _raindropState[2];
    /// The ping-pong texture pair for glyph symbol state.
    id<MTLTexture> _symbolState[2];
    /// The ping-pong texture pair for effect state.
    id<MTLTexture> _effectState[2];
    /// The per-level high-pass pyramid textures.
    id<MTLTexture> _highPassPyramid[kMatrixBloomPyramidHeight];
    /// The per-level horizontal blur pyramid textures.
    id<MTLTexture> _hBlurPyramid[kMatrixBloomPyramidHeight];
    /// The per-level vertical blur pyramid textures.
    id<MTLTexture> _vBlurPyramid[kMatrixBloomPyramidHeight];
}
/// The Metal device used for rendering.
@property (nonatomic, strong) id<MTLDevice> metalDevice;
/// The Metal command queue used for rendering.
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
/// The pipeline state used for glyph rendering.
@property (nonatomic, strong) id<MTLRenderPipelineState> glyphPipelineState;
/// The pipeline state used for high-pass filter.
@property (nonatomic, strong) id<MTLRenderPipelineState> highPassPipelineState;
/// The pipeline state used for blur passes.
@property (nonatomic, strong) id<MTLRenderPipelineState> blurPipelineState;
/// The pipeline state used for final compositing.
@property (nonatomic, strong) id<MTLRenderPipelineState> compositePipelineState;
/// The compute pipeline for intro state.
@property (nonatomic, strong) id<MTLComputePipelineState> introPipelineState;
/// The compute pipeline for raindrop state.
@property (nonatomic, strong) id<MTLComputePipelineState> raindropPipelineState;
/// The compute pipeline for symbol state.
@property (nonatomic, strong) id<MTLComputePipelineState> symbolPipelineState;
/// The compute pipeline for effect state.
@property (nonatomic, strong) id<MTLComputePipelineState> effectPipelineState;
/// The Metal layer used to present frames.
@property (nonatomic, strong) CAMetalLayer *metalLayer;
/// The MSDF glyph atlas texture.
@property (nonatomic, strong) id<MTLTexture> glyphTexture;
/// The render target for the glyph pass.
@property (nonatomic, strong) id<MTLTexture> glyphRenderTarget;
/// The high-pass filtered texture for bloom.
@property (nonatomic, strong) id<MTLTexture> highPassTexture;
/// The intermediate blur texture.
@property (nonatomic, strong) id<MTLTexture> blurIntermediate;
/// The final bloom texture.
@property (nonatomic, strong) id<MTLTexture> bloomTexture;
/// The sampler used for MSDF texture sampling.
@property (nonatomic, strong) id<MTLSamplerState> glyphSampler;
/// The sampler used for linear sampling in post passes.
@property (nonatomic, strong) id<MTLSamplerState> linearSampler;
/// The vertex buffer for the quad.
@property (nonatomic, strong) id<MTLBuffer> quadVertexBuffer;
/// The number of vertices in the quad buffer.
@property (nonatomic, assign) NSUInteger quadVertexCount;
/// The current ping index.
@property (nonatomic, assign) NSUInteger pingIndex;
/// The current frame tick.
@property (nonatomic, assign) uint32_t tick;
/// The current grid size (columns, rows).
@property (nonatomic, assign) vector_int2 gridSize;
/// The configuration sheet window.
@property (nonatomic, strong) NSWindow *configurationSheet;
/// The checkbox used to toggle skipping the intro.
@property (nonatomic, strong) NSButton *skipIntroCheckbox;
/// The current skip-intro preference.
@property (nonatomic, assign) BOOL skipIntro;
/// The skip-intro value when the configuration sheet was opened.
@property (nonatomic, assign) BOOL initialSkipIntro;
/// The time the renderer started, for simple animation.
@property (nonatomic, assign) CFTimeInterval startTime;
@end

@implementation MatrixView

/// Initializes the screensaver view and loads defaults.
- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1 / 60.0];
        [self loadDefaults];
    }
    return self;
}

/// Handles attachment to a window and initializes Metal if possible.
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self ensureMetalInfrastructureIfNeeded];
    [self updateMetalDrawableSize];
}

/// Keeps Metal geometry in sync when the view frame changes.
- (void)setFrame:(NSRect)frameRect
{
    [super setFrame:frameRect];
    [self updateMetalDrawableSize];
}

/// Handles view size changes and keeps the Metal layer in sync.
- (void)layout
{
    [super layout];
    [self updateMetalDrawableSize];
}

/// Starts the animation loop.
- (void)startAnimation
{
    [super startAnimation];
    self.startTime = CACurrentMediaTime();
    [self resetSimulationState];
}

/// Stops the animation loop.
- (void)stopAnimation
{
    [super stopAnimation];
}

/// Advances one frame of animation.
- (void)animateOneFrame
{
    [self ensureMetalInfrastructureIfNeeded];
    [self renderMetal];
}

/// Returns whether the screensaver has a configuration sheet.
- (BOOL)hasConfigureSheet
{
    return YES;
}

/// Returns the configuration sheet window, creating it if needed.
- (NSWindow*)configureSheet
{
    if (!self.configurationSheet) {
        [self buildConfigurationSheet];
    }
    self.initialSkipIntro = self.skipIntro;
    [self syncConfigurationSheetState];
    return self.configurationSheet;
}

/// Loads defaults into local state and registers defaults if needed.
- (void)loadDefaults
{
    ScreenSaverDefaults *defaults =
        [ScreenSaverDefaults defaultsForModuleWithName:@"Matrix"];
    [defaults registerDefaults:@{ kMatrixSkipIntroKey: @YES }];
    self.skipIntro = [defaults boolForKey:kMatrixSkipIntroKey];
}

/// Builds the configuration sheet UI.
- (void)buildConfigurationSheet
{
    NSRect windowFrame = NSMakeRect(0.0, 0.0, 360.0, 140.0);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:windowFrame
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:@"Matrix Settings"];

    NSView *contentView = window.contentView;
    if (!contentView) {
        return;
    }

    NSButton *checkbox =
        [[NSButton alloc] initWithFrame:NSMakeRect(20.0, 60.0, 320.0, 24.0)];
    [checkbox setButtonType:NSButtonTypeSwitch];
    [checkbox setTitle:@"Skip Intro"];
    [checkbox setTarget:self];
    [checkbox setAction:@selector(skipIntroCheckboxChanged:)];
    [contentView addSubview:checkbox];

    NSButton *doneButton =
        [[NSButton alloc] initWithFrame:NSMakeRect(250.0, 20.0, 90.0, 28.0)];
    [doneButton setBezelStyle:NSBezelStyleRounded];
    [doneButton setTitle:@"Done"];
    [doneButton setTarget:self];
    [doneButton setAction:@selector(closeConfigurationSheet:)];
    [doneButton setKeyEquivalent:@"\r"];
    [contentView addSubview:doneButton];

    NSButton *cancelButton =
        [[NSButton alloc] initWithFrame:NSMakeRect(150.0, 20.0, 90.0, 28.0)];
    [cancelButton setBezelStyle:NSBezelStyleRounded];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(cancelConfigurationSheet:)];
    [contentView addSubview:cancelButton];

    self.skipIntroCheckbox = checkbox;
    self.configurationSheet = window;
}

/// Updates the configuration sheet controls to match current settings.
- (void)syncConfigurationSheetState
{
    if (!self.skipIntroCheckbox) {
        return;
    }
    self.skipIntroCheckbox.state =
        self.skipIntro ? NSControlStateValueOn : NSControlStateValueOff;
}

/// Handles changes to the skip-intro checkbox.
- (void)skipIntroCheckboxChanged:(id)sender
{
    NSButton *checkbox = (NSButton *)sender;
    BOOL skipIntro = checkbox.state == NSControlStateValueOn;
    self.skipIntro = skipIntro;
}

/// Closes the configuration sheet.
- (void)closeConfigurationSheet:(id)sender
{
    (void)sender;
    if (!self.configurationSheet) {
        return;
    }
    ScreenSaverDefaults *defaults =
        [ScreenSaverDefaults defaultsForModuleWithName:@"Matrix"];
    [defaults setBool:self.skipIntro forKey:kMatrixSkipIntroKey];
    [defaults synchronize];
    [NSApp endSheet:self.configurationSheet];
    [self.configurationSheet orderOut:self];
}

/// Cancels changes and closes the configuration sheet.
- (void)cancelConfigurationSheet:(id)sender
{
    (void)sender;
    if (!self.configurationSheet) {
        return;
    }
    self.skipIntro = self.initialSkipIntro;
    [self syncConfigurationSheetState];
    ScreenSaverDefaults *defaults =
        [ScreenSaverDefaults defaultsForModuleWithName:@"Matrix"];
    [defaults setBool:self.initialSkipIntro forKey:kMatrixSkipIntroKey];
    [defaults synchronize];
    [NSApp endSheet:self.configurationSheet];
    [self.configurationSheet orderOut:self];
}

/// Ensures the Metal device, layer, and pipeline are ready if possible.
- (void)ensureMetalInfrastructureIfNeeded
{
    if (self.metalLayer || !self.window) {
        return;
    }

    // Wait until we have a valid frame size before setting up Metal.
    if (self.bounds.size.width < 1.0 || self.bounds.size.height < 1.0) {
        return;
    }

    id<MTLDevice> device = self.metalDevice;
    if (!device) {
        device = MTLCreateSystemDefaultDevice();
        if (!device) {
            return;
        }
        self.metalDevice = device;
    }

    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    layer.needsDisplayOnBoundsChange = YES;
    if ([layer respondsToSelector:@selector(setPresentsWithTransaction:)]) {
        layer.presentsWithTransaction = NO;
    }
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 101300
    if (@available(macOS 10.13, *)) {
        layer.displaySyncEnabled = YES;
    }
#endif

    self.wantsLayer = YES;
    self.layer = layer;
    if ([self respondsToSelector:@selector(setLayerContentsRedrawPolicy:)]) {
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    }

    self.metalLayer = layer;
    self.commandQueue = [device newCommandQueue];

    // Build static rendering resources after we have a valid Metal device.
    [self setupGlyphResources];
    [self setupComputeState];
    [self buildMetalPipeline];
}

/// Updates the drawable size to match the current bounds and scale.
- (void)updateMetalDrawableSize
{
    if (!self.metalLayer) {
        return;
    }
    CGFloat scale = [self currentBackingScaleFactor];
    if (scale <= 0.0) {
        scale = 1.0;
    }
    self.metalLayer.contentsScale = scale;
    self.metalLayer.frame = self.bounds;
    self.metalLayer.drawableSize = CGSizeMake(
        MAX(self.bounds.size.width * scale, 1.0),
        MAX(self.bounds.size.height * scale, 1.0)
    );
    [self updateRenderTargets];
}

/// Returns the best available backing scale factor for the view.
- (CGFloat)currentBackingScaleFactor
{
    if (self.window) {
        return self.window.backingScaleFactor;
    }
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    return screen ? screen.backingScaleFactor : 1.0;
}

/// Ensures offscreen render targets match the drawable size.
- (void)updateRenderTargets
{
    if (!self.metalDevice || !self.metalLayer) {
        return;
    }

    CGSize drawableSize = self.metalLayer.drawableSize;
    if (drawableSize.width < 1.0 || drawableSize.height < 1.0) {
        return;
    }

    NSUInteger width = (NSUInteger)drawableSize.width;
    NSUInteger height = (NSUInteger)drawableSize.height;
    // Use bloomSize of 0.4 to match the original REGL implementation.
    NSUInteger bloomWidth = MAX(1, (NSUInteger)(width * 0.4f));
    NSUInteger bloomHeight = MAX(1, (NSUInteger)(height * 0.4f));

    if (self.glyphRenderTarget &&
        self.glyphRenderTarget.width == width &&
        self.glyphRenderTarget.height == height) {
        return;
    }

    MTLTextureDescriptor *glyphDesc =
        [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:kMatrixOffscreenPixelFormat
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    glyphDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    self.glyphRenderTarget = [self.metalDevice newTextureWithDescriptor:glyphDesc];

    // Allocate the bloom pyramid at progressively smaller resolutions.
    for (NSUInteger level = 0; level < kMatrixBloomPyramidHeight; level++) {
        NSUInteger levelWidth = MAX(1, bloomWidth >> level);
        NSUInteger levelHeight = MAX(1, bloomHeight >> level);

        MTLTextureDescriptor *levelDesc =
            [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:kMatrixOffscreenPixelFormat
                                             width:levelWidth
                                            height:levelHeight
                                         mipmapped:NO];
        levelDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

        _highPassPyramid[level] =
            [self.metalDevice newTextureWithDescriptor:levelDesc];
        _hBlurPyramid[level] =
            [self.metalDevice newTextureWithDescriptor:levelDesc];
        _vBlurPyramid[level] =
            [self.metalDevice newTextureWithDescriptor:levelDesc];
    }

    // Keep these compatibility aliases for legacy single-level checks.
    self.highPassTexture = _highPassPyramid[0];
    self.blurIntermediate = _hBlurPyramid[0];
    self.bloomTexture = _vBlurPyramid[0];
}

/// Draws a single Metal frame.
- (void)renderMetal
{
    // Validate core renderer state before acquiring a drawable.
    if (!self.metalLayer || !self.commandQueue) {
        return;
    }

    // Don't try to render if the view doesn't have a valid size yet.
    if (self.bounds.size.width < 1.0 || self.bounds.size.height < 1.0) {
        return;
    }

    // Don't try to render if drawable size is invalid.
    if (self.metalLayer.drawableSize.width < 1.0 ||
        self.metalLayer.drawableSize.height < 1.0) {
        return;
    }

    if (!self.glyphRenderTarget) {
        return;
    }

    // Validate the full bloom chain before encoding any work.
    for (NSUInteger level = 0; level < kMatrixBloomPyramidHeight; level++) {
        if (!_highPassPyramid[level] || !_hBlurPyramid[level] ||
            !_vBlurPyramid[level]) {
            return;
        }
    }

    if (!self.highPassTexture || !self.blurIntermediate || !self.bloomTexture) {
        return;
    }

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) {
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    // Run the state update kernels before any render passes.
    [self encodeComputePasses:commandBuffer];

    // Pass 1: render glyphs into offscreen target.
    MTLRenderPassDescriptor *glyphPass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    glyphPass.colorAttachments[0].texture = self.glyphRenderTarget;
    glyphPass.colorAttachments[0].loadAction = MTLLoadActionClear;
    glyphPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    glyphPass.colorAttachments[0].clearColor =
        MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLRenderCommandEncoder> glyphEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:glyphPass];
    if (self.glyphPipelineState) {
        // Bind the base glyph rendering pipeline and full-screen geometry.
        [glyphEncoder setRenderPipelineState:self.glyphPipelineState];
        [glyphEncoder setVertexBuffer:self.quadVertexBuffer offset:0 atIndex:0];
        [glyphEncoder setFragmentTexture:self.glyphTexture atIndex:0];
        [glyphEncoder setFragmentSamplerState:self.glyphSampler atIndex:0];

        // Sample simulation textures from the currently published ping index.
        [glyphEncoder setFragmentTexture:_raindropState[self.pingIndex] atIndex:1];
        [glyphEncoder setFragmentTexture:_symbolState[self.pingIndex] atIndex:2];
        [glyphEncoder setFragmentTexture:_effectState[self.pingIndex] atIndex:3];

        float renderWidth = (float)self.glyphRenderTarget.width;
        float renderHeight = (float)self.glyphRenderTarget.height;
        float aspectRatio = renderHeight > 0.0f ? renderWidth / renderHeight : 1.0f;
        // Match rainPass.vert.glsl non-volumetric screen-size scaling.
        vector_float2 screenSize = aspectRatio > 1.0f
            ? (vector_float2){ 1.0f, aspectRatio }
            : (vector_float2){ 1.0f / aspectRatio, 1.0f };
        MatrixMSDFUniforms uniforms = {
            .gridSize = { (float)self.gridSize.x, (float)self.gridSize.y },
            .screenSize = screenSize,
            .glyphHeightToWidth = 1.0f,
            .glyphScale = 1.0f,
            .msdfPxRange = 4.0f,
            .time = (float)(CACurrentMediaTime() - self.startTime),
            .atlasGridSize = { 8.0f, 8.0f },
        };
        [glyphEncoder setFragmentBytes:&uniforms
                                length:sizeof(uniforms)
                               atIndex:0];
        [glyphEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                         vertexStart:0
                         vertexCount:self.quadVertexCount];
    }
    [glyphEncoder endEncoding];

    // Passes 2-4: run high-pass and two-pass blur over each bloom level.
    for (NSUInteger level = 0; level < kMatrixBloomPyramidHeight; level++) {
        // Feed each level from the previous high-pass level.
        id<MTLTexture> highPassSource = level == 0
            ? self.glyphRenderTarget
            : _highPassPyramid[level - 1];
        id<MTLTexture> highPassTarget = _highPassPyramid[level];
        id<MTLTexture> hBlurTarget = _hBlurPyramid[level];
        id<MTLTexture> vBlurTarget = _vBlurPyramid[level];

        MTLRenderPassDescriptor *highPassDesc =
            [MTLRenderPassDescriptor renderPassDescriptor];
        highPassDesc.colorAttachments[0].texture = highPassTarget;
        highPassDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        highPassDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        highPassDesc.colorAttachments[0].clearColor =
            MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        id<MTLRenderCommandEncoder> highPassEncoder =
            [commandBuffer renderCommandEncoderWithDescriptor:highPassDesc];
        if (self.highPassPipelineState) {
            // Isolate bright glyph energy for this bloom level.
            [highPassEncoder setRenderPipelineState:self.highPassPipelineState];
            [highPassEncoder setVertexBuffer:self.quadVertexBuffer
                                      offset:0
                                     atIndex:0];
            [highPassEncoder setFragmentTexture:highPassSource atIndex:0];
            [highPassEncoder setFragmentSamplerState:self.linearSampler atIndex:0];
            [highPassEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                vertexStart:0
                                vertexCount:self.quadVertexCount];
        }
        [highPassEncoder endEncoding];

        MTLRenderPassDescriptor *blurPassH =
            [MTLRenderPassDescriptor renderPassDescriptor];
        blurPassH.colorAttachments[0].texture = hBlurTarget;
        blurPassH.colorAttachments[0].loadAction = MTLLoadActionClear;
        blurPassH.colorAttachments[0].storeAction = MTLStoreActionStore;
        blurPassH.colorAttachments[0].clearColor =
            MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        id<MTLRenderCommandEncoder> blurEncoderH =
            [commandBuffer renderCommandEncoderWithDescriptor:blurPassH];
        if (self.blurPipelineState) {
            // Blur horizontally into the intermediate pyramid target.
            [blurEncoderH setRenderPipelineState:self.blurPipelineState];
            [blurEncoderH setVertexBuffer:self.quadVertexBuffer
                                   offset:0
                                  atIndex:0];
            [blurEncoderH setFragmentTexture:highPassTarget atIndex:0];
            [blurEncoderH setFragmentSamplerState:self.linearSampler atIndex:0];

            MatrixBlurUniforms blurUniforms = {
                .texelSize = {
                    1.0f / (float)highPassTarget.width,
                    1.0f / (float)highPassTarget.height,
                },
                .direction = { 1.0f, 0.0f },
            };
            [blurEncoderH setFragmentBytes:&blurUniforms
                                     length:sizeof(blurUniforms)
                                    atIndex:0];
            [blurEncoderH drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:0
                             vertexCount:self.quadVertexCount];
        }
        [blurEncoderH endEncoding];

        MTLRenderPassDescriptor *blurPassV =
            [MTLRenderPassDescriptor renderPassDescriptor];
        blurPassV.colorAttachments[0].texture = vBlurTarget;
        blurPassV.colorAttachments[0].loadAction = MTLLoadActionClear;
        blurPassV.colorAttachments[0].storeAction = MTLStoreActionStore;
        blurPassV.colorAttachments[0].clearColor =
            MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        id<MTLRenderCommandEncoder> blurEncoderV =
            [commandBuffer renderCommandEncoderWithDescriptor:blurPassV];
        if (self.blurPipelineState) {
            // Blur vertically to complete the separable blur for this level.
            [blurEncoderV setRenderPipelineState:self.blurPipelineState];
            [blurEncoderV setVertexBuffer:self.quadVertexBuffer
                                   offset:0
                                  atIndex:0];
            [blurEncoderV setFragmentTexture:hBlurTarget atIndex:0];
            [blurEncoderV setFragmentSamplerState:self.linearSampler atIndex:0];

            MatrixBlurUniforms blurUniforms = {
                .texelSize = {
                    1.0f / (float)hBlurTarget.width,
                    1.0f / (float)hBlurTarget.height,
                },
                .direction = { 0.0f, 1.0f },
            };
            [blurEncoderV setFragmentBytes:&blurUniforms
                                     length:sizeof(blurUniforms)
                                    atIndex:0];
            [blurEncoderV drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:0
                             vertexCount:self.quadVertexCount];
        }
        [blurEncoderV endEncoding];
    }

    // Pass 5: composite.
    MTLRenderPassDescriptor *compositePass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    compositePass.colorAttachments[0].texture = drawable.texture;
    compositePass.colorAttachments[0].loadAction = MTLLoadActionClear;
    compositePass.colorAttachments[0].storeAction = MTLStoreActionStore;
    compositePass.colorAttachments[0].clearColor =
        MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLRenderCommandEncoder> compositeEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:compositePass];
    if (self.compositePipelineState) {
        float timeSeconds = (float)(CACurrentMediaTime() - self.startTime);
        // Composite the base glyph pass with all bloom levels.
        [compositeEncoder setRenderPipelineState:self.compositePipelineState];
        [compositeEncoder setVertexBuffer:self.quadVertexBuffer offset:0 atIndex:0];
        [compositeEncoder setFragmentBytes:&timeSeconds
                                    length:sizeof(timeSeconds)
                                   atIndex:0];
        [compositeEncoder setFragmentTexture:self.glyphRenderTarget atIndex:0];
        for (NSUInteger level = 0; level < kMatrixBloomPyramidHeight; level++) {
            [compositeEncoder setFragmentTexture:_vBlurPyramid[level]
                                         atIndex:(NSUInteger)(level + 1)];
        }
        [compositeEncoder setFragmentSamplerState:self.linearSampler atIndex:0];
        [compositeEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                             vertexStart:0
                             vertexCount:self.quadVertexCount];
    }
    [compositeEncoder endEncoding];

    // Present and commit after all compute and render encoders are closed.
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

/// Loads the MSDF glyph atlas and creates render resources.
- (void)setupGlyphResources
{
    if (!self.metalDevice) {
        return;
    }

    self.glyphTexture = [self loadGlyphTexture];
    if (!self.glyphTexture) {
        return;
    }

    MTLSamplerDescriptor *samplerDescriptor = [[MTLSamplerDescriptor alloc] init];
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    self.glyphSampler = [self.metalDevice newSamplerStateWithDescriptor:samplerDescriptor];

    MTLSamplerDescriptor *linearDescriptor = [[MTLSamplerDescriptor alloc] init];
    linearDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    linearDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    linearDescriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    linearDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    linearDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    self.linearSampler = [self.metalDevice newSamplerStateWithDescriptor:linearDescriptor];

    // Build a full-screen quad for triangle-strip render passes.
    MatrixVertex quadVertices[] = {
        { { -1.0f, -1.0f }, { 0.0f, 0.0f } },
        { {  1.0f, -1.0f }, { 1.0f, 0.0f } },
        { { -1.0f,  1.0f }, { 0.0f, 1.0f } },
        { {  1.0f,  1.0f }, { 1.0f, 1.0f } },
    };
    self.quadVertexCount = sizeof(quadVertices) / sizeof(quadVertices[0]);
    self.quadVertexBuffer = [self.metalDevice newBufferWithBytes:quadVertices
                                                          length:sizeof(quadVertices)
                                                         options:MTLResourceStorageModeShared];
}

/// Initializes the compute state textures.
- (void)setupComputeState
{
    if (!self.metalDevice) {
        return;
    }

    // The classic preset uses an 80x80 logical glyph grid.
    self.gridSize = (vector_int2){ 80, 80 };
    NSUInteger width = (NSUInteger)self.gridSize.x;
    NSUInteger height = (NSUInteger)self.gridSize.y;

    MTLTextureDescriptor *introDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:width
                                                          height:1
                                                       mipmapped:NO];
    // Intro progression is tracked per column only.
    introDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

    MTLTextureDescriptor *stateDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    // Rain, symbol, and effect states are full-grid ping-pong textures.
    stateDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

    // Allocate both ping and pong textures for every simulation state.
    for (int i = 0; i < 2; i++) {
        _introState[i] = [self.metalDevice newTextureWithDescriptor:introDesc];
        _raindropState[i] = [self.metalDevice newTextureWithDescriptor:stateDesc];
        _symbolState[i] = [self.metalDevice newTextureWithDescriptor:stateDesc];
        _effectState[i] = [self.metalDevice newTextureWithDescriptor:stateDesc];
    }

    [self resetSimulationState];
}

/// Clears a texture to zero.
- (void)clearTexture:(id<MTLTexture>)texture
{
    if (!texture) {
        return;
    }
    NSUInteger width = texture.width;
    NSUInteger height = texture.height;
    if (width == 0 || height == 0) {
        return;
    }
    NSUInteger bytesPerPixel = 8; // RGBA16F
    NSUInteger bytesPerRow = width * bytesPerPixel;
    NSUInteger dataSize = bytesPerRow * height;
    void *data = calloc(1, dataSize);
    if (!data) {
        return;
    }
    MTLRegion region = {
        { 0, 0, 0 },
        { width, height, 1 }
    };
    [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:bytesPerRow];
    free(data);
}

/// Resets simulation textures and frame state to their initial values.
- (void)resetSimulationState
{
    for (int i = 0; i < 2; i++) {
        [self clearTexture:_introState[i]];
        [self clearTexture:_raindropState[i]];
        [self clearTexture:_symbolState[i]];
        [self clearTexture:_effectState[i]];
    }
    self.pingIndex = 0;
    self.tick = 0;
}

/// Encodes the compute passes for state updates.
- (void)encodeComputePasses:(id<MTLCommandBuffer>)commandBuffer
{
    if (!self.introPipelineState || !self.raindropPipelineState ||
        !self.symbolPipelineState || !self.effectPipelineState) {
        return;
    }

    // Share one frame time across all simulation kernels.
    float timeSeconds = (float)(CACurrentMediaTime() - self.startTime);
    uint32_t frame = self.tick++;

    // Rotate ping-pong indices once per frame.
    NSUInteger nextIndex = (self.pingIndex + 1) % 2;

    // Pass 1: update intro progression state.
    id<MTLComputeCommandEncoder> introEncoder = [commandBuffer computeCommandEncoder];
    [introEncoder setComputePipelineState:self.introPipelineState];
    // Match uniform ordering used by introKernel in MatrixView.metal.
    [introEncoder setBytes:&timeSeconds length:sizeof(timeSeconds) atIndex:0];
    [introEncoder setBytes:&frame length:sizeof(frame) atIndex:1];
    uint32_t skipIntroValue = self.skipIntro ? 1 : 0;
    vector_int2 gridSize = self.gridSize;
    [introEncoder setBytes:&skipIntroValue length:sizeof(skipIntroValue) atIndex:2];
    [introEncoder setBytes:&gridSize length:sizeof(gridSize) atIndex:3];
    [introEncoder setTexture:_introState[self.pingIndex] atIndex:0];
    [introEncoder setTexture:_introState[nextIndex] atIndex:1];

    MTLSize introThreads = MTLSizeMake((NSUInteger)self.gridSize.x, 1, 1);
    MTLSize introThreadgroup = MTLSizeMake(16, 1, 1);
    [introEncoder dispatchThreads:introThreads
          threadsPerThreadgroup:introThreadgroup];
    [introEncoder endEncoding];

    // Pass 2: update raindrop brightness and cursor state.
    id<MTLComputeCommandEncoder> raindropEncoder = [commandBuffer computeCommandEncoder];
    [raindropEncoder setComputePipelineState:self.raindropPipelineState];
    // Match uniform ordering used by raindropKernel in MatrixView.metal.
    [raindropEncoder setBytes:&timeSeconds length:sizeof(timeSeconds) atIndex:0];
    [raindropEncoder setBytes:&frame length:sizeof(frame) atIndex:1];
    [raindropEncoder setBytes:&skipIntroValue length:sizeof(skipIntroValue) atIndex:2];
    [raindropEncoder setBytes:&gridSize length:sizeof(gridSize) atIndex:3];
    [raindropEncoder setTexture:_introState[nextIndex] atIndex:0];
    [raindropEncoder setTexture:_raindropState[self.pingIndex] atIndex:1];
    [raindropEncoder setTexture:_raindropState[nextIndex] atIndex:2];

    MTLSize stateThreads = MTLSizeMake((NSUInteger)self.gridSize.x,
                                       (NSUInteger)self.gridSize.y,
                                       1);
    MTLSize stateThreadgroup = MTLSizeMake(8, 8, 1);
    [raindropEncoder dispatchThreads:stateThreads
             threadsPerThreadgroup:stateThreadgroup];
    [raindropEncoder endEncoding];

    // Pass 3: update glyph symbol cycling state.
    id<MTLComputeCommandEncoder> symbolEncoder = [commandBuffer computeCommandEncoder];
    [symbolEncoder setComputePipelineState:self.symbolPipelineState];
    // Match uniform ordering used by symbolKernel in MatrixView.metal.
    [symbolEncoder setBytes:&timeSeconds length:sizeof(timeSeconds) atIndex:0];
    [symbolEncoder setBytes:&frame length:sizeof(frame) atIndex:1];
    [symbolEncoder setBytes:&gridSize length:sizeof(gridSize) atIndex:2];
    [symbolEncoder setTexture:_raindropState[nextIndex] atIndex:0];
    [symbolEncoder setTexture:_symbolState[self.pingIndex] atIndex:1];
    [symbolEncoder setTexture:_symbolState[nextIndex] atIndex:2];
    [symbolEncoder dispatchThreads:stateThreads
            threadsPerThreadgroup:stateThreadgroup];
    [symbolEncoder endEncoding];

    // Pass 4: update effect state.
    id<MTLComputeCommandEncoder> effectEncoder = [commandBuffer computeCommandEncoder];
    [effectEncoder setComputePipelineState:self.effectPipelineState];
    // Match uniform ordering used by effectKernel in MatrixView.metal.
    [effectEncoder setBytes:&timeSeconds length:sizeof(timeSeconds) atIndex:0];
    [effectEncoder setBytes:&frame length:sizeof(frame) atIndex:1];
    [effectEncoder setBytes:&gridSize length:sizeof(gridSize) atIndex:2];
    [effectEncoder setTexture:_raindropState[nextIndex] atIndex:0];
    [effectEncoder setTexture:_effectState[self.pingIndex] atIndex:1];
    [effectEncoder setTexture:_effectState[nextIndex] atIndex:2];
    [effectEncoder dispatchThreads:stateThreads
            threadsPerThreadgroup:stateThreadgroup];
    [effectEncoder endEncoding];

    // Publish the next state pair for render sampling.
    self.pingIndex = nextIndex;
}

/// Loads the Matrix MSDF glyph atlas from the bundle.
- (id<MTLTexture>)loadGlyphTexture
{
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *textureURL = [bundle URLForResource:@"matrixcode_msdf" withExtension:@"png"];
    if (!textureURL) {
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfURL:textureURL];
    if (!image) {
        return nil;
    }

    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:NULL hints:nil];
    if (!cgImage) {
        return nil;
    }

    return [self createTextureFromCGImage:cgImage];
}

/// Creates a Metal texture from a CGImage.
- (id<MTLTexture>)createTextureFromCGImage:(CGImageRef)cgImage
{
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) {
        return nil;
    }

    size_t bytesPerPixel = 4;
    size_t bytesPerRow = bytesPerPixel * width;
    size_t dataSize = bytesPerRow * height;
    void *data = calloc(1, dataSize);
    if (!data) {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data,
                                                 width,
                                                 height,
                                                 8,
                                                 bytesPerRow,
                                                 colorSpace,
                                                 kCGImageAlphaNoneSkipLast |
                                                     kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(data);
        return nil;
    }

    // Match WebGL's texture upload path that uses flipY for image assets.
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    id<MTLTexture> texture = [self.metalDevice newTextureWithDescriptor:descriptor];
    if (texture) {
        MTLRegion region = {
            { 0, 0, 0 },
            { (NSUInteger)width, (NSUInteger)height, 1 }
        };
        [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:bytesPerRow];
    }

    free(data);
    return texture;
}

/// Builds the Metal pipeline used for classic mode rendering.
- (void)buildMetalPipeline
{
    if (!self.metalDevice || !self.metalLayer) {
        return;
    }

    // Source mapping for classic mode:
    // - introKernel mirrors shaders/glsl/rainPass.intro.frag.glsl.
    // - raindropKernel mirrors shaders/glsl/rainPass.raindrop.frag.glsl.
    // - symbolKernel mirrors shaders/glsl/rainPass.symbol.frag.glsl.
    // - effectKernel mirrors shaders/glsl/rainPass.effect.frag.glsl.
    // - fs_main mirrors shaders/glsl/rainPass.frag.glsl in non-volumetric mode.
    // - fs_highpass mirrors shaders/glsl/bloomPass.highPass.frag.glsl.
    // - fs_blur mirrors shaders/glsl/bloomPass.blur.frag.glsl.
    // - fs_composite merges bloomPass.combine.frag.glsl and
    //   palettePass.frag.glsl into one pass for the screensaver.
    //
    // Known fidelity tradeoff:
    // - The blur step is intentionally scaled to 0.65 of the strict WebGL
    //   footprint to reduce glyph softness at higher bloom gain on macOS.
    //   This keeps a crisper appearance at the expense of exact parity.
    // - The palette pass is merged into fs_composite for fewer passes.
    //
    // Shader functions are loaded from MatrixView.metal via the default
    // precompiled Metal library.
    NSError *error = nil;
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    id<MTLLibrary> library = nil;
    if ([self.metalDevice
             respondsToSelector:@selector(newDefaultLibraryWithBundle:error:)]) {
        library = [self.metalDevice newDefaultLibraryWithBundle:bundle
                                                         error:&error];
    } else {
        library = [self.metalDevice newDefaultLibrary];
    }
    if (!library) {
        NSLog(@"MatrixView: Failed to load default Metal library: %@",
              error);
        return;
    }

    // Resolve compute kernels by name from the precompiled library.
    id<MTLFunction> introFn = [library newFunctionWithName:@"introKernel"];
    id<MTLFunction> raindropFn = [library newFunctionWithName:@"raindropKernel"];
    id<MTLFunction> symbolFn = [library newFunctionWithName:@"symbolKernel"];
    id<MTLFunction> effectFn = [library newFunctionWithName:@"effectKernel"];
    if (!introFn || !raindropFn || !symbolFn || !effectFn) {
        NSLog(@"MatrixView: Missing compute functions.");
        return;
    }
    self.introPipelineState =
        [self.metalDevice newComputePipelineStateWithFunction:introFn
                                                        error:&error];
    self.raindropPipelineState =
        [self.metalDevice newComputePipelineStateWithFunction:raindropFn
                                                        error:&error];
    self.symbolPipelineState =
        [self.metalDevice newComputePipelineStateWithFunction:symbolFn
                                                        error:&error];
    self.effectPipelineState =
        [self.metalDevice newComputePipelineStateWithFunction:effectFn
                                                        error:&error];
    if (!self.introPipelineState || !self.raindropPipelineState ||
        !self.symbolPipelineState || !self.effectPipelineState) {
        NSLog(@"MatrixView: Compute pipeline creation failed: %@", error);
        return;
    }

    // Resolve render-stage shaders by name from the precompiled library.
    id<MTLFunction> fullscreenVertexFunction = [library newFunctionWithName:@"vs_fullscreen"];
    id<MTLFunction> glyphFragmentFunction = [library newFunctionWithName:@"fs_main"];
    id<MTLFunction> highPassFragmentFunction = [library newFunctionWithName:@"fs_highpass"];
    id<MTLFunction> blurFragmentFunction = [library newFunctionWithName:@"fs_blur"];
    id<MTLFunction> compositeFragmentFunction = [library newFunctionWithName:@"fs_composite"];
    if (!fullscreenVertexFunction || !glyphFragmentFunction ||
        !highPassFragmentFunction || !blurFragmentFunction ||
        !compositeFragmentFunction) {
        return;
    }

    MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;
    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[1].offset = sizeof(vector_float2);
    vertexDescriptor.attributes[1].bufferIndex = 0;
    vertexDescriptor.layouts[0].stride = sizeof(MatrixVertex);
    MTLPixelFormat offscreenFormat = kMatrixOffscreenPixelFormat;

    MTLRenderPipelineDescriptor *glyphDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    glyphDescriptor.vertexFunction = fullscreenVertexFunction;
    glyphDescriptor.fragmentFunction = glyphFragmentFunction;
    glyphDescriptor.colorAttachments[0].pixelFormat = offscreenFormat;
    // Use additive blending like the original REGL implementation.
    glyphDescriptor.colorAttachments[0].blendingEnabled = YES;
    glyphDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    glyphDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    glyphDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    glyphDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    glyphDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    glyphDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    glyphDescriptor.vertexDescriptor = vertexDescriptor;
    self.glyphPipelineState =
        [self.metalDevice newRenderPipelineStateWithDescriptor:glyphDescriptor
                                                         error:&error];
    if (!self.glyphPipelineState) {
        NSLog(@"MatrixView: glyph pipeline failed: %@", error);
        return;
    }

    MTLRenderPipelineDescriptor *highPassDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    highPassDescriptor.vertexFunction = fullscreenVertexFunction;
    highPassDescriptor.fragmentFunction = highPassFragmentFunction;
    highPassDescriptor.colorAttachments[0].pixelFormat = offscreenFormat;
    highPassDescriptor.vertexDescriptor = vertexDescriptor;
    self.highPassPipelineState =
        [self.metalDevice newRenderPipelineStateWithDescriptor:highPassDescriptor
                                                         error:&error];
    if (!self.highPassPipelineState) {
        NSLog(@"MatrixView: high-pass pipeline failed: %@", error);
        return;
    }

    MTLRenderPipelineDescriptor *blurDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    blurDescriptor.vertexFunction = fullscreenVertexFunction;
    blurDescriptor.fragmentFunction = blurFragmentFunction;
    blurDescriptor.colorAttachments[0].pixelFormat = offscreenFormat;
    blurDescriptor.vertexDescriptor = vertexDescriptor;
    self.blurPipelineState =
        [self.metalDevice newRenderPipelineStateWithDescriptor:blurDescriptor
                                                         error:&error];
    if (!self.blurPipelineState) {
        NSLog(@"MatrixView: blur pipeline failed: %@", error);
        return;
    }

    MTLRenderPipelineDescriptor *compositeDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    compositeDescriptor.vertexFunction = fullscreenVertexFunction;
    compositeDescriptor.fragmentFunction = compositeFragmentFunction;
    compositeDescriptor.colorAttachments[0].pixelFormat = self.metalLayer.pixelFormat;
    compositeDescriptor.vertexDescriptor = vertexDescriptor;
    self.compositePipelineState =
        [self.metalDevice newRenderPipelineStateWithDescriptor:compositeDescriptor
                                                         error:&error];
    if (!self.compositePipelineState) {
        NSLog(@"MatrixView: composite pipeline failed: %@", error);
        return;
    }
}

@end
