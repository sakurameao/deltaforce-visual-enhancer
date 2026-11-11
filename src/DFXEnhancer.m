//
//  DFXEnhancer.m
//  三角洲行动 · 画面可见性增强后处理
//
//  管线：drawable ← blit ← tmpB ← compute(shader) ← tmpA ← blit ← drawable
//
//  关键约束：CAMetalLayer.framebufferOnly 默认为 YES，此时 drawable.texture
//  只能作为 render target，无法被 blit 读取。因此必须拦截 nextDrawable 把它
//  关掉，否则整条链路拿不到像素。
//

#import "DFXEnhancer.h"
#import "DFXShaders.h"
#import <objc/runtime.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

static void (*gOrigPresent)(id, SEL, id) = NULL;
static id (*gOrigNextDrawable)(id, SEL) = NULL;

#pragma mark - Hooks

static void dfx_present(id self, SEL _cmd, id drawable)
{
    @try {
        [[DFXEnhancer shared] processCommandBuffer:(id<MTLCommandBuffer>)self
                                          drawable:(id<CAMetalDrawable>)drawable];
    } @catch (NSException *e) {
        NSLog(@"[DFX] present hook error: %@", e.reason);
    }
    if (gOrigPresent) {
        gOrigPresent(self, _cmd, drawable);
    }
}

static id dfx_nextDrawable(id self, SEL _cmd)
{
    @try {
        // 只有关掉 framebufferOnly，drawable.texture 才能作为 blit 源被读取
        CAMetalLayer *layer = (CAMetalLayer *)self;
        if (layer.framebufferOnly) {
            layer.framebufferOnly = NO;
        }
    } @catch (NSException *e) {
        NSLog(@"[DFX] framebufferOnly patch failed: %@", e.reason);
    }
    return gOrigNextDrawable ? gOrigNextDrawable(self, _cmd) : nil;
}

#pragma mark - DFXEnhancer

@implementation DFXEnhancer {
    id<MTLDevice>               _device;
    id<MTLCommandQueue>         _queue;
    id<MTLComputePipelineState> _pipeline;
    id<MTLTexture>              _texA;
    id<MTLTexture>              _texB;
    NSUInteger                  _texW;
    NSUInteger                  _texH;
    MTLPixelFormat              _texFmt;
    DFXParams                   _params;
    BOOL                        _enabled;
}

+ (instancetype)shared
{
    static DFXEnhancer *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[DFXEnhancer alloc] init]; });
    return inst;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _enabled = YES;
        [self loadParams];
        NSLog(@"[DFX] enhancer init  contrast=%.2f sharpen=%.2f lift=%.2f dehaze=%.2f",
              _params.contrast, _params.sharpen, _params.shadowLift, _params.dehaze);
    }
    return self;
}

- (void)setParams:(DFXParams)params
{
    _params = params;
    [self saveParams];
}

- (DFXParams)params { return _params; }

#pragma mark - 参数持久化（可用 NSUserDefaults 外部覆盖，便于调试）

- (void)loadParams
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    _params.contrast   = [d objectForKey:@"dfx.contrast"]   ? [d floatForKey:@"dfx.contrast"]   : 1.08f;
    _params.sharpen    = [d objectForKey:@"dfx.sharpen"]    ? [d floatForKey:@"dfx.sharpen"]    : 0.55f;
    _params.shadowLift = [d objectForKey:@"dfx.shadowLift"] ? [d floatForKey:@"dfx.shadowLift"] : 0.35f;
    _params.dehaze     = [d objectForKey:@"dfx.dehaze"]     ? [d floatForKey:@"dfx.dehaze"]     : 0.30f;
    if ([d objectForKey:@"dfx.enabled"]) {
        _enabled = [d boolForKey:@"dfx.enabled"];
    }
}

- (void)saveParams
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setFloat:_params.contrast   forKey:@"dfx.contrast"];
    [d setFloat:_params.sharpen    forKey:@"dfx.sharpen"];
    [d setFloat:_params.shadowLift forKey:@"dfx.shadowLift"];
    [d setFloat:_params.dehaze     forKey:@"dfx.dehaze"];
    [d setBool:_enabled            forKey:@"dfx.enabled"];
}

#pragma mark - 资源准备

- (BOOL)prepareWithTexture:(id<MTLTexture>)target
{
    if (!_device) {
        _device = target.device;
    }
    if (!_device) { return NO; }

    if (!_pipeline) {
        NSError *err = nil;
        id<MTLLibrary> lib = [_device newLibraryWithSource:kDFXKernelSource
                                                   options:nil
                                                     error:&err];
        if (!lib) {
            NSLog(@"[DFX] shader compile failed: %@", err.localizedDescription);
            return NO;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"dfx_enhance"];
        if (!fn) {
            NSLog(@"[DFX] kernel dfx_enhance not found");
            return NO;
        }
        _pipeline = [_device newComputePipelineStateWithFunction:fn error:&err];
        if (!_pipeline) {
            NSLog(@"[DFX] pipeline build failed: %@", err.localizedDescription);
            return NO;
        }
        NSLog(@"[DFX] pipeline ready (tw=%lu, max=%lu)",
              (unsigned long)_pipeline.threadExecutionWidth,
              (unsigned long)_pipeline.maxTotalThreadsPerThreadgroup);
    }

    // 纹理尺寸或格式变化时重建中间缓冲
    if (!_texA || _texW != target.width || _texH != target.height || _texFmt != target.pixelFormat) {
        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:target.pixelFormat
                                                               width:target.width
                                                              height:target.height
                                                           mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        desc.storageMode = MTLStorageModePrivate;

        _texA = [_device newTextureWithDescriptor:desc];
        _texB = [_device newTextureWithDescriptor:desc];
        _texW = target.width;
        _texH = target.height;
        _texFmt = target.pixelFormat;

        if (!_texA || !_texB) {
            NSLog(@"[DFX] intermediate texture alloc failed (%lux%lu fmt=%lu)",
                  (unsigned long)_texW, (unsigned long)_texH, (unsigned long)_texFmt);
            return NO;
        }
        NSLog(@"[DFX] buffers %lux%lu fmt=%lu", (unsigned long)_texW, (unsigned long)_texH, (unsigned long)_texFmt);
    }

    return YES;
}

#pragma mark - 主流程

- (void)processCommandBuffer:(id<MTLCommandBuffer>)cmdBuffer
                    drawable:(id<CAMetalDrawable>)drawable
{
    if (!_enabled || !cmdBuffer || !drawable) { return; }

    id<MTLTexture> target = drawable.texture;
    if (!target || target.width == 0 || target.height == 0) { return; }

    if (![self prepareWithTexture:target]) { return; }

    MTLSize full = MTLSizeMake(target.width, target.height, 1);

    // 1) drawable -> texA
    id<MTLBlitCommandEncoder> blit = [cmdBuffer blitCommandEncoder];
    if (!blit) { return; }
    [blit copyFromTexture:target
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(target.width, target.height, 1)
                toTexture:_texA
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    // 2) compute: texA -> texB
    id<MTLComputeCommandEncoder> enc = [cmdBuffer computeCommandEncoder];
    if (!enc) { return; }
    [enc setComputePipelineState:_pipeline];
    [enc setTexture:_texA atIndex:0];
    [enc setTexture:_texB atIndex:1];
    DFXParams p = _params;
    [enc setBytes:&p length:sizeof(DFXParams) atIndex:0];

    NSUInteger tw = _pipeline.threadExecutionWidth;
    NSUInteger th = _pipeline.maxTotalThreadsPerThreadgroup / tw;
    if (th == 0) { th = 1; }
    [enc dispatchThreads:full
   threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
    [enc endEncoding];

    // 3) texB -> drawable
    blit = [cmdBuffer blitCommandEncoder];
    if (!blit) { return; }
    [blit copyFromTexture:_texB
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(target.width, target.height, 1)
                toTexture:target
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
}

#pragma mark - 安装

+ (void)install
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [DFXEnhancer shared];

        int count = objc_getClassList(NULL, 0);
        if (count <= 0) {
            NSLog(@"[DFX] no classes");
            return;
        }
        Class *classes = (Class *)malloc(sizeof(Class) * count);
        if (!classes) { return; }
        count = objc_getClassList(classes, count);

        int presentHooked = 0;
        int layerHooked = 0;

        for (int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *cname = class_getName(c);

            // MTLCommandBuffer 的具体实现类（AGXCommandBuffer / _MTLCommandBuffer 等）
            if (!presentHooked && strstr(cname, "CommandBuffer") != NULL) {
                Method m = class_getInstanceMethod(c, @selector(presentDrawable:));
                if (m) {
                    gOrigPresent = (void (*)(id, SEL, id))method_getImplementation(m);
                    method_setImplementation(m, (IMP)dfx_present);
                    presentHooked++;
                    NSLog(@"[DFX] hooked presentDrawable: on %s", cname);
                }
            }

        }

        // CAMetalLayer 是具体类，直接 hook 父类即可，子类继承后同样生效
        Method lm = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
        if (lm) {
            gOrigNextDrawable = (id (*)(id, SEL))method_getImplementation(lm);
            method_setImplementation(lm, (IMP)dfx_nextDrawable);
            layerHooked = 1;
            NSLog(@"[DFX] hooked nextDrawable on CAMetalLayer");
        }

        free(classes);
        NSLog(@"[DFX] install done: present=%d layer=%d", presentHooked, layerHooked);
    });
}

@end
