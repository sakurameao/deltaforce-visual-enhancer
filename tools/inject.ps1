<#
.SYNOPSIS
    把 DFXEnhance.dylib 注入目标 IPA：追加 LC_LOAD_DYLIB 并重新打包。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/inject.ps1 `
        -SourceIpa "D:\works\DeltaForce_NoKey.ipa" `
        -Dylib     "build\DFXEnhance.dylib" `
        -OutputIpa "D:\works\DeltaForce_Visual.ipa"
#>
param(
    [Parameter(Mandatory = $true)][string]$SourceIpa,
    [Parameter(Mandatory = $true)][string]$Dylib,
    [Parameter(Mandatory = $true)][string]$OutputIpa,
    [string]$InstallName = '@executable_path/Frameworks/DFXEnhance.dylib',
    [string]$AppPath     = 'Payload/DeltaForceClient.app',
    [switch]$KeepCodeResources
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

$ErrorActionPreference = 'Stop'

# ---------- 预检 ----------
if (-not (Test-Path $SourceIpa)) { throw "源 IPA 不存在: $SourceIpa" }
if (-not (Test-Path $Dylib))     { throw "dylib 不存在: $Dylib"   }

$binEntryName   = "$AppPath/DeltaForceClient"
$dylibEntryName = "$AppPath/Frameworks/" + (Split-Path $Dylib -Leaf)
$tmpBin = [System.IO.Path]::GetTempFileName()

Write-Host "[*] 源: $SourceIpa"
Write-Host "[*] 注入: $InstallName"

# ---------- 1. 取出主二进制 ----------
$zip = [System.IO.Compression.ZipFile]::OpenRead($SourceIpa)
$binEntry = $zip.Entries | Where-Object { $_.FullName -eq $binEntryName }
if (-not $binEntry) { $zip.Dispose(); throw "找不到主二进制: $binEntryName" }

$fs = [System.IO.File]::Create($tmpBin)
$s = $binEntry.Open(); $s.CopyTo($fs); $s.Dispose(); $fs.Close()
Write-Host "[*] 主二进制: $([math]::Round($binEntry.Length/1MB,1)) MB"

# ---------- 2. 追加 LC_LOAD_DYLIB ----------
$fh = [System.IO.File]::Open($tmpBin, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
$hdr = New-Object byte[] 32
$null = $fh.Read($hdr, 0, 32)
$ncmds      = [BitConverter]::ToUInt32($hdr, 16)
$sizeofcmds = [BitConverter]::ToUInt32($hdr, 20)

$cmdStart  = 32 + $sizeofcmds
$textStart = 16384
$pathBytes = [System.Text.Encoding]::ASCII.GetBytes($InstallName) + [byte]0
$cmdSize   = [int]([Math]::Ceiling((24 + $pathBytes.Length) / 8.0) * 8)

if ($cmdStart + $cmdSize -gt $textStart) {
    $fh.Close()
    throw "load commands 区空间不足（需要 $cmdSize 字节，剩余 $($textStart - $cmdStart)）"
}

$cmd = New-Object byte[] $cmdSize
[BitConverter]::GetBytes([uint32]0xC).CopyTo($cmd, 0)
[BitConverter]::GetBytes([uint32]$cmdSize).CopyTo($cmd, 4)
[BitConverter]::GetBytes([uint32]24).CopyTo($cmd, 8)
[BitConverter]::GetBytes([uint32]0).CopyTo($cmd, 12)
[BitConverter]::GetBytes([uint32]0x00010000).CopyTo($cmd, 16)
[BitConverter]::GetBytes([uint32]0x00010000).CopyTo($cmd, 20)
[Array]::Copy($pathBytes, 0, $cmd, 24, $pathBytes.Length)

$fh.Position = 16
$fh.Write([BitConverter]::GetBytes([uint32]($ncmds + 1)), 0, 4)
$fh.Position = 20
$fh.Write([BitConverter]::GetBytes([uint32]($sizeofcmds + $cmdSize)), 0, 4)
$fh.Position = $cmdStart
$fh.Write($cmd, 0, $cmdSize)

$fh.Position = 0
$null = $fh.Read($hdr, 0, 32)
Write-Host "[*] ncmds: $ncmds -> $([BitConverter]::ToUInt32($hdr,16))"
Write-Host "[*] sizeofcmds: $sizeofcmds -> $([BitConverter]::ToUInt32($hdr,20))"
$fh.Close()

# ---------- 3. 重新打包 ----------
$newBin = [System.IO.File]::ReadAllBytes($tmpBin)
$dylibBytes = [System.IO.File]::ReadAllBytes($Dylib)

$skipList = @("$AppPath/SignedByEsign")
if (-not $KeepCodeResources) { $skipList += "$AppPath/_CodeSignature/CodeResources" }

$out = [System.IO.Compression.ZipFile]::Open($OutputIpa, [System.IO.Compression.ZipArchiveMode]::Create)
$written = 0

foreach ($e in $zip.Entries) {
    if ($skipList -ccontains $e.FullName) {
        Write-Host "[*] 剔除: $($e.FullName)"
        continue
    }
    $entry = $out.CreateEntry($e.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $e.LastWriteTime
    if ($e.FullName.EndsWith('/')) { continue }

    $dst = $entry.Open()
    if ($e.FullName -ceq $binEntryName) {
        $dst.Write($newBin, 0, $newBin.Length)
        Write-Host "[*] 替换主二进制"
    } else {
        $src = $e.Open(); $src.CopyTo($dst); $src.Dispose()
    }
    $dst.Dispose()
    $written++
}

$de = $out.CreateEntry($dylibEntryName, [System.IO.Compression.CompressionLevel]::Optimal)
$de.LastWriteTime = Get-Date
$ds = $de.Open(); $ds.Write($dylibBytes, 0, $dylibBytes.Length); $ds.Dispose()
Write-Host "[*] 写入 $dylibEntryName"

$zip.Dispose()
$out.Dispose()
Remove-Item $tmpBin -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[+] 完成: $written 个文件"
Write-Host "[+] 输出: $OutputIpa ($([math]::Round((Get-Item $OutputIpa).Length/1MB,1)) MB)"
Write-Host ""
Write-Host "[!] 该 IPA 未签名。需要用自己的证书重签后才能安装："
Write-Host "    ESign / TrollStore / codesign 均可。"
