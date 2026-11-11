# DeltaForce Visual Enhancer

给《三角洲行动》iOS 版加一层屏幕后处理，提升画面里**已经渲染出来的**目标可见性：对比度、锐化、暗部提亮、去雾。

## 边界声明

这个模块只操作像素。

- **能做**：让远处的人形边缘更锐、暗部轮廓更清楚、雾霾下的对比度更高。
- **做不到**：让墙后面的人显形。没有任何后处理能凭空造出被遮挡物体的像素，那些信息在屏幕上根本不存在。

它不读取游戏实体列表、不读坐标、不读骨骼、不碰 `UWorld`/`GNames`。源码里你可以自己搜，没有一处 ObjC 运行时遍历游戏对象的代码。

## 为什么需要它

《三角洲行动》用的是 UE4 Mobile Forward 管线（`MobileBasePass` + PRT 静态光照 + CSM + 完整后处理链，见 `docs/PIPELINE.md`）。这个管线为了省移动端 GPU 预算，在暗部细节和远景对比度上做了大量妥协：暗部被压成一片死黑，远处雾化严重，目标轮廓容易糊进背景。

后处理层可以在不重新计算光照的前提下，把这些被压掉的信息拉回来一部分。

## 工作原理

```
CAMetalLayer.nextDrawable  ──►  framebufferOnly = NO
        │
        ▼
MTLCommandBuffer.presentDrawable:
        │
        ├─ blit   drawable.texture ──► texA
        ├─ compute texA ──► texB   (dfx_enhance kernel)
        ├─ blit   texB ──► drawable.texture
        └─ 原始 present
```

两个关键点：

1. `CAMetalLayer.framebufferOnly` 默认是 `YES`，此时 `drawable.texture` 只能当 render target，**不能**被 blit 读取。必须先关掉它，否则整条链路一个像素都拿不到。
2. `MTLCommandBuffer` 是协议，不能直接 swizzle，得用 `objc_getClassList` 找到具体实现类（`AGXCommandBuffer` / `_MTLCommandBuffer`）再换 IMP。

shader 用 `newLibraryWithSource:` 在运行时编译，所以构建产物不需要携带 `.metallib`，也就不需要 `xcrun metal`。

## 构建

需要 macOS + Xcode Command Line Tools。

```bash
xcode-select --install   # 如果还没装
brew install ldid        # 可选，但签名必需

chmod +x build.sh
./build.sh
# 产物：build/DFXEnhance.dylib
```

## 注入

在 Windows 上把 dylib 注入目标 IPA：

```powershell
powershell -ExecutionPolicy Bypass -File tools/inject.ps1 `
  -SourceIpa  "D:\works\DeltaForce_NoKey.ipa" `
  -Dylib      "build\DFXEnhance.dylib" `
  -OutputIpa  "D:\works\DeltaForce_Visual.ipa"
```

脚本会：

1. 在主二进制追加 `LC_LOAD_DYLIB @executable_path/Frameworks/DFXEnhance.dylib`（复用 load commands 区的 padding，文件总大小不变）
2. 把 dylib 写进 `Frameworks/`
3. 剔除陈旧的 `_CodeSignature/CodeResources`（重签时由签名工具重建）
4. 重新打包 IPA

## 参数

默认值在 `DFXEnhancer.m` 的 `loadParams` 里，也可以安装后通过 `NSUserDefaults` 外部覆盖（需要写权限的调试通道）：

| key | 含义 | 默认 |
|---|---|---|
| `dfx.enabled` | 总开关 | `YES` |
| `dfx.contrast` | 对比度 | `1.08` |
| `dfx.sharpen` | 锐化强度 | `0.55` |
| `dfx.shadowLift` | 暗部提亮 | `0.35` |
| `dfx.dehaze` | 去雾强度 | `0.30` |

调参建议：`sharpen` 超过 0.8 会出现明显白边，`dehaze` 超过 0.5 会把远景压成灰块。先动 `shadowLift`，那个对视野的改善最直接。

## 风险

改包会被反作弊盯上，跟这个模块本身无关：

- `anogs.framework` 用 `_dyld_image_count` / `_dyld_get_image_name` / `_proc_regionfilename` 枚举镜像，多一个 dylib 就多一条记录
- `_vm_read` 会校验 `__TEXT` 段完整性
- `DataDomeSDK` 还有一层行为风控

**联机模式下账号保不住。** 这个模块适合单机测试、画面研究，或者你接受封号的独立设备。

## 目录

```
src/DFXEnhancer.m     hook 层 + 纹理管理 + 主流程
src/DFXShaders.h      内嵌 Metal kernel 源码
src/DFXEntry.m        constructor 入口
build.sh              macOS 构建脚本
tools/inject.ps1      注入并重新打包 IPA
docs/PIPELINE.md      目标游戏的渲染管线分析
```

## 许可

MIT
