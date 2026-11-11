//
//  DFXEntry.m
//  dylib 加载入口。constructor 会在 dyld 完成加载后立即执行。
//

#import "DFXEnhancer.h"
#import <Metal/Metal.h>
#import <Metal/MTLCommandQueue.h>
#import <QuartzCore/CAMetalLayer.h>

__attribute__((constructor))
static void DFXEntry(void)
{
    @autoreleasepool {
        // 触发 Metal 运行时初始化，确保 CommandBuffer 的具体实现类
        // 已经注册到 objc runtime，否则 install 时枚举不到。
        // 用 NSClassFromString 而非直接引用类型，避免 SDK 里的条件编译差异。
        (void)NSClassFromString(@"MTLCommandQueue");
        (void)NSClassFromString(@"CAMetalLayer");

        [DFXEnhancer install];
        NSLog(@"[DFX] dylib loaded");
    }
}
