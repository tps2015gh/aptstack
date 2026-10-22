#Requires -Version 5.1
<#
.SYNOPSIS
    aptstack setup wizard - เตรียม stack ครั้งแรก
.DESCRIPTION
    ตรวจ environment -> สร้างโครงสร้าง -> ติดตั้ง app/PHP ถ้ามี zip ให้ -> ตั้งค่าเริ่มต้น
    หลังจบให้รัน: aptstack doctor
.EXAMPLE
    .\setup.ps1
.EXAMPLE
    .\setup.ps1 -AppDir "C:\deploy\apt-app-1.1.0" -PhpZip "C:\Downloads\php-8.3.36-Win32-vs17-x64.zip"
#>
[CmdletBinding()]
param(
    [string]$AppDir,
    [string]$AppZip,
    [string]$AppName = '1.0.0',
    [string]$PhpZip,
    [string]$PhpUrl,
    [int]$HttpPort = 8077,
    [int]$DbPort = 3307,
    [switch]$SkipStart
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Apt = Join-Path $Root 'aptstack.ps1'

function Step($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    !!  $t" -ForegroundColor Yellow }
function Info($t) { Write-Host "        $t" -ForegroundColor Gray }

if (-not (Test-Path $Apt)) { throw "ไม่พบ aptstack.ps1 ที่ $Root" }

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   aptstack setup wizard' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan

Step 1 'ตรวจ environment'
Info "PowerShell $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'ต้องใช้ PowerShell 5.1 ขึ้นไป' }
if ($Root -match '\s') { Warn 'path มีช่องว่าง — Apache/PHP บน Windows มีปัญหากับช่องว่างได้ (แนะนำย้าย)' }
else { Ok "path สะอาด: $Root" }

Step 2 'สร้างโครงสร้างโฟลเดอร์'
& $Apt init | Out-Null
Ok 'สร้างแล้ว (versions\, stack\, data\, config\, logs\, www\)'

Step 3 'ติดตั้งแอป'
$appInstalled = $false
if ($AppZip) {
    & $Apt add app $AppZip
    $appInstalled = $true
} elseif ($AppDir) {
    & $Apt add app $AppDir $AppName
    $appInstalled = $true
}
if ($appInstalled) {
    & $Apt use $AppName
    Ok "app $AppName พร้อมใช้"
} else {
    Warn 'ยังไม่ได้ติดตั้งแอป'
    Info 'เพิ่มทีหลัง:  aptstack add app <folder-or-zip>'
    Info 'แล้วเปิดใช้ :  aptstack use <name>'
}

Step 4 'ติดตั้ง PHP'
$phpInstalled = $false
if ($PhpUrl)  { & $Apt add php $PhpUrl;  $phpInstalled = $true }
elseif ($PhpZip) {
    if (-not (Test-Path $PhpZip)) { throw "ไม่พบไฟล์: $PhpZip" }
    & $Apt add php $PhpZip; $phpInstalled = $true
}
if ($phpInstalled) {
    $list = & $Apt list
    Ok 'ติดตั้ง PHP แล้ว'
} else {
    Warn 'ยังไม่ได้ติดตั้ง PHP'
    Info 'ดาวน์โหลด: https://windows.php.net/downloads/releases/'
    Info 'เลือกไฟล์ php-<ver>-Win32-vs17-x64.zip (ตัวนี้เป็น Thread Safe อยู่แล้ว)'
    Info 'แล้วรัน: aptstack add php C:\Downloads\php-8.3.36-Win32-vs17-x64.zip'
    Info ''
    Info 'เวอร์ชันที่ผ่านช่องโหว่ RCE (security-php.txt):'
    Info '  8.5.12+ / 8.4.27+ / 8.3.36+ / 8.2.35+   |   8.1 และต่ำกว่า = EOL ห้ามใช้ production'
}

Step 5 'ตั้งค่าพอร์ต'
$cfgPath = Join-Path $Root 'config\stack.json'
$cfg = @{ app = ''; appPrev = ''; php = ''; phpPrev = ''; mysql = ''; httpPort = $HttpPort; dbPort = $DbPort; appAlias = 'app'; serviceName = 'AptStack'; dbUser = 'root'; dbPass = 'root'; dbAdmin = 'auto' }
if (Test-Path $cfgPath) {
    try {
        $ex = Get-Content $cfgPath -Raw | ConvertFrom-Json
        foreach ($k in @($ex.PSObject.Properties.Name)) { if ($null -ne $ex.$k -and "$($ex.$k)" -ne '') { $cfg[$k] = $ex.$k } }
    } catch { }
}
$cfg.httpPort = $HttpPort
$cfg.dbPort = $DbPort
# UTF-8 ไม่มี BOM — JSON ที่มี BOM ทำให้ php json_decode() คืน null
[IO.File]::WriteAllText($cfgPath, (($cfg | ConvertTo-Json) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Ok "http=$HttpPort  db=$DbPort"
Info 'ถ้าชนกับ program อื่น ให้แก้ config\stack.json แล้ว aptstack restart'

Step 6 'ตรวจความปลอดภัย'
& $Apt doctor

Step 7 'สรุป'
& $Apt list
Write-Host ''
Write-Host '  ขั้นต่อไป:' -ForegroundColor White
Write-Host '    aptstack start            # เริ่ม MariaDB + Web' -ForegroundColor Gray
Write-Host '    aptstack service install  # ติดตั้งเป็น Windows Service (ต้อง admin)' -ForegroundColor Gray
Write-Host '    aptstack backup           # dump database ก่อนเปลี่ยนเวอร์ชัน' -ForegroundColor Gray
Write-Host ''
Write-Host '  เปลี่ยนแอป : aptstack use <ver>  หรือ aptstack use - (ย้อนกลับ)' -ForegroundColor Gray
Write-Host '  เปลี่ยน PHP : aptstack use php <ver>  หรือ aptstack use (เมนู)' -ForegroundColor Gray
Write-Host ''
if (-not $SkipStart) {
    $ans = Read-Host '  เริ่ม stack ตอนนี้เลยไหม? (y/n)'
    if ($ans -match '^(y|Y)') { & $Apt start } else { Info 'รันเองเมื่อพร้อม: aptstack start' }
}
Write-Host ''
