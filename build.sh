#!/usr/bin/env bash
#
# 在 macOS 上构建 iOS arm64 dylib。
# 依赖：Xcode Command Line Tools（xcrun / clang）、ldid（可选但推荐）
#
#   chmod +x build.sh && ./build.sh
#

set -euo pipefail

cd "$(dirname "$0")"

OUT="${1:-build/DFXEnhance.dylib}"
mkdir -p "$(dirname "$OUT")"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "[!] 找不到 xcrun，需要先安装 Xcode Command Line Tools：" >&2
  echo "    xcode-select --install" >&2
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "[*] SDK: $SDK"

SOURCES=(
  src/DFXEnhancer.m
  src/DFXEntry.m
)

xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=12.0 \
  -fobjc-arc \
  -O2 \
  -fvisibility=hidden \
  -dynamiclib \
  -framework Foundation \
  -framework UIKit \
  -framework Metal \
  -framework QuartzCore \
  -install_name "@executable_path/Frameworks/DFXEnhance.dylib" \
  -o "$OUT" \
  "${SOURCES[@]}"

echo "[+] 编译完成: $OUT"

# dyld 在非越狱环境只加载有签名的 dylib
if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT"
  echo "[+] ldid 签名完成"
else
  echo "[!] 未找到 ldid。请执行以下任一后重试：" >&2
  echo "    brew install ldid" >&2
  echo "    或 codesign -f -s - --timestamp=none \"$OUT\"" >&2
fi

echo
echo "[*] 校验："
otool -L "$OUT" || true
echo
echo "[*] 下一步：把 $OUT 与 tools/inject.ps1 一起带回 Windows 执行注入打包。"
