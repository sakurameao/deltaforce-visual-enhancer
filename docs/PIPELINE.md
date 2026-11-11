# 目标渲染管线分析

数据来源：`Payload/DeltaForceClient.app/cookeddata/deltaforce/content/` 下的两个预编译 Metal 库。

| 文件 | 大小 |
|---|---|
| `deltaforce_sf_metal.0.metallib` | 43.44 MB |
| `global_sf_metal.0.metallib` | 21.63 MB |

格式 `MTLB` version `0x02000100`（Metal 1.2）。

## 存在的着色器

**光照与几何**

```
MobileBasePass              移动端 Forward 基础光照
MobileShadowDepthPass       阴影深度（CSM）
MobileDirectionalLight      单方向光
MobileLocalLights           动态局部光（点/聚）
PRTLighting                 预计算辐射传输（静态 GI 近似）
IndirectLightingCache       间接光缓存
EyeAdaptation               自动曝光
```

**后处理（global 库）**

```
Bloom + Upsample/Downsample      泛光及其降采样金字塔
Tonemap + Vignette + Grain       色调映射与暗角
ColorGradingLUT（texture3d）      3D LUT 调色
TemporalAA                       时域抗锯齿
FXAA                             快速抗锯齿
LocalExposure (UE4.26+)          局部曝光
LightShaft                       屏幕空间光束
MobileMotionBlur                 移动端运动模糊
DepthOfField                     景深
Distortion                       折射/热浪
MobileColorGradingAndTonemap     移动端合并后处理
```

**地形**

```
LandscapeContinuousLODParameters / CDLODConstParameters
```

## 不存在的东西

```
SSAO              ScreenSpaceReflection     VolumetricFog
DistanceField     Lumen                     RayTracing
Deferred          Subsurface
```

## 结论

这是 UE4 的 **Mobile Forward** 路径：光照在 `MobileBasePass` 里一次性算完，没有 G-buffer，没有延迟光照阶段。

对"加光影"这件事意味着：

- **没有延迟管线可供插入**。想在光照阶段改东西，得改 `MobileBasePass` 的 shader 二进制（metallib 里的 GPU 机器码），工程上不现实。
- **CSM 阴影在 BasePass 之前就已烘好**，后处理改不了阴影本身，只能做接触阴影近似。
- **没有 G-buffer = 没有法线/粗糙度**。SSAO 得从 depth 重建法线，SSR 只能靠 depth 硬猜，效果都会打折。
- **没有 ComputeShader 阶段**可见（metallib 里没有 compute 入口），所以后处理基本是 fragment pass。
- **LightShaft 已存在**，体积光可以复用它的参数走屏幕空间 ray march，这是唯一接近"光影"的可行项。

## 对 DFXEnhancer 的意义

因为拿不到 G-buffer、也改不了光照阶段，本项目的后处理只能作用于最终 tonemap 之后的 `drawable.texture`：

```
SceneColor → Bloom → Tonemap → ColorGrading → drawable
                                                  ↑
                                            DFXEnhance 在这里
```

这是纯像素域调整（对比度/锐化/提亮/去雾），不需要深度、不需要法线、不依赖任何游戏内部数据。代价是：它能拉回被压缩的动态范围，但无法重建已经丢失的几何信息。

## pak 格式备注

`pak-0-0-pakchunk1-iosclient.pak` 的前 4 字节是 `0x00000001`，而标准 UE4 pak 的 magic 是 `0x5A6F12E1`。说明资源包经过自定义封装或加密，直接改 pak 内容的门槛较高。这也是本项目选择运行时后处理、而不是修改资源的原因之一。
