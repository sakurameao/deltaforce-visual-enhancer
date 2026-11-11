//
//  DFXShaders.h
//  Metal 内核源码以字符串形式内嵌，运行时用 newLibraryWithSource 编译，
//  这样构建产物不需要携带 metallib，也就不依赖 xcrun metal 工具链。
//

#ifndef DFXShaders_h
#define DFXShaders_h

static NSString *const kDFXKernelSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct DFXParams {\n"
"    float contrast;\n"
"    float sharpen;\n"
"    float shadowLift;\n"
"    float dehaze;\n"
"};\n"
"\n"

"kernel void dfx_enhance(texture2d<float, access::read>  src [[texture(0)]],\n"
"                       texture2d<float, access::write> dst [[texture(1)]],\n"
"                       constant DFXParams &p [[buffer(0)]],\n"
"                       uint2 gid [[thread_position_in_grid]])\n"
"{\n"
"    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
"\n"
"    float3 c = src.read(gid).rgb;\n"
"\n"
"    // --- 锐化：4 邻域 unsharp mask ---\n"
"    if (p.sharpen > 0.001) {\n"
"        uint w = src.get_width();\n"
"        uint h = src.get_height();\n"
"        uint xm = (gid.x == 0)     ? gid.x : gid.x - 1;\n"
"        uint xp = (gid.x + 1 >= w) ? gid.x : gid.x + 1;\n"
"        uint ym = (gid.y == 0)     ? gid.y : gid.y - 1;\n"
"        uint yp = (gid.y + 1 >= h) ? gid.y : gid.y + 1;\n"
"        float3 blur = (src.read(uint2(xm, gid.y)).rgb +\n"
"                       src.read(uint2(xp, gid.y)).rgb +\n"
"                       src.read(uint2(gid.x, ym)).rgb +\n"
"                       src.read(uint2(gid.x, yp)).rgb) * 0.25;\n"
"        c += (c - blur) * p.sharpen;\n"
"    }\n"
"\n"
"    // --- 暗部提亮：按亮度反向加权，避免整体泛白 ---\n"
"    if (p.shadowLift > 0.001) {\n"
"        float l = dot(saturate(c), float3(0.2126, 0.7152, 0.0722));\n"
"        float lift = p.shadowLift * (1.0 - l) * (1.0 - l);\n"
"        c = c + lift * (1.0 - c);\n"
"    }\n"
"\n"
"    // --- 去雾：暗通道近似，去除低对比灰蒙 ---\n"
"    if (p.dehaze > 0.001) {\n"
"        float mn = min(min(c.r, c.g), c.b);\n"
"        float atmos = 0.75;\n"
"        float t = clamp(1.0 - p.dehaze * (mn / atmos), 0.35, 1.0);\n"
"        c = (c - atmos) / t + atmos;\n"
"    }\n"
"\n"
"    // --- 对比度：围绕中灰拉伸 ---\n"
"    c = (c - 0.5) * p.contrast + 0.5;\n"
"\n"
"    dst.write(float4(saturate(c), 1.0), gid);\n"
"}\n";

#endif /* DFXShaders_h */
