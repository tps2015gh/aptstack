#Requires -Version 5.1
<#
.SYNOPSIS
    aptstack service manager - ติดตั้ง/ถอน Windows Service

.DESCRIPTION
    compile service\AptStackService.cs ด้วย csc.exe ของ .NET Framework ที่มากับ Windows
    แล้วลงทะเบียนด้วย sc.exe -> ไม่ต้องดาวน์โหลด NSSM/WinSW อะไรเพิ่ม

.EXAMPLE
    .\service.ps1 -Action install
    .\service.ps1 -Action status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'start', 'stop', 'restart', 'status', 'compile')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
# service.ps1 อยู่ที่ root ของ bundle -> PSScriptRoot คือ root เอง (ไม่ใช่ parent)
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SvcName = 'AptStack'
$SrcCs = Join-Path $Root 'service\AptStackService.cs'
$BinDir = Join-Path $Root 'bin'
$Exe = Join-Path $BinDir 'aptstack-svc.exe'

function Write-Head($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('  ' + ('-' * [Math]::Min(64, $t.Length + 8))) -ForegroundColor DarkGray }
function Write-Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Write-Err2($t) { Write-Host "  [ERR]  $t" -ForegroundColor Red }
function Write-Info($t) { Write-Host "         $t" -ForegroundColor Gray }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated($act) {
    Write-Warn2 'ต้องใช้สิทธิ์ administrator — เปิดหน้าต่าง UAC ให้กด Yes'
    $ps = Join-Path $Root 'service.ps1'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ps`"", '-Action', $act
    )
    return $false
}

function Find-Csc {
    $candidates = @(
        (Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Build-Service {
    if (-not (Test-Path $SrcCs)) { throw "ไม่พบ source: $SrcCs" }
    $csc = Find-Csc
    if (-not $csc) {
        throw 'ไม่พบ csc.exe (.NET Framework 4.x) — ติดตั้ง .NET Framework 4.x หรือใช้ Task Scheduler แทน'
    }
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }

    $need = $true
    if (Test-Path $Exe) {
        $srcTime = (Get-Item $SrcCs).LastWriteTimeUtc
        $exeTime = (Get-Item $Exe).LastWriteTimeUtc
        if ($exeTime -ge $srcTime) { $need = $false }
    }
    if (-not $need) { Write-Ok "มี $Exe แล้ว (ใหม่กว่า source)"; return $Exe }

    Write-Head 'compile service host'
    Write-Info $csc
    $ref = Join-Path (Split-Path $csc) 'System.ServiceProcess.dll'
    $args = @('/nologo', '/target:exe', "/out:`"$Exe`"", "/r:`"$ref`"", "`"$SrcCs`"")
    $out = & $csc @args 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Exe)) {
        throw "compile ล้มเหลว:`r`n$($out -join "`r`n")"
    }
    Write-Ok "สร้างแล้ว: $Exe"
    return $Exe
}

function Get-ServiceObj { Get-Service -Name $SvcName -ErrorAction SilentlyContinue }

function Invoke-Sc([string[]]$scArgs, [switch]$Throw) {
    $out = & sc.exe @scArgs 2>&1
    $txt = $out -join ' '
    if ($Throw -and $LASTEXITCODE -ne 0) { throw "sc $($scArgs -join ' ') -> $txt" }
    return $txt
}

switch ($Action) {
    'compile' {
        Build-Service | Out-Null
    }

    'install' {
        if (-not (Test-Admin)) { Invoke-Elevated 'install'; break }
        $exe = Build-Service
        Write-Head 'ติดตั้ง Windows Service'
        if (Get-ServiceObj) { Write-Warn2 'มี service อยู่แล้ว — ถอนก่อนด้วย: aptstack service uninstall' }

        # กันชน: ถ้า web/db port ถูก stack แบบ manual จองอยู่ (dev ยังไม่ได้ stop)
        # service จะ start ตอนบูตแล้วชนพอร์ต -> เตือนให้ aptstack stop ก่อน
        $httpP = 8077; $dbP = 3307
        $cfgPath = Join-Path $Root 'config\stack.json'
        if (Test-Path $cfgPath) {
            try {
                $cj = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($cj.httpPort) { $httpP = [int]$cj.httpPort }
                if ($cj.dbPort)   { $dbP   = [int]$cj.dbPort }
            } catch { }
        }
        $busy = @()
        foreach ($pp in @($httpP, $dbP)) {
            if (Get-NetTCPConnection -LocalPort $pp -State Listen -ErrorAction SilentlyContinue) { $busy += $pp }
        }
        if ($busy.Count -gt 0) {
            Write-Warn2 ("พอร์ต " + ($busy -join ', ') + " ถูกใช้อยู่ — ดูเหมือน stack แบบ manual ยังรันอยู่")
            Write-Info 'ถ้าติดตั้งเลย ตอนบูต service จะชนกับการรัน manual เดิม'
            Write-Info 'แนะนำ: aptstack stop ก่อน แล้วค่อย service install (dev ใช้ start/run ได้ตลอดโดยไม่ต้อง register)'
            Write-Host "  ยืนยันติดตั้งต่อโดยไม่ต้อง stop ตอนนี้? (พิมพ์ 'y')" -ForegroundColor Yellow
            $ans = Read-Host '  > '
            if ("$ans".Trim().ToLower() -ne 'y') { Write-Info 'ยกเลิก — ไปรัน aptstack stop แล้ว service install ใหม่'; break }
        }

        $binPath = "`"$exe`""
        Invoke-Sc @('create', $SvcName, 'binPath=', $binPath, 'start=', 'auto',
                    'DisplayName=', 'AptStack (PHP + MariaDB portable)') -Throw | Out-Null
        Invoke-Sc @('description', $SvcName, 'aptstack portable stack - run as service; managed by aptstack.ps1') -Throw | Out-Null
        # ถ้า service ตาย ให้ SCM เริ่มกลับ (stack เริ่มเองใหม่)
        Invoke-Sc @('failure', $SvcName, 'reset=', '86400', 'actions=', 'restart/10000/restart/30000/restart/60000') -Throw | Out-Null
        Invoke-Sc @('failureflag', $SvcName, '1') | Out-Null
        Invoke-Sc @('config', $SvcName, 'depend=', '') | Out-Null

        Write-Ok "ติดตั้งแล้ว: $SvcName"
        Write-Info "binPath: $binPath"
        Write-Info 'เริ่ม: aptstack service start'
        Write-Info 'ดู : aptstack service status'
        Write-Info 'ถอน: aptstack service uninstall'
        Write-Warn2 'ตอน start ครั้งแรก ให้ดู log ที่ logs\ ถ้า stack ไม่ขึ้น'
    }

    'uninstall' {
        if (-not (Test-Admin)) { Invoke-Elevated 'uninstall'; break }
        Write-Head 'ถอน Windows Service'
        if (-not (Get-ServiceObj)) { Write-Warn2 'ยังไม่ได้ติดตั้ง'; break }
        Invoke-Sc @('stop', $SvcName) | Out-Null
        Start-Sleep -Seconds 3
        Invoke-Sc @('delete', $SvcName) -Throw | Out-Null
        Write-Ok 'ถอนแล้ว — ไม่มีอะไรค้างในเครื่อง'
        Write-Info 'ตัว exe ยังอยู่ที่ bin\ (ลบได้ถ้าไม่ใช้)'
    }

    'start' {
        if (-not (Test-Admin)) { Invoke-Elevated 'start'; break }
        $s = Get-ServiceObj
        if (-not $s) { throw "ยังไม่ได้ติดตั้ง — รัน: aptstack service install" }
        if ($s.Status -eq 'Running') { Write-Ok 'service รันอยู่แล้ว'; break }
        Start-Service -Name $SvcName
        Start-Sleep -Seconds 5
        Write-Ok "start แล้ว ($((Get-ServiceObj).Status))"
        Write-Info 'เปิดดู: http://127.0.0.1:8077/app/'
    }

    'stop' {
        if (-not (Test-Admin)) { Invoke-Elevated 'stop'; break }
        $s = Get-ServiceObj
        if (-not $s) { Write-Warn2 'ยังไม่ได้ติดตั้ง'; break }
        if ($s.Status -ne 'Running') { Write-Ok 'service หยุดอยู่แล้ว'; break }
        Stop-Service -Name $SvcName -Force
        Start-Sleep -Seconds 5
        Write-Ok "stop แล้ว ($((Get-ServiceObj).Status))"
    }

    'restart' {
        & $PSCommandPath -Action stop
        Start-Sleep -Seconds 2
        & $PSCommandPath -Action start
    }

    'status' {
        Write-Head 'Windows Service'
        $s = Get-ServiceObj
        if (-not $s) { Write-Warn2 "ยังไม่ได้ติดตั้ง ($SvcName) — รัน: aptstack service install"; break }
        Write-Host "  $($s.DisplayName)" -ForegroundColor White
        Write-Host "  Status : $($s.Status)" -ForegroundColor $(if ($s.Status -eq 'Running') { 'Green' } else { 'Yellow' })
        Write-Host "  Start  : $($s.StartType)"
        Write-Host "  Exe    : $(if (Test-Path $Exe) { $Exe } else { '(ยังไม่ compile)' })"
        Invoke-Sc @('qc', $SvcName) | Write-Host -ForegroundColor DarkGray
    }
}
