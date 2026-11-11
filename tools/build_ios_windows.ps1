# 用 llvm-mingw 的 clang 交叉编译 iOS arm64 dylib
param(
    [string]$SrcDir  = "D:\works\deltaforce-visual-enhancer\src",
    [string]$Sdk     = "C:\iosbuild\sdk\iPhoneOS16.5.sdk",
    [string]$ToolBin = "C:\iosbuild\llvm-mingw\bin",
    [string]$Out     = "C:\iosbuild\DFXEnhance.dylib",
    [string]$MinIOS  = "12.0"
)

$ErrorActionPreference = "Stop"

$clang = Join-Path $ToolBin "clang.exe"
if (-not (Test-Path $clang)) { throw "找不到 clang: $clang" }
if (-not (Test-Path $Sdk))   { throw "找不到 SDK: $Sdk" }

$sources = Get-ChildItem $SrcDir -Filter *.m | ForEach-Object { $_.FullName }
if ($sources.Count -eq 0) { throw "源目录没有 .m 文件: $SrcDir" }

$args = @(
    "-target", "arm64-apple-ios$MinIOS",
    "-isysroot", $Sdk,
    "-fobjc-arc",
    "-O2",
    "-fvisibility=hidden",
    "-dynamiclib",
    "-fuse-ld=lld",
    "-Wl,-platform_version,ios,$MinIOS,$MinIOS",
    "-Wl,-install_name,@executable_path/Frameworks/DFXEnhance.dylib",
    "-framework", "Foundation",
    "-framework", "UIKit",
    "-framework", "Metal",
    "-framework", "QuartzCore",
    "-o", $Out
) + $sources

Write-Host "[*] clang: $clang"
Write-Host "[*] sdk  : $Sdk"
Write-Host "[*] 源文件: $($sources.Count) 个"
Write-Host "[*] 命令:"
Write-Host ("    " + $clang + " " + ($args -join " "))
Write-Host ""

& $clang @args 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[!] 编译失败，exit=$LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

if (Test-Path $Out) {
    $f = Get-Item $Out
    Write-Host ""
    Write-Host "[+] 成功: $Out ($([math]::Round($f.Length/1KB,1)) KB)" -ForegroundColor Green
} else {
    Write-Host "[!] 没有生成产物" -ForegroundColor Red
}
