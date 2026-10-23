#Requires -Version 5.1
<#
.SYNOPSIS
    สร้าง release zip จากไฟล์ที่ git track ไว้ (ไม่เอา binary/โค้ดแอป/data)
.DESCRIPTION
    ใช้ `git archive` จึงได้เฉพาะไฟล์ใน repo -> ปลอดภัย ไม่มีทางเอาของ sensitive ติดไป
    ผลลัพธ์: dist\aptstack-<version>.zip + .sha256
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\make-release.ps1
    powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 -Version 1.1.0
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$NoHash
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info($t) { Write-Host "         $t" -ForegroundColor Gray }
function Head($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('  ' + ('-' * 50)) -ForegroundColor DarkGray }

Head 'build release'
if (-not $Version) {
    $vf = Join-Path $Root 'VERSION'
    if (Test-Path $vf) { $Version = (Get-Content $vf -Raw).Trim() }
    else { $Version = '0.0.0' }
}
Info "version: $Version"

# ต้อง commit ให้หมดก่อน ไม่งั้นไฟล์ใหม่จะไม่เข้า zip
$dirty = & git -C $Root status --porcelain 2>&1
if ($dirty) {
    Write-Warning 'ยังมีไฟล์ที่ commit ไม่หมด -> release อาจไม่ครบ'
    Info 'รัน: git add -A && git commit'
}

$dist = Join-Path $Root 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }
$out = Join-Path $dist "aptstack-$Version.zip"
if (Test-Path $out) { Remove-Item $out -Force }

Head "git archive -> $out"
# --prefix: zip ต้องมีโฟลเดอร์บนสุดชื่อ aptstack\ ไม่งั้นแตกแล้วไฟล์กระจายลง drive ที่ -C ชี้
# (คู่มืออย่าง SCENARIO.md สอน `tar -xf ... -C D:\` ตามด้วย `cd /d D:\aptstack`)
& git -C $Root archive --format=zip --prefix=aptstack/ -o "$out" HEAD
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw 'git archive ล้มเหลว' }
Ok ("{0}  ({1:N2} MB)" -f (Split-Path $out -Leaf), ((Get-Item $out).Length / 1MB))

$n = (& git -C $Root ls-files | Measure-Object).Count
Info "ไฟล์ใน zip: $n (จาก git ls-files)"

if (-not $NoHash) {
    $h = (Get-FileHash -Path $out -Algorithm SHA256).Hash
    $hashFile = "$out.sha256"
    Set-Content -Path $hashFile -Value "$h  $(Split-Path $out -Leaf)" -Encoding ASCII
    Ok "SHA256: $h"
    Info "บันทึก: $hashFile"
}

Head 'ขั้นต่อไป (อัปขึ้น GitHub Release)'
@'
  1. git tag v<version> && git push origin main --tags
  2. เปิด repo บน GitHub -> Releases -> Draft a new release
  3. tag = v<version> , แนบ dist\aptstack-<version>.zip เป็น asset
  4. ผู้ใช้ดาวน์โหลดแล้วแตก zip -> รัน setup.ps1 / aptstack start

  หมายเหตุ: ผู้ใช้ต้องโหลด PHP (และถ้าใช้ Apache) เอง
  ดูลิงก์ใน README-TH.md -> คู่มือ.md ขั้นตอนติดตั้ง
'@ | Write-Host
