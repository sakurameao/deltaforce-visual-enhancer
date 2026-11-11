//
//  DFXEnhancer.h
//  三角洲行动 · 画面可见性增强后处理模块
//
//  作用边界：仅对屏幕上已渲染的像素做对比度/锐化/暗部提亮/去雾。
//  不读取任何游戏实体、坐标或骨骼数据，不具备透视能力。
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

/// 后处理参数，全部为像素域视觉调整
typedef struct {
    float contrast;     // 对比度      1.0 = 原始
    float sharpen;      // 锐化强度    0.0 = 关闭
    float shadowLift;   // 暗部提亮    0.0 = 关闭
    float dehaze;       // 去雾强度    0.0 = 关闭
} DFXParams;

@interface DFXEnhancer : NSObject

+ (instancetype)shared;

/// 安装 hook，必须在 app 启动早期调用
+ (void)install;

/// 供 hook 层调用：在 present 之前处理 drawable
- (void)processCommandBuffer:(id<MTLCommandBuffer>)cmdBuffer
                    drawable:(id<CAMetalDrawable>)drawable;

@property (nonatomic, assign) DFXParams params;
@property (nonatomic, assign) BOOL enabled;

@end

NS_ASSUME_NONNULL_END
