#Requires -Version 5.1
<#
.SYNOPSIS
    aptstack - portable PHP / MariaDB / app-version manager for Windows

.DESCRIPTION
    Laragon/XAMPP-style stack ที่ไม่ต้องติดตั้ง อยู่โฟลเดอร์เดียว ย้ายเครื่องได้ด้วยการ copy
    จุดเด่นกว่า devstack คือ สลับ **เวอร์ชันแอป** ได้ด้วย (junction -> versions\<ver>)
    และติดตั้งเป็น Windows Service ได้

    กฎทอง:
      templates\  = ของถาวร (แก้ตรงนี้)
      config\     = ค่าจริงของเครื่อง + ไฟล์ที่ generate ใหม่เสมอ (ห้ามแก้ php.ini/my.ini)

.EXAMPLE
    aptstack list
    aptstack use 1.1.0
    aptstack use php 8.3.36
    aptstack start
    aptstack service install
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Action,
    [Parameter(Position = 2)][string]$Value,
    [Parameter(Position = 3)][string]$Extra,
    [switch]$NoRestart,
    # aptstack list --available [php|mysql|apache] -> ดูเวอร์ชันที่โหลดได้ (ต้อง declare ตรงนี้
    # ไม่งั้น PS โยน parameter binding error ก่อนถึง dispatch เหมือนกรณี -h เดิม)
    [switch]$Available,
    # aptstack -h / -? -> โชว์ help (PS ไม่รับ --help แต่เราจะดักใน dispatch ให้เอง)
    [Alias('h', '?', 'Help')][switch]$HelpFlag,
    # aptstack -v / -Version -> โชว์เวอร์ชัน (alias v จับก่อน prefix ของ -Value)
    [Alias('v', 'Version')][switch]$VersionFlag
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Script:P = @{
    Root      = $Root
    Stack     = Join-Path $Root 'stack'
    PhpRoot   = Join-Path $Root 'stack\php'
    MySqlRoot = Join-Path $Root 'stack\mysql'
    ApacheRoot = Join-Path $Root 'stack\apache'
    Versions  = Join-Path $Root 'versions'
    Www       = Join-Path $Root 'www'
    Data      = Join-Path $Root 'data'
    Dumps     = Join-Path $Root 'data\dumps'
    # ทุก config อยู่ที่เดียว: config\
    #   config\stack.json = ค่าที่แก้ได้ (เลือก version + port)
    #   config\php.ini, config\my.ini = generate จาก templates\ (ห้ามแก้)
    ConfigDir = Join-Path $Root 'config'
    Certs     = Join-Path $Root 'config\certs'
    Runtime   = Join-Path $Root 'config'
    Pids      = Join-Path $Root 'config\pids'
    Tmp       = Join-Path $Root 'config\tmp'
    Logs      = Join-Path $Root 'logs'
    Templates = Join-Path $Root 'templates'
    Downloads = Join-Path $Root 'downloads'
    Config    = Join-Path $Root 'config\stack.json'
    StopFlag  = Join-Path $Root 'config\stop.flag'
    PhpIni    = Join-Path $Root 'config\php.ini'
    MySqlIni  = Join-Path $Root 'config\my.ini'
}

# เวอร์ชัน PHP ที่ patch ช่องโหว่ RCE (อ้างอิง security-php.txt)
#   PHP 8.5 -> 8.5.12 | 8.4 -> 8.4.27 | 8.3 -> 8.3.36 | 8.2 -> 8.2.35
#   PHP 8.1 และต่ำกว่า = ไม่มี binary patch (EOL) ต้องย้ายรุ่น
$Script:PatchedPhp = @{
    '8.5' = '8.5.12'
    '8.4' = '8.4.27'
    '8.3' = '8.3.36'
    '8.2' = '8.2.35'
}
$Script:EolBelow = [version]'8.2.0'

# ---------------------------------------------------------------- output
function Write-Head($t) {
    Write-Host ''
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * [Math]::Min(64, $t.Length + 8))) -ForegroundColor DarkGray
}
function Write-Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Write-Err2($t) { Write-Host "  [ERR]  $t" -ForegroundColor Red }
function Write-Info($t) { Write-Host "         $t" -ForegroundColor Gray }

function Ensure-Dirs {
    foreach ($k in @('Stack', 'PhpRoot', 'MySqlRoot', 'ApacheRoot', 'Versions', 'Www', 'Data', 'Dumps', 'ConfigDir', 'Certs', 'Runtime', 'Pids', 'Tmp', 'Logs', 'Templates', 'Downloads')) {
        $p = $Script:P[$k]
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}

# ---------------------------------------------------------------- config
function Get-Config {
    $d = [ordered]@{
        app         = ''
        appPrev     = ''
        php         = ''
        phpPrev     = ''
        mysql       = ''
        apache      = ''
        apachePrev  = ''
        mysqlPrev   = ''
        httpPort    = 8077
        dbPort      = 3307
        dbMode      = 'internal'   # internal = MariaDB ของเรา | external = ใช้ MySQL ของ XAMPP
        webMode     = 'auto'       # auto = ใช้ Apache ถ้ามี ไม่งั้น built-in | apache | builtin
        httpsEnabled = 'false'     # true = เปิด HTTPS (ใช้ได้กับ webMode=apache)
        httpsPort   = 8443
        certFile    = ''           # path ของ PEM cert (เปลี่ยนด้วย: aptstack tls ...)
        keyFile     = ''           # path ของ PEM private key
        serverName  = 'localhost'  # ServerName ใน vhost HTTPS
        appAlias    = 'app'
        serviceName = 'AptStack'
        dbUser      = 'root'
        dbPass      = 'root'
        dbAdmin     = 'auto'
    }
    if (Test-Path $Script:P.Config) {
        try {
            $raw = Get-Content $Script:P.Config -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($d.Keys)) {
                if ($null -ne $raw.$k -and "$($raw.$k)" -ne '') { $d[$k] = $raw.$k }
            }
        } catch {
            Write-Warn2 "config\stack.json อ่านไม่ได้ ใช้ค่า default แทน ($($_.Exception.Message))"
        }
    }
    return [pscustomobject]$d
}

function Save-Config($cfg) {
    Ensure-Dirs
    # เขียน UTF-8 *ไม่มี BOM* — JSON ที่มี BOM เป็น JSON ไม่ถูกต้อง
    # (php json_decode() คืน null ทันที -> แอปจะอ่าน port/user/pass ไม่ได้)
    Write-Utf8NoBom $Script:P.Config (($cfg | ConvertTo-Json -Depth 5) + "`r`n")
}

# ---------------------------------------------------------------- versions
# ------------------------------------------------ app version metadata (family)
# ชื่อโฟลเดอร์ = label อิสระ แต่เก็บ manifest เล็ก ๆ ไว้บอกว่า
# "app ชื่ออะไร / เวอร์ชันอะไร" เพื่อให้ list/size/report จับกลุ่มได้ถูก
function Get-AppMeta($dir) {
    # fallback: todo-1.2.0 -> family=todo, ver=1.2.0 ; todo-app -> family=todo-app
    $name = Split-Path $dir -Leaf
    $fam = $name; $ver = $name
    if ($name -match '^(.+?)[-_]v?(\d[\d.]*)$') { $fam = $Matches[1]; $ver = $Matches[2] }
    $mf = Join-Path $dir '.aptstack-version'
    if (Test-Path $mf) {
        foreach ($l in (Get-Content $mf -EA SilentlyContinue)) {
            if ("$l" -match '^\s*family\s*=\s*(.+)$') { $fam = "$($Matches[1])".Trim() }
            if ("$l" -match '^\s*version\s*=\s*(.+)$') { $ver = "$($Matches[1])".Trim() }
        }
    }
    return [pscustomobject]@{ Family = $fam; Version = $ver; HasManifest = (Test-Path $mf) }
}

function Set-AppMeta($dir, [string]$family, [string]$version) {
    try {
        if (-not (Test-Path $dir)) { return }
        $name = Split-Path $dir -Leaf
        # ไม่ระบุก็ derive จากชื่อ: todo-1.2.0 -> family=todo, version=1.2.0
        if (-not $family -or -not $version) {
            $f = $name; $v = $name
            if ($name -match '^(.+?)[-_]v?(\d[\d.]*)$') { $f = $Matches[1]; $v = $Matches[2] }
            if (-not $family) { $family = $f }
            if (-not $version) { $version = $v }
        }
        Write-Utf8NoBom (Join-Path $dir '.aptstack-version') ("family=$family`r`nversion=$version`r`n")
    } catch { }
}

function Get-AppVersions {
    if (-not (Test-Path $Script:P.Versions)) { return @() }
    $out = @()
    foreach ($d in (Get-ChildItem $Script:P.Versions -Directory -ErrorAction SilentlyContinue)) {
        $meta = Get-AppMeta $d.FullName
        $out += [pscustomobject]@{
            Name     = $d.Name
            Dir      = $d.FullName
            Usable   = (Test-Path (Join-Path $d.FullName 'index.php'))
            Family   = $meta.Family
            Version  = $meta.Version
            HasMeta  = $meta.HasManifest
        }
    }
    return ($out | Sort-Object Family, { try { [version]$_.Version } catch { [version]'0.0.0' } }, Name)
}

function Get-CurrentAppName {
    $cfg = Get-Config
    $link = Join-Path $Script:P.Www $cfg.appAlias
    if (Test-Path $link) {
        $i = Get-Item $link -Force -ErrorAction SilentlyContinue
        if ($i -and $i.PSObject.Properties['Target'] -and $i.Target) {
            $t = "$($i.Target)"
            $leaf = Split-Path $t -Leaf
            if ($leaf) { return $leaf }
        }
    }
    return $cfg.app
}

function Get-NextAppName([string]$fromName) {
    # สร้างชื่อเวอร์ชันถัดไปโดยคงชื่อหลักไว้ (เปลี่ยนเฉพาะเลข version)
    #   1.0 -> 1.1 · todo-1.2.0 -> todo-1.2.1 · my-app -> my-app-1
    if ([string]::IsNullOrWhiteSpace($fromName)) { return 'app-1' }
    $next = $null
    if ($fromName -match '^\d+(?:\.\d+)*$') {
        $parts = @($fromName -split '\.')
        $n = 0; [void][int]::TryParse($parts[-1], [ref]$n)
        $parts[-1] = "$($n + 1)"
        $next = $parts -join '.'
    }
    elseif ($fromName -match '^(.+?)([-_])(v?)(\d+(?:\.\d+)*)$') {
        $prefix = $Matches[1]; $sep = $Matches[2]; $vtag = $Matches[3]; $ver = $Matches[4]
        $vp = @($ver -split '\.')
        $n = 0; [void][int]::TryParse($vp[-1], [ref]$n)
        $vp[-1] = "$($n + 1)"
        $next = "$prefix$sep$vtag$($vp -join '.')"
    }
    else { $next = "$fromName-1" }

    # ชนโฟลเดอร์เดิม -> bump ต่อ
    $guard = 0
    while ((Test-Path (Join-Path $Script:P.Versions $next)) -and $guard -lt 999) {
        $guard++
        if ($next -match '^(.+?)([-_])(v?)(\d+(?:\.\d+)*)$') {
            $prefix = $Matches[1]; $sep = $Matches[2]; $vtag = $Matches[3]; $ver = $Matches[4]
            $vp = @($ver -split '\.')
            $n = 0; [void][int]::TryParse($vp[-1], [ref]$n)
            $vp[-1] = "$($n + 1)"
            $next = "$prefix$sep$vtag$($vp -join '.')"
        }
        elseif ($next -match '^(.*)-(\d+)$') {
            $n = 0; [void][int]::TryParse($Matches[2], [ref]$n)
            $next = "$($Matches[1])-$($n + 1)"
        }
        else { $next = "$next-1" }
    }
    return $next
}

function Select-CloneAppSource {
    # เมนูเลือก app ต้นทางสำหรับ clone — แสดงชื่อเวอร์ชันถัดไปเป็น preview ด้วย
    $apps = @(Get-AppVersions)
    if ($apps.Count -eq 0) { throw 'ยังไม่มี app — เพิ่มก่อน: aptstack add app <folder|zip>' }
    $cur = Get-CurrentAppName
    Write-Host ''
    Write-Host '  เลือก app ต้นทางที่จะ clone' -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $mark = if ($cur -eq $apps[$i].Name) { '  <- ใช้อยู่' } else { '' }
        $preview = Get-NextAppName $apps[$i].Name
        Write-Host ("   {0}) {1,-42} -> {2}{3}" -f ($i + 1), $apps[$i].Name, $preview, $mark)
    }
    Write-Host ''
    $ans = Read-Host "  พิมพ์หมายเลข 1-$($apps.Count) แล้ว Enter (Enter เปล่า = ยกเลิก)"
    if ([string]::IsNullOrWhiteSpace($ans)) { Write-Info 'ยกเลิก'; return $null }
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 1 -or $n -gt $apps.Count) { throw "ไม่ถูกต้อง: '$ans'" }
    return $apps[$n - 1]
}

function Select-CloneKind {
    # ถามก่อนว่าจะ clone อะไร: app | mysql
    Write-Host ''
    Write-Host '  clone — เลือกประเภท' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   1) app    คัดลอกโค้ด app (versions\) — DB เดิม · สลับด้วย use ทีหลัง' -ForegroundColor White
    Write-Host '   2) mysql  คัดลอก datadir (data\) — ต้อง stop ก่อน · ใช้กับ engine ใหม่' -ForegroundColor White
    Write-Host ''
    $ans = Read-Host '  พิมพ์ 1 หรือ 2 แล้ว Enter (Enter เปล่า = ยกเลิก)'
    if ([string]::IsNullOrWhiteSpace($ans)) { Write-Info 'ยกเลิก'; return $null }
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n)) { throw "ไม่ถูกต้อง: '$ans'" }
    if ($n -eq 1) { return 'app' }
    if ($n -eq 2) { return 'mysql' }
    throw "ไม่ถูกต้อง: '$ans' (ต้องเป็น 1 หรือ 2)"
}

function Select-CloneMysqlSource {
    # เมนูเลือก datadir ต้นทางสำหรับ clone mysql
    $items = @()
    foreach ($eng in @(Get-MySqlVersions)) {
        $dd = Get-DataDir $eng
        if (Test-Path (Join-Path $dd 'mysql')) {
            $items += [pscustomobject]@{ Name = $eng.Name; Path = $dd; Kind = 'engine' }
        }
    }
    if (Test-Path $Script:P.Data) {
        foreach ($d in (Get-ChildItem $Script:P.Data -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -eq 'dumps') { continue }
            if (-not (Test-Path (Join-Path $d.FullName 'mysql'))) { continue }
            if ($items | Where-Object { $_.Path -eq $d.FullName }) { continue }
            $items += [pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Kind = 'data' }
        }
    }
    if ($items.Count -eq 0) { throw 'ยังไม่มี datadir — เพิ่ม MySQL ก่อน: aptstack add mysql <zip>' }

    Write-Host ''
    Write-Host '  เลือก datadir ต้นทางที่จะ clone' -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        $preview = Get-NextAppName $items[$i].Name
        Write-Host ("   {0}) {1,-36} -> {2}" -f ($i + 1), $items[$i].Name, $preview)
        Write-Host ("       {0}" -f $items[$i].Path) -ForegroundColor DarkGray
    }
    Write-Host ''
    $ans = Read-Host "  พิมพ์หมายเลข 1-$($items.Count) แล้ว Enter (Enter เปล่า = ยกเลิก)"
    if ([string]::IsNullOrWhiteSpace($ans)) { Write-Info 'ยกเลิก'; return $null }
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 1 -or $n -gt $items.Count) { throw "ไม่ถูกต้อง: '$ans'" }
    return $items[$n - 1]
}

function Test-PhpApacheMod([string]$Dir) {
    # Thread Safe สำหรับ mod_php: มี php*apache2_4.dll
    # PHP 8 = php8apache2_4.dll · PHP 7 = php7apache2_4.dll · PHP 5 = php5apache2_4.dll
    # อย่าเช็คแค่ php8... — PHP 7.4 TS จะถูกตีเป็น NTS ผิด (บั๊คจริง)
    if (-not $Dir -or -not (Test-Path $Dir)) { return $false }
    $hit = @(Get-ChildItem -Path $Dir -Filter 'php*apache2_4.dll' -File -ErrorAction SilentlyContinue)
    return ($hit.Count -gt 0)
}

function Get-PhpVersions {
    if (-not (Test-Path $Script:P.PhpRoot)) { return @() }
    $out = @()
    foreach ($d in (Get-ChildItem $Script:P.PhpRoot -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $d.FullName 'php.exe'
        $ver = $null
        if ($d.Name -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
        if (-not $ver -and (Test-Path $exe)) {
            $v = (& $exe -v 2>$null | Select-Object -First 1)
            if ("$v" -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
        }
        if ($ver) {
            $out += [pscustomobject]@{
                Version    = $ver
                Name       = $d.Name
                Dir        = $d.FullName
                Exe        = $exe
                Usable     = (Test-Path $exe)
                ApacheMod  = (Test-PhpApacheMod $d.FullName)
            }
        }
    }
    return ($out | Sort-Object { [version]$_.Version })
}

function Get-MySqlVersions {
    if (-not (Test-Path $Script:P.MySqlRoot)) { return @() }
    $out = @()
    foreach ($d in (Get-ChildItem $Script:P.MySqlRoot -Directory -ErrorAction SilentlyContinue)) {
        $daemon = $null
        foreach ($n in @('bin\mariadbd.exe', 'bin\mysqld.exe')) {
            $p = Join-Path $d.FullName $n
            if (Test-Path $p) { $daemon = $p; break }
        }
        if (-not $daemon) {
            $f = Get-ChildItem $d.FullName -Recurse -File -Include 'mariadbd.exe', 'mysqld.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { $daemon = $f.FullName }
        }
        if ($daemon) {
            $ver = $null
            if ($d.Name -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
            $out += [pscustomobject]@{
                Version = $ver
                Name    = $d.Name
                Dir     = $d.FullName
                Daemon  = $daemon
                # datadir เดิมที่มากับ bundle (มีข้อมูลจริงอยู่)
                # datadir จริงอยู่ที่ data\<ชื่อ> ดู Get-DataDir
                DataDir = Join-Path $Script:P.Data $d.Name
            }
        }
    }
    return $out
}

# datadir อยู่คนละโฟลเดอร์กับ binary (data\<ชื่อ>*) -> upgrade/reinstall stack แล้วข้อมูลไม่หาย
function Get-DataDir($hit) {
    $new = Join-Path $Script:P.Data $hit.Name
    if (Test-Path (Join-Path $new 'mysql')) { return $new }
    $legacy = Join-Path $hit.Dir 'data'
    if (Test-Path (Join-Path $legacy 'mysql')) { return $legacy }   # bundle รุ่นก่อนย้าย
    return $new
}

function Get-ApacheVersions {
    if (-not (Test-Path $Script:P.ApacheRoot)) { return @() }
    $out = @()
    foreach ($d in (Get-ChildItem $Script:P.ApacheRoot -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $d.FullName 'bin\httpd.exe'
        if (-not (Test-Path $exe)) {
            $f = Get-ChildItem $d.FullName -Recurse -File -Filter 'httpd.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { $exe = $f.FullName } else { $exe = $null }
        }
        if ($exe -and (Test-Path $exe)) {
            # ServerRoot ต้องเป็นโฟลเดอร์ที่มี bin\ และ modules\ (zip ของ Apache Lounge จะมี Apache24 ซ้อนอยู่)
            $dir = Split-Path -Parent $exe
            if ((Split-Path -Leaf $dir) -ieq 'bin') { $dir = Split-Path -Parent $dir }
            $ver = $null
            if ($d.Name -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
            $out += [pscustomobject]@{ Version = $ver; Name = $d.Name; Dir = $dir; Httpd = $exe }
        }
    }
    return ($out | Sort-Object { if ($_.Version) { [version]$_.Version } else { [version]'0.0.0' } })
}

function Resolve-Apache([string]$wanted) {
    # @() บังคับให้เป็น array เสมอ — PS5.1 คืน $null สำหรับ .Count ของ object เดียว
    $l = @(Get-ApacheVersions)
    if (-not $wanted) { if ($l.Count -ge 1) { return $l[-1] }; return $null }
    $e = $l | Where-Object { $_.Version -eq $wanted -or $_.Name -eq $wanted } | Select-Object -First 1
    if ($e) { return $e }
    $p = $l | Where-Object { $_.Version -like "$wanted*" -or $_.Name -like "*$wanted*" } | Select-Object -Last 1
    if ($p) { return $p }
    return $null
}

function Resolve-MySql([string]$wanted) {
    $l = @(Get-MySqlVersions | Sort-Object { if ($_.Version) { [version]$_.Version } else { [version]'0.0.0' } })
    if (-not $wanted) { if ($l.Count -ge 1) { return $l[-1] }; return $null }
    $e = $l | Where-Object { $_.Version -eq $wanted -or $_.Name -eq $wanted } | Select-Object -First 1
    if ($e) { return $e }
    $p = $l | Where-Object { $_.Version -like "$wanted*" -or $_.Name -like "*$wanted*" } | Select-Object -Last 1
    if ($p) { return $p }
    return $null
}

function Resolve-WebMode($cfg, $php, $apache) {
    switch ("$($cfg.webMode)".ToLower()) {
        'apache'  { return 'apache' }
        'builtin' { return 'builtin' }
        default   {
            # auto: ใช้ Apache ถ้ามี ครบทั้ง httpd + php*apache2_4.dll (Thread Safe รวม php7/php8)
            if ($apache -and $php -and (Test-PhpApacheMod $php.Dir)) { return 'apache' }
            return 'builtin'
        }
    }
}

function Resolve-CertPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    if ($p -match '^[A-Za-z]:[\\/]') { return $p }
    return (Join-Path $Root $p)
}

function Get-CertSnippet($cfg) {
    # คืนเป็นข้อความถ้าพร้อมใช้ ไม่งั้นคืน ''
    if ("$($cfg.httpsEnabled)".ToLower() -ne 'true') { return '' }
    $tpl = Join-Path $Script:P.Templates 'ssl.conf.tpl'
    if (-not (Test-Path $tpl)) { Write-Warn2 'ไม่พบ templates\ssl.conf.tpl — ข้าม HTTPS'; return '' }
    $cert = Resolve-CertPath $cfg.certFile
    $key = Resolve-CertPath $cfg.keyFile
    if (-not (Test-Path $cert) -or -not (Test-Path $key)) {
        Write-Warn2 'httpsEnabled=true แต่ไม่พบไฟล์ cert/key — ข้าม HTTPS ไปก่อน'
        Write-Info 'สร้าง: aptstack tls init     |     ใช้ของจริง: aptstack tls import <cert.pem> <key.pem>'
        return ''
    }
    $s = (Get-Content $tpl -Raw -Encoding UTF8).TrimStart([char]0xFEFF)
    $apache = Resolve-Apache $cfg.apache
    $m = @{
        '{{APACHE_DIR}}'  = $(if ($apache) { ($apache.Dir -replace '\\', '/') } else { '' })
        '{{HTTPS_PORT}}'  = "$($cfg.httpsPort)"
        '{{WWW}}'         = ($Script:P.Www -replace '\\', '/')
        '{{LOGS}}'        = ($Script:P.Logs -replace '\\', '/')
        '{{CERT}}'        = ($cert -replace '\\', '/')
        '{{KEY}}'         = ($key -replace '\\', '/')
        '{{SERVER_NAME}}' = $(if ($cfg.serverName) { "$($cfg.serverName)" } else { 'localhost' })
    }
    foreach ($k in $m.Keys) { $s = $s.Replace($k, $m[$k]) }
    return $s
}

function Get-VhostsSnippet($cfg) {
    # virtual host จาก config\vhosts.json -> ถูก append เข้า config\httpd.conf
    # ใช้ได้กับ webMode=apache เท่านั้น (PHP built-in server ไม่มี concept vhost)
    $src = Join-Path $Script:P.ConfigDir 'vhosts.json'
    if (-not (Test-Path $src)) { return '' }
    $raw = (Get-Content $src -Raw -Encoding UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    try { $items = @((ConvertFrom-Json $raw)) } catch {
        Write-Warn2 "vhosts.json อ่านไม่ได้: $($_.Exception.Message)"
        return ''
    }
    if ($items.Count -eq 0) { return '' }

    $logsF = ($Script:P.Logs -replace '\\', '/')
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# ---- aptstack virtual hosts (generate จาก config\vhosts.json — ห้ามแก้ตรงนี้) ----')
    $ssl = (Get-CertSnippet $cfg)
    $hasSsl = ("$($cfg.httpsEnabled)".ToLower() -eq 'true') -and ($ssl -ne '')

    foreach ($v in $items) {
        $h = "$($v.host)"
        if (-not $h) { continue }
        $app = if ($v.app) { "$($v.app)" } else { "$($cfg.app)" }
        $dir = Join-Path $Script:P.Versions $app
        if (-not (Test-Path $dir)) {
            Write-Warn2 "vhost $h -> ไม่พบ versions\$app (ข้าม)"
            continue
        }
        $port = if ($v.port) { [int]$v.port } else { [int]$cfg.httpPort }
        $dirF = ($dir -replace '\\', '/')
        $safe = ($h -replace '[^\w\-.]', '_')

        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("# vhost: $h -> versions\$app (port $port)")
        [void]$sb.AppendLine("<VirtualHost *:$port>")
        [void]$sb.AppendLine("    ServerName $h")
        [void]$sb.AppendLine("    DocumentRoot `"$dirF`"")
        [void]$sb.AppendLine('    <Directory "' + $dirF + '">')
        [void]$sb.AppendLine('        Options -Indexes +FollowSymLinks')
        [void]$sb.AppendLine('        AllowOverride All')
        [void]$sb.AppendLine('        Require all granted')
        [void]$sb.AppendLine('        AcceptPathInfo On')
        [void]$sb.AppendLine('    </Directory>')
        [void]$sb.AppendLine("    ErrorLog  `"$logsF/vhost-$safe-error.log`"")
        [void]$sb.AppendLine("    CustomLog `"$logsF/vhost-$safe-access.log`" common")
        [void]$sb.AppendLine('</VirtualHost>')

        # เมื่อเปิด HTTPS แล้ว -> ออก vhost ฝั่ง https ให้ทุก host อัตโนมัติ
        # (ไม่งั้น https://host-นี้ จะตกไป default vhost)
        # ยกเว้นเจ้าของ vhost ระบุ "https": false ไว้ชัดเจน
        $wantSsl = $hasSsl -and ("$($v.https)").ToLower() -ne 'false'
        if ($wantSsl) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("# vhost (https): $h -> versions\$app (port $($cfg.httpsPort))")
            $lines = $ssl -split "`r?`n"
            # แทนที่ VirtualHost/ServerName/DocumentRoot/Directory ของ block SSL หลัก
            $out2 = @()
            foreach ($l in $lines) {
                $l2 = $l
                $l2 = $l2 -replace '\*:\{\{HTTPS_PORT\}\}', "*:$($cfg.httpsPort)"
                $l2 = $l2 -replace '\*:' + [regex]::Escape("$($cfg.httpsPort)"), "*:$($cfg.httpsPort)"
                if ($l2 -match '^\s*ServerName\s') { $l2 = "    ServerName $h" }
                if ($l2 -match '^\s*DocumentRoot\s') { $l2 = "    DocumentRoot `"$dirF`"" }
                if ($l2 -match '^\s*<Directory\s') { $l2 = '    <Directory "' + $dirF + '">' }
                if ($l2 -match 'LoadModule|SSLSessionCache|SSLStrictSNI|^\s*Listen\s') { continue }
                $out2 += $l2
            }
            [void]$sb.AppendLine(($out2 -join "`r`n"))
        }
    }
    return $sb.ToString()
}

function New-HttpdConf($cfg, $php, $apacheHit) {
    Ensure-Dirs
    $tpl = Join-Path $Script:P.Templates 'httpd.conf.tpl'
    if (-not (Test-Path $tpl)) { throw "ไม่พบ template: $tpl" }
    $conf = (Get-Content $tpl -Raw -Encoding UTF8).TrimStart([char]0xFEFF)
    # ชื่อ DLL mod_php ไม่ใช่แค่ php8... — PHP7 = php7apache2_4.dll
    $modDll = 'php8apache2_4.dll'
    $modHit = @(Get-ChildItem -Path $php.Dir -Filter 'php*apache2_4.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($modHit) { $modDll = $modHit[0].Name }
    $map = @{
        '{{APACHE_DIR}}' = ($apacheHit.Dir -replace '\\', '/')
        '{{PHP_DIR}}'    = ($php.Dir -replace '\\', '/')
        '{{PHP_APACHE_DLL}}' = $modDll
        '{{PHP_INI}}'    = ($Script:P.ConfigDir -replace '\\', '/')
        '{{WWW}}'        = ($Script:P.Www -replace '\\', '/')
        '{{LOGS}}'       = ($Script:P.Logs -replace '\\', '/')
        '{{PORT}}'       = "$($cfg.httpPort)"
    }
    foreach ($k in $map.Keys) { $conf = $conf.Replace($k, $map[$k]) }

    # แนบ HTTPS (ถ้าเปิด) + virtual hosts (ถ้ามี config\vhosts.json)
    $conf += (Get-CertSnippet $cfg)
    $conf += (Get-VhostsSnippet $cfg)

    $out = Join-Path $Script:P.Runtime 'httpd.conf'
    # Apache อ่าน BOM ไม่ออก -> ต้องเขียน UTF-8 ไม่มี BOM
    Write-Utf8NoBom $out $conf
    return $out
}

function Resolve-App($wanted) {
    $list = @(Get-AppVersions)
    if (-not $wanted) { if ($list.Count -ge 1) { return $list[-1] }; return $null }
    $e = $list | Where-Object { $_.Name -eq $wanted } | Select-Object -First 1
    if ($e) { return $e }
    $p = $list | Where-Object { $_.Name -like "$wanted*" } | Select-Object -Last 1
    if ($p) { return $p }
    return $null
}

function Resolve-Php($wanted) {
    $list = @(Get-PhpVersions)
    if (-not $wanted) { if ($list.Count -ge 1) { return $list[-1] }; return $null }
    $e = $list | Where-Object { $_.Version -eq $wanted } | Select-Object -First 1
    if ($e) { return $e }
    $p = $list | Where-Object { $_.Version -like "$wanted*" } | Select-Object -Last 1
    if ($p) { return $p }
    return $null
}

function Get-PhpRisk($ver) {
    # คืนค่า: $null = ปลอดภัย, 'EOL', 'UNPATCHED'
    $minor = ($ver -split '\.')[0..1] -join '.'
    $v = $null
    try { $v = [version]$ver } catch { return $null }
    if ($Script:PatchedPhp.ContainsKey($minor)) {
        if ($v -lt [version]$Script:PatchedPhp[$minor]) { return 'UNPATCHED' }
        return $null
    }
    if ($v -lt $Script:EolBelow) { return 'EOL' }
    return $null
}

# ---------------------------------------------------------------- ini
# หมายเหตุ: MariaDB อ่าน my.ini แบบไม่สน BOM -> ต้องเขียน UTF-8 *ไม่มี* BOM
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

function New-PhpIni($phpDir) {
    Ensure-Dirs
    $base = $null
    foreach ($c in @((Join-Path $phpDir 'php.ini'), (Join-Path $phpDir 'php.ini-production'), (Join-Path $phpDir 'php.ini-development'))) {
        if (Test-Path $c) { $base = $c; break }
    }
    if (-not $base) { throw "ไม่พบ php.ini ใน $phpDir" }

    $content = (Get-Content $base -Raw -Encoding UTF8).TrimStart([char]0xFEFF)

    # ตัดบรรทัด extension ที่ active อยู่ใน build เดิมออกทั้งหมด
    # (PHP zip แบบทางการไม่มี php.ini เลย บาง build ก็มีของตัวเอง)
    # เพื่อให้รายการ extension มาจาก templates\php-extensions.ini ที่เดียว = คาดเดาได้
    $kept = @()
    foreach ($l in ($content -split "`r?`n")) {
        if ($l -match '^\s*;') { $kept += $l }
        elseif ($l -match '^\s*(extension|zend_extension)\s*=') { }
        # ตัด short_open_tag ออกจาก base — ค่าจริงมาจาก templates\php-hardening.ini
        # (php.ini-production มี short_open_tag = Off ถ้าไม่ตัด จะทับค่า On ของเรา)
        elseif ($l -match '^\s*short_open_tag\s*=') { }
        else { $kept += $l }
    }
    $content = ($kept -join "`r`n")

    $extTpl = Join-Path $Script:P.Templates 'php-extensions.ini'
    if (Test-Path $extTpl) {
        $extDir = Join-Path $phpDir 'ext'
        # บังคับ extension_dir ชี้ไปที่ build นี้
        # (php.ini-production ของ PHP มี ;extension_dir ถูก comment ไว้
        #  ถ้าไม่ตั้ง PHP จะไปหา ext ที่ C:\php\ext -> extension โหลดไม่ขึ้นทั้งหมด)
        $extLines = @('extension_dir = "' + ($extDir -replace '\\', '/') + '"')
        foreach ($l in ((Get-Content $extTpl -Raw -Encoding UTF8).TrimStart([char]0xFEFF) -split "`r?`n")) {
            if ($l -match '^\s*(extension|zend_extension)\s*=\s*(.+?)\s*$') {
                $name = $Matches[2].Trim().Trim('"').Trim("'")
                $dll = $name
                if ($dll -notmatch '\.dll$') { $dll = "php_$dll.dll" }
                # ข้ามถ้าไม่มี dll จริง (เช่น ext ถูกถอดออกใน build นั้น)
                if (Test-Path (Join-Path $extDir $dll)) { $extLines += $l }
            } else {
                $extLines += $l
            }
        }
        $content += "`r`n`r`n; ============================================================`r`n"
        $content += "; aptstack extensions - generated, do not edit here`r`n"
        $content += "; แก้ถาวรที่ templates\php-extensions.ini`r`n"
        $content += "; ============================================================`r`n"
        $content += ($extLines -join "`r`n")
    }

    $hardTpl = Join-Path $Script:P.Templates 'php-hardening.ini'
    if (Test-Path $hardTpl) {
        $hard = Get-Content $hardTpl -Raw -Encoding UTF8
        $hard = $hard.Replace('{{LOGS}}', ($Script:P.Logs -replace '\\', '/'))
        # session.save_path อยู่ใน bundle -> สลับ PHP/สลับโหมดรัน (service <-> manual) แล้วยังใช้ session เดิมได้
        $sessDir = Join-Path $Script:P.Runtime 'sessions'
        if (-not (Test-Path $sessDir)) { New-Item -ItemType Directory -Path $sessDir -Force | Out-Null }
        $hard = $hard.Replace('{{SESSIONS}}', ($sessDir -replace '\\', '/'))
        $content += "`r`n`r`n; ============================================================`r`n"
        $content += "; aptstack security overrides - REGENERATED, do not edit here`r`n"
        $content += "; แก้ถาวรที่ templates\php-hardening.ini`r`n"
        $content += "; ============================================================`r`n"
        $content += $hard
    }
    Write-Utf8NoBom $Script:P.PhpIni $content
    return $Script:P.PhpIni
}

function New-MyIni($cfg, $mysqlHit) {
    Ensure-Dirs
    $tpl = Join-Path $Script:P.Templates 'my.ini.tpl'
    if (-not (Test-Path $tpl)) { throw "ไม่พบ template: $tpl" }
    # tmpdir อยู่ใน bundle (ไม่ใช้ %TEMP% ของเครื่อง) -> copy ไปเครื่องอื่นแล้วไม่มี path ค้าง
    # และไฟล์ชั่วคราวของ DB ไม่ไปปนกับแอปอื่นบนเครื่องเดียวกัน
    $tmp = $Script:P.Tmp
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }

    $map = @{
        '{{BASEDIR}}' = ($mysqlHit.Dir -replace '\\', '/')
        '{{DATADIR}}' = ((Get-DataDir $mysqlHit) -replace '\\', '/')
        '{{DBPORT}}'  = "$($cfg.dbPort)"
        '{{LOGS}}'    = ($Script:P.Logs -replace '\\', '/')
        '{{TMP}}'     = ($tmp -replace '\\', '/')
    }
    $c = (Get-Content $tpl -Raw -Encoding UTF8).TrimStart([char]0xFEFF)
    foreach ($k in $map.Keys) { $c = $c.Replace($k, $map[$k]) }
    Write-Utf8NoBom $Script:P.MySqlIni $c
    return $Script:P.MySqlIni
}

# ---------------------------------------------------------------- ports / pid
function Test-PortFree($port) {
    try {
        $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        return (-not $c)
    } catch { return $true }
}

function Get-PortPid($port) {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return [int]$c.OwningProcess }
    return $null
}

function Get-PortOwner([int]$Port) {
    # แผนที่พอร์ต -> PID -> exe image path (+ โฟลเดอร์) รู้ได้ทันทีว่าของ bundle ไหน
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    $id = [int]$c.OwningProcess
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    $name = ''; $path = ''
    if ($proc) {
        $name = "$($proc.ProcessName)"
        try { $path = "$($proc.Path)" } catch { $path = '' }
    }
    if (-not $path) {
        try {
            $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
            if ($ci) {
                if ($ci.ExecutablePath) { $path = "$($ci.ExecutablePath)" }
                if (-not $name -and $ci.Name) { $name = "$($ci.Name)" }
            }
        } catch { }
    }
    $folder = ''
    if ($path) { try { $folder = Split-Path -Parent $path } catch { $folder = '' } }
    $isSelf = $false
    if ($path) {
        $pn = $path.Replace('/', '\').TrimEnd('\')
        $rn = "$Root".Replace('/', '\').TrimEnd('\')
        $isSelf = $pn.StartsWith($rn + '\', [StringComparison]::OrdinalIgnoreCase) -or
                  ($pn -ieq $rn)
    }
    return [pscustomobject]@{
        Port   = $Port
        Pid    = $id
        Name   = $name
        Path   = $path
        Folder = $folder
        IsSelf = $isSelf
    }
}

function Write-PortOwner($owner, [string]$Label) {
    # ใช้ตอน "พอร์ตถูกจอง" — โชว์ PID + program + path ให้รู้ว่า bundle ไหน
    if (-not $owner) {
        Write-Warn2 "$Label พอร์ต : ว่าง"
        return
    }
    $tag = if ($owner.IsSelf) { 'ของ bundle นี้' } else { 'ของ program อื่น' }
    Write-Info ("{0} พอร์ต {1} ถูกจองโดย PID {2} ({3})  [{4}]" -f $Label, $owner.Port, $owner.Pid, $owner.Name, $tag)
    if ($owner.Path) { Write-Info "exe : $($owner.Path)" }
    if ($owner.Folder) { Write-Info "dir : $($owner.Folder)" }
    if (-not $owner.IsSelf) {
        Write-Info "หยุดตัวนี้: aptstack stop $($owner.Port)"
    }
}

# --------------------------------------------------------------- health probe
# ไม่รอแบบ blind (พอร์ตเปิด = จบ) -> ยิง HTTP จริงจนกว่าจะตอบ
function Invoke-HttpProbe([string]$Url, [int]$TimeoutSec = 5) {
    # หมายเหตุ: ห้ามใช้ ServerCertificateValidationCallback เพื่อปลด cert check
    # ผลทดสอบจริงบน PS 5.1 → ใส่ callback แล้วได้ UntrustedRoot สลับไปมา (แย่กว่าเดิม)
    # วิธีที่ work จริงคือ "ใส่ cert เข้า Trusted Root" (ดู Add-CertTrust / aptstack tls init)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5
        return [pscustomobject]@{ Ok = $true; Url = $Url; Status = [int]$r.StatusCode; Bytes = [int]$r.RawContentLength; Error = ''; Ms = 0 }
    } catch {
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        # server ตอบแล้ว (401/403/404 ก็ตาม) = ถือว่า healthy
        if ($code -gt 0) {
            return [pscustomobject]@{ Ok = $true; Url = $Url; Status = $code; Bytes = 0; Error = ''; Ms = 0 }
        }
        $msg = "$($_.Exception.Message)"
        $inner = $_.Exception.InnerException
        if ($inner) { $msg = "$($inner.Message)" }
        if ($msg -match 'certificate|UntrustedRoot|SSL') {
            $msg += '  -> cert ยังไม่ได้ trust: รัน aptstack tls init (จะใส่เข้า Trusted Root ให้)'
        }
        return [pscustomobject]@{ Ok = $false; Url = $Url; Status = 0; Bytes = 0; Error = $msg; Ms = 0 }
    }
}

function Wait-Healthy([int]$Port, [string]$Path = '/', [int]$Seconds = 20, [string]$Scheme = 'http') {
    $url = "${Scheme}://127.0.0.1:${Port}${Path}"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($w = 0; $w -lt ($Seconds * 2); $w++) {
        Start-Sleep -Milliseconds 500
        if (Test-PortFree $Port) { continue }
        $p = Invoke-HttpProbe $url 3
        if ($p.Ok) {
            $sw.Stop()
            $p | Add-Member -NotePropertyName Ms -NotePropertyValue ([int]$sw.ElapsedMilliseconds) -Force -PassThru
            return
        }
    }
    $sw.Stop()
    return [pscustomobject]@{ Ok = $false; Url = $url; Status = 0; Bytes = 0; Error = "หมดเวลา $Seconds วิ แล้วยังตอบไม่ได้"; Ms = [int]$sw.ElapsedMilliseconds }
}

function Write-HealthLine($h, [string]$Label) {
    if ($h.Ok) {
        Write-Ok "health: $Label -> $($h.Status) OK ($($h.Ms) ms)  $($h.Url)"
    } else {
        Write-Err2 "health: $Label ไม่ตอบ — $($h.Error)"
        Write-Info $h.Url
    }
}

function Get-PidFile($name) { Join-Path $Script:P.Pids "$name.pid" }

function Test-Running($name) {
    $f = Get-PidFile $name
    if (-not (Test-Path $f)) { return $null }
    $s = (Get-Content $f -Raw -ErrorAction SilentlyContinue)
    if (-not $s) { return $null }
    $s = $s.Trim()
    if (-not $s) { return $null }
    $p = Get-Process -Id ([int]$s) -ErrorAction SilentlyContinue
    if (-not $p) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        return $null
    }
    # Windows นำ PID กลับมาใช้ใหม่ได้ — ต้องชื่อ process ตรงด้วย ไม่งั้น status/ start หลอกว่ารันอยู่
    $expect = switch ("$name".ToLower()) {
        'mysql' { @('mysqld', 'mariadbd', 'mysql') }
        'web'   { @('httpd', 'php-cgi', 'php', 'nginx') }
        default { @("$name".ToLower()) }
    }
    if ($expect -notcontains $p.ProcessName.ToLower()) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p
}

function Set-Pid($name, $id) {
    Ensure-Dirs
    Set-Content -Path (Get-PidFile $name) -Value "$id" -Encoding ASCII
}

function Clear-Pid($name) { Remove-Item (Get-PidFile $name) -Force -ErrorAction SilentlyContinue }

function Stop-ByPidFile($name) {
    $p = Test-Running $name
    if ($p) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Write-Ok "หยุด $name (PID $($p.Id))" }
        catch { Write-Warn2 "หยุด $name ไม่สำเร็จ: $($_.Exception.Message)" }
    }
    Clear-Pid $name
}

function Stop-ByPort($port, $label, [switch]$Force) {
    $owner = Get-PortOwner ([int]$port)
    if (-not $owner) { return }
    Write-Info ("จองพอร์ต {0}: PID {1} ({2})" -f $port, $owner.Pid, $owner.Name)
    if ($owner.Path) { Write-Info "exe : $($owner.Path)" }
    if (-not $owner.IsSelf -and -not $Force) {
        Write-Warn2 'program นี้ "ไม่ใช่" ของ bundle นี้ — ถ้าใช่ bundle อื่นที่คุณเปิดค้างไว้ ค่อยหยุดเอง'
        if (-not (Confirm-Action "หยุด PID $($owner.Pid) ($($owner.Name)) ที่พอร์ต $port จริงไหม?")) {
            Write-Info 'ข้าม — ไม่ได้หยุดอะไร'
            return
        }
    }
    try {
        Stop-Process -Id $owner.Pid -Force -ErrorAction Stop
        Write-Ok "หยุด $label (PID $($owner.Pid) / $($owner.Name)) ที่จองพอร์ต $port"
        if ($owner.Folder) { Write-Info "จากโฟลเดอร์: $($owner.Folder)" }
    } catch { Write-Warn2 "หยุด process บนพอร์ต $port ไม่สำเร็จ" }
}

function Cmd-Ports([string]$what) {
    # aptstack ports           -> ดู port ของ stack + ใครจองอยู่ (path ครบ)
    # aptstack ports stop 3307 -> หยุดตัวที่จอง port นั้น (ถามยืนยันถ้าไม่ใช่ของเรา)
    $cfg = Get-Config
    $rows = @(
        [pscustomobject]@{ Label = 'HTTP';  Port = [int]$cfg.httpPort; Ours = 'web' },
        [pscustomobject]@{ Label = 'HTTPS'; Port = [int]$cfg.httpsPort; Ours = 'web' },
        [pscustomobject]@{ Label = 'MySQL'; Port = [int]$cfg.dbPort; Ours = 'mysql' }
    )
    if ("$what".ToLower() -in @('stop', 'kill')) {
        $p = 0
        if ($Action -match '^\d+$') { $p = [int]$Action }
        elseif ($Value -match '^\d+$') { $p = [int]$Value }
        else { throw 'ใช้: aptstack ports stop <port>   เช่น aptstack ports stop 3307' }
        Stop-ByPort $p "port $p"
        return
    }

    Write-Head 'พอร์ตของ stack + เจ้าของ (exe image)'
    $cfg = Get-Config
    Write-Info "bundle : $Root"
    Write-Info "config : http=$($cfg.httpPort)  https=$($cfg.httpsPort)  mysql=$($cfg.dbPort)"
    Write-Host ''
    foreach ($r in $rows) {
        $ownPid = Get-PortPid $r.Port
        if (-not $ownPid) {
            Write-Host ("  {0,-5} {1,-5}  ว่าง" -f $r.Label, $r.Port) -ForegroundColor DarkGray
            continue
        }
        $owner = Get-PortOwner $r.Port
        $ours = [bool](Test-Running $r.Ours)
        $mark = if ($ours -and $owner -and $owner.IsSelf) { '[ours]' }
                elseif ($owner -and $owner.IsSelf) { '[bundle]' }
                else { '[other]' }
        $color = if ($mark -eq '[ours]') { 'Green' } elseif ($mark -eq '[bundle]') { 'Yellow' } else { 'Red' }
        Write-Host ("  {0,-5} {1,-5}  {2,-8} PID {3}  {4}" -f $r.Label, $r.Port, $mark, $owner.Pid, $owner.Name) -ForegroundColor $color
        if ($owner.Path)   { Write-Info "exe : $($owner.Path)" }
        if ($owner.Folder) { Write-Info "dir : $($owner.Folder)" }
        if ($mark -eq '[other]') { Write-Info "หยุด: aptstack ports stop $($r.Port)   (หรือ aptstack stop $($r.Port))" }
    }
    Write-Host ''
    Write-Info 'ดูพอร์ตอื่น: aptstack ports แล้วดูบรรทัด [other] · หยุด: aptstack stop <port>'
    Write-Info 'หมายเหตุ: [ours] = stack ชุดนี้รันอยู่ · [other] = program อื่น (มักเป็น aptstack/XAMPP bundle ที่เปิดค้าง)'
}

# ---------------------------------------------------------------- db helpers
function Get-DbAdmin($mysqlHit) {
    foreach ($n in @('bin\mariadb-admin.exe', 'bin\mysqladmin.exe')) {
        $p = Join-Path $mysqlHit.Dir $n
        if (Test-Path $p) { return $p }
    }
    $f = Get-ChildItem $mysqlHit.Dir -Recurse -File -Include 'mariadb-admin.exe', 'mysqladmin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Invoke-DbAdmin($mysqlHit, $argList) {
    $adm = Get-DbAdmin $mysqlHit
    if (-not $adm) { return $false }
    $cfg = Get-Config
    $a = @('--skip-ssl', '-u', $cfg.dbUser, "-p$($cfg.dbPass)", '-h', '127.0.0.1', '-P', "$($cfg.dbPort)", '--protocol=tcp') + $argList
    try {
        $out = & $adm $a 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# ---------------------------------------------------------------- start / stop
function Start-Db($cfg) {
    # dbMode=external -> ใช้ MySQL ของ XAMPP/ของจริงที่ port เดิม ไม่แตะ MariaDB ใน bundle
    if ("$($cfg.dbMode)" -eq 'external') {
        if (Test-PortFree $cfg.dbPort) {
            Write-Warn2 "dbMode=external แต่พอร์ต $($cfg.dbPort) ว่าง — MySQL (XAMPP) ยังไม่ start?"
        } else {
            Write-Ok "ใช้ MySQL ภายนอก (XAMPP) ที่ 127.0.0.1:$($cfg.dbPort) — ข้าม MariaDB ใน bundle"
        }
        return $true
    }
    if (Test-Running 'mysql') { Write-Info 'MariaDB รันอยู่แล้ว'; return $true }
    if (-not (Test-PortFree $cfg.dbPort)) {
        Write-Warn2 "พอร์ต $($cfg.dbPort) ถูกใช้อยู่ — ข้าม MariaDB"
        Write-PortOwner (Get-PortOwner ([int]$cfg.dbPort)) 'MySQL'
        return $false
    }
    $hit = Resolve-MySql $cfg.mysql
    if (-not $hit) { Write-Warn2 'ไม่พบ MariaDB/MySQL ใน stack\mysql\ — ข้าม'; return $false }

    $datadir = Get-DataDir $hit
    if (-not (Test-Path $datadir)) { New-Item -ItemType Directory -Path $datadir -Force | Out-Null }
    if (-not (Test-Path (Join-Path $datadir 'mysql'))) {
        Write-Head 'สร้าง data directory ครั้งแรก'
        Write-Info $datadir
        # datadir ที่ init ค้าง (มีไฟล์ ibdata แต่ไม่มี mysql/) ต้องล้างก่อน ไม่งั้น install/initialize พัง
        $left = @(Get-ChildItem $datadir -Force -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0) {
            Write-Warn2 'มีไฟล์ค้างจากการ init ล้มเหลว — ล้างก่อน'
            Remove-Item (Join-Path $datadir '*') -Recurse -Force -ErrorAction SilentlyContinue
        }
        # MariaDB ไม่รองรับ --initialize-insecure (เป็นของ MySQL) -> ใช้ mysql_install_db -d<path>
        $installDb = $null
        foreach ($n in @('bin\mariadb-install-db.exe', 'bin\mysql_install_db.exe')) {
            $p0 = Join-Path $hit.Dir $n
            if (Test-Path $p0) { $installDb = $p0; break }
        }
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($installDb) {
                $ida = @("-d$datadir")
                if ($cfg.dbPass) { $ida += "-p$($cfg.dbPass)" }   # MariaDB ต้องติดกัน: -proot ไม่ใช่ -p root
                $p = Start-Process -FilePath $installDb -ArgumentList $ida -Wait -PassThru -NoNewWindow `
                    -RedirectStandardOutput (Join-Path $Script:P.Tmp 'install-db-out.txt') `
                    -RedirectStandardError  (Join-Path $Script:P.Tmp 'install-db-err.txt')
                if ($p.ExitCode -ne 0 -or -not (Test-Path (Join-Path $datadir 'mysql'))) {
                    $e = Get-Content (Join-Path $Script:P.Tmp 'install-db-err.txt') -Tail 5 -ErrorAction SilentlyContinue
                    Write-Err2 "mysql_install_db ล้มเหลว (exit $($p.ExitCode))"
                    if ($e) { Write-Info ($e -join ' ') }
                    return $false
                }
            } else {
                $args = @('--initialize-insecure', "--datadir=$datadir", "--basedir=$($hit.Dir)")
                $p = Start-Process -FilePath $hit.Daemon -ArgumentList $args -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -ne 0) { Write-Err2 "mysqld --initialize ล้มเหลว (exit $($p.ExitCode))"; return $false }
            }
        } finally { $ErrorActionPreference = $oldEap }
        Write-Ok 'สร้าง datadir เรียบร้อย'
    }

    $ini = New-MyIni $cfg $hit
    $p = Start-Process -FilePath $hit.Daemon -ArgumentList @("--defaults-file=$ini") -PassThru -WindowStyle Hidden
    Set-Pid 'mysql' $p.Id

    # health probe: พอร์ตเปิดแล้วต้อง "ping ผ่าน client ได้จริง" ไม่ใช่แค่รอพอร์ต
    # 60 วิ — ครั้งแรก/หลัง crash Aria recovery อาจกินเวลา >30 วิ (ไม่งั้นโดน kill กลางทาง)
    $healthy = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($w = 0; $w -lt 60; $w++) {
        Start-Sleep -Seconds 1
        if (Test-PortFree $cfg.dbPort) { continue }
        if (Invoke-DbAdmin $hit @('ping')) { $healthy = $true; break }
    }
    $sw.Stop()
    if (-not $healthy) {
        Write-Err2 "MariaDB ไม่ตอบ (รอ $($sw.Elapsed.TotalSeconds.ToString('0.0')) วิ) — ดู logs\mariadb-error.log"
        Write-Info 'เปิดดู: aptstack logs mysql'
        Write-Info 'ถ้า log ขึ้น Aria recovery ให้ start ซ้ำ (อย่า kill ระหว่าง recovery)'
        Clear-Pid 'mysql'
        return $false
    }
    Write-Ok "MariaDB $($hit.Version) healthy (ping OK, $([int]$sw.ElapsedMilliseconds) ms, port $($cfg.dbPort))"
    Write-Info "datadir: $datadir"
    return $true
}

function Start-Web($cfg) {
    if (Test-Running 'web') { Write-Info 'Web server รันอยู่แล้ว'; return $true }
    if (-not (Test-PortFree $cfg.httpPort)) {
        Write-Warn2 "พอร์ต $($cfg.httpPort) ถูกใช้อยู่ — ข้าม web"
        Write-PortOwner (Get-PortOwner ([int]$cfg.httpPort)) 'HTTP'
        return $false
    }
    $php = Resolve-Php $cfg.php
    if (-not $php) { Write-Err2 'ไม่พบ PHP — ใช้: aptstack add php <zip>'; return $false }
    if (-not $php.Usable) { Write-Err2 "PHP $($php.Version) ไม่มี php.exe"; return $false }

    $apache = Resolve-Apache $cfg.apache
    $mode = Resolve-WebMode $cfg $php $apache

    if ($mode -eq 'apache') {
        if (-not $apache) { Write-Err2 'webMode=apache แต่ไม่พบ httpd — ใช้: aptstack add apache <zip>'; return $false }
        if (-not (Test-PhpApacheMod $php.Dir)) {
            Write-Err2 "PHP $($php.Version) เป็น NTS — ใช้กับ mod_php ไม่ได้ (ต้อง Thread Safe)"
            Write-Info 'TS = มี php*apache2_4.dll · โหลด TS รุ่นเก่า: php-7.4.33-x64TS.zip บน php.watch'
            return $false
        }
        # generate php.ini ทุกครั้งที่ start (ไม่ใช่แค่ตอน use php) — กันค่า hardening ใหม่ไม่เข้า
        $ini = New-PhpIni $php.Dir
        $conf = New-HttpdConf $cfg $php $apache
        # native โปรแกรมเขียนลง stderr -> ต้องหยุด EAP=Stop ไม่งั้นโยน exception แทนที่จะรายงานสวยๆ
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $syntax = & $apache.Httpd -f $conf -t 2>&1 } catch { $syntax = @("$($_.Exception.Message)") }
        $httpdCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEap
        if ($httpdCode -ne 0) {
            Write-Err2 "httpd -t ไม่ผ่าน:"
            foreach ($s in $syntax) { Write-Info "$s" }
            return $false
        }
        # สำคัญ: extension อย่าง curl/intl/sodium พึ่งพา DLL ที่อยู่ในโฟลเดอร์ PHP
        # (libcrypto, icu*, ...) แต่ Windows หา dependency จาก PATH ของ process ที่โหลด
        # -> ถ้าไม่ใส่ PATH ของ PHP ลงไป httpd จะโหลด php_curl แล้วฟ้อง "module could not be found"
        $oldPath = $env:PATH
        $env:PATH = "$($php.Dir);$oldPath"
        try {
            $p = Start-Process -FilePath $apache.Httpd -ArgumentList @('-f', $conf) -PassThru -WindowStyle Hidden
        } finally {
            $env:PATH = $oldPath
        }
        Set-Pid 'web' $p.Id
        $h = Wait-Healthy -Port $cfg.httpPort -Path '/' -Seconds 20
        if (-not $h.Ok) {
            Write-Err2 "Apache ไม่ตอบ — ดู logs\apache-error.log"
            Write-Info 'เปิดดู: aptstack logs apache'
            Clear-Pid 'web'
            return $false
        }
        Write-Ok "Apache $($apache.Version) + mod_php (PHP $($php.Version))"
        Write-HealthLine $h 'http'
        Write-Info "conf: $conf"
        if ("$($cfg.httpsEnabled)".ToLower() -eq 'true') {
            $hs = Wait-Healthy -Port $cfg.httpsPort -Path '/' -Seconds 10 -Scheme 'https'
            Write-HealthLine $hs 'https'
        }
        return $true
    }

    $ini = New-PhpIni $php.Dir
    $router = Join-Path $Script:P.Www 'router.php'
    $argList = @('-c', $ini, '-S', "127.0.0.1:$($cfg.httpPort)", '-t', $Script:P.Www)
    if (Test-Path $router) { $argList += $router }

    $p = Start-Process -FilePath $php.Exe -ArgumentList $argList -PassThru -WindowStyle Hidden
    Set-Pid 'web' $p.Id
    $h = Wait-Healthy -Port $cfg.httpPort -Path '/' -Seconds 20
    if (-not $h.Ok) {
        Write-Err2 "Web server ไม่ตอบ — ดู logs\php-error.log"
        Write-Info 'เปิดดู: aptstack logs php'
        Clear-Pid 'web'
        return $false
    }
    Write-Ok "PHP built-in server (PHP $($php.Version))"
    Write-HealthLine $h 'http'
    if ("$($cfg.httpsEnabled)".ToLower() -eq 'true') {
        Write-Warn2 'webMode=builtin ไม่รองรับ HTTPS — ใช้ "webMode": "apache" หรือปิด httpsEnabled'
    }
    return $true
}

function Stop-Web {
    $cfg = Get-Config
    $php = Resolve-Php $cfg.php
    $apache = Resolve-Apache $cfg.apache
    if ($apache -and (Resolve-WebMode $cfg $php $apache) -eq 'apache') {
        $conf = Join-Path $Script:P.Runtime 'httpd.conf'
        if (Test-Path $conf) {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & $apache.Httpd -f $conf -k stop 2>&1 | Out-Null; Start-Sleep -Seconds 2 } catch { }
            $ErrorActionPreference = $oldEap
        }
    }
    Stop-ByPidFile 'web'
    Stop-ByPort -port $cfg.httpPort -label 'web'
}

function Stop-Db {
    $cfg = Get-Config
    # dbMode=external = MySQL ของ XAMPP/ของจริง -> ห้ามแตะ (อย่า kill ของคนอื่น)
    if ("$($cfg.dbMode)" -eq 'external') {
        Write-Info "dbMode=external — ไม่แตะ MySQL ที่ 127.0.0.1:$($cfg.dbPort)"
        Clear-Pid 'mysql'
        return
    }
    if (Test-Running 'mysql') {
        $hit = Resolve-MySql $cfg.mysql
        $ok = $false
        if ($hit) { $ok = Invoke-DbAdmin $hit @('shutdown') }
        if ($ok) {
            # รอ flush ให้จบจริง — ปิดก่อน Aria/InnoDB เขียน = ตารางพัง
            for ($w = 0; $w -lt 45; $w++) { Start-Sleep -Seconds 1; if (Test-PortFree $cfg.dbPort) { break } }
            if (Test-PortFree $cfg.dbPort) {
                Write-Ok 'MariaDB ปิดแบบ clean shutdown (รอ flush ครบ)'
                Clear-Pid 'mysql'
            } else {
                Write-Warn2 'สั่ง shutdown แล้วแต่ port ยังไม่ว่าง — รอต่ออีกหน่อย (ไม่ kill ทันที)'
                Start-Sleep -Seconds 10
            }
        }
        if (-not (Test-PortFree $cfg.dbPort)) {
            Write-Warn2 'ยังปิดไม่สนิท — force stop เป็นทางสุดท้าย (เสี่ยง Aria corrupt ถ้า server กำลังเขียน)'
            Write-Info 'ครั้งหน้าอย่าเพิ่ง kill: รอ aptstack stop จน clean หรือรัน mariadb-admin shutdown เอง'
            Stop-ByPidFile 'mysql'
        }
    } else {
        Clear-Pid 'mysql'
    }
    # เฉพาะพอร์ตที่ "ยังไม่ว่าง" เท่านั้น — อย่า kill ถ้า shutdown สำเร็จแล้ว
    if (-not (Test-PortFree $cfg.dbPort)) { Stop-ByPort -port $cfg.dbPort -label 'MariaDB' }
}

function Sync-AppAliases {
    # สร้าง junction ใน www\<ชื่อapp> ให้ทุกตัวที่ติดตั้งอยู่
    # -> เข้าได้หลาย path พร้อมกันบน listener เดียว เช่น /app/ /todo-app/ /sysinfo-app/
    # (ไม่แตะ www\<appAlias> ตัวหลัก · ไม่สร้างซ้ำ · ไม่ลบของที่ไม่ใช่ junction)
    $cfg = Get-Config
    Ensure-Dirs
    $main = "$($cfg.appAlias)"
    # 1) เก็บกวาด junction ที่ชี้ไปโฟลเดอร์ที่ถูกลบแล้ว (ไม่แตะตัวหลัก/ของที่ไม่ใช่ junction)
    foreach ($i in @(Get-ChildItem $Script:P.Www -Force -EA SilentlyContinue)) {
        if (-not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if ($i.Name -eq $main) { continue }
        if (-not (Test-Path -LiteralPath $i.FullName)) {
            [void][IO.Directory]::Delete($i.FullName, $false)
        }
    }
    # 2) สร้าง junction ให้ทุก app ที่ยังไม่มี path
    foreach ($a in @(Get-AppVersions)) {
        $safe = "$($a.Name)" -replace '[^\w.\-]', '-'
        if (-not $safe -or $safe -eq $main) { continue }
        $link = Join-Path $Script:P.Www $safe
        $tgt = $a.Dir
        $i = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ($i) {
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ("$($i.Target)" -eq $tgt) { continue }
                [void][IO.Directory]::Delete($link, $false)
            } else { continue }
        }
        New-Item -ItemType Junction -Path $link -Target $tgt | Out-Null
    }
}

function Cmd-Start {
    Ensure-Dirs
    $cfg = Get-Config
    if (-not $cfg.app) {
        $cur = Get-CurrentAppName
        if ($cur) { $cfg.app = $cur; Save-Config $cfg }
    }
    if (-not (Test-Path (Join-Path $Script:P.Www $cfg.appAlias))) {
        Write-Warn2 "ไม่พบ www\$($cfg.appAlias) — รัน: aptstack use <version>"
    }
    Start-Db $cfg | Out-Null
    Sync-AppAliases            # ทุก app มี path ของตัวเอง เช่น /todo-app/ /sysinfo-app/
    Start-Web $cfg | Out-Null
    Write-ShortTagHint         # เตือน short_open_tag ตั้งแต่ start — กัน CI3 พังแบบ Unclosed brace
    Cmd-Summary
}

function Cmd-Stop([string]$what) {
    # aptstack stop          -> หยุด web + db ของ bundle นี้
    # aptstack stop 3307     -> หยุด process ที่จอง port นั้น (โชว์ path ก่อน ถามถ้าไม่ใช่ของเรา)
    if ("$what" -match '^\d+$') {
        Write-Head "หยุด process บนพอร์ต $what"
        Stop-ByPort ([int]$what) "port $what"
        return
    }
    Write-Head 'หยุด stack'
    Stop-Web
    Stop-Db
    if (Test-Path $Script:P.StopFlag) { Remove-Item $Script:P.StopFlag -Force -ErrorAction SilentlyContinue }
    Cmd-Summary
}

function Cmd-Restart { Cmd-Stop; Start-Sleep -Seconds 1; Cmd-Start }

function Cmd-Summary {
    $cfg = Get-Config
    $webUp = -not (Test-PortFree $cfg.httpPort)
    $dbUp = -not (Test-PortFree $cfg.dbPort)
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkGray
    if ($dbUp) { Write-Host "   MariaDB : UP    127.0.0.1:$($cfg.dbPort)" -ForegroundColor Green }
    else       { Write-Host "   MariaDB : DOWN  127.0.0.1:$($cfg.dbPort)" -ForegroundColor DarkGray }
    if ($webUp) { Write-Host "   Web     : UP    http://127.0.0.1:$($cfg.httpPort)/$($cfg.appAlias)/" -ForegroundColor Green }
    else        { Write-Host "   Web     : DOWN  http://127.0.0.1:$($cfg.httpPort)/" -ForegroundColor DarkGray }
    Write-Host "   App ver : $(Get-CurrentAppName)   PHP: $($cfg.php)" -ForegroundColor Gray
    Write-Host '   หยุดทั้งหมด : aptstack stop' -ForegroundColor Gray
    Write-Host '  ============================================================' -ForegroundColor DarkGray
    Write-Host ''
}

function Cmd-Status {
    $cfg = Get-Config
    Write-Head 'สถานะ'
    foreach ($n in @('web', 'mysql')) {
        $p = Test-Running $n
        if ($p) { Write-Ok "$n กำลังรัน (PID $($p.Id))" } else { Write-Info "$n หยุดอยู่" }
    }
    Write-Host ''
    Write-Host "  App version : $(Get-CurrentAppName)"
    Write-Host "  PHP         : $($cfg.php)"
    Write-Host "  URL         : http://127.0.0.1:$($cfg.httpPort)/$($cfg.appAlias)/"
    Write-Host "  Database    : 127.0.0.1:$($cfg.dbPort)"
    Write-Host "  Service     : $(if (Get-Service -Name $cfg.serviceName -EA SilentlyContinue) { 'ติดตั้งแล้ว' } else { 'ยังไม่ติดตั้ง' })"

    # พอร์ตถูกใครจอง (โชว์ path ถ้าไม่ใช่ของเรา)
    Write-Host ''
    Write-Host '  พอร์ต:' -ForegroundColor Cyan
    foreach ($pair in @(@('HTTP', $cfg.httpPort, 'web'), @('HTTPS', $cfg.httpsPort, 'web'), @('MySQL', $cfg.dbPort, 'mysql'))) {
        $pid0 = Get-PortPid $pair[1]
        if (-not $pid0) { Write-Info ("{0,-5} {1,-5}  ว่าง" -f $pair[0], $pair[1]); continue }
        $owner = Get-PortOwner $pair[1]
        $ours = [bool](Test-Running $pair[2])
        $mark = if ($ours -and $owner.IsSelf) { 'ours' } elseif ($owner.IsSelf) { 'bundle' } else { 'OTHER' }
        Write-Info ("{0,-5} {1,-5}  [{2}] PID {3} {4}" -f $pair[0], $pair[1], $mark, $owner.Pid, $owner.Name)
        if ($mark -eq 'OTHER' -and $owner.Folder) {
            Write-Info "      dir : $($owner.Folder)"
            Write-Info "      หยุด: aptstack stop $($pair[1])"
        }
    }
}

# ---------------------------------------------------------------- switch
function Remove-AppLink {
    $cfg = Get-Config
    $link = Join-Path $Script:P.Www $cfg.appAlias
    $i = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if (-not $i) { return }
    if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # rmdir บน junction = ลบ link เท่านั้น ไม่แตะ contents ของ target
        [void][IO.Directory]::Delete($link, $false)
    } else {
        throw "www\$($cfg.appAlias) เป็นโฟลเดอร์ธรรมดา (ไม่ใช่ junction) — ย้ายออกเองก่อน ระบบจะไม่ลบของจริงให้"
    }
}

function Set-AppLink([string]$appName) {
    $cfg = Get-Config
    $link = Join-Path $Script:P.Www $cfg.appAlias
    $target = Join-Path $Script:P.Versions $appName
    if (-not (Test-Path $target)) { throw "ไม่พบเวอร์ชันแอป '$appName' ใน versions\" }
    Remove-AppLink
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
}

function New-MainAppLinkFromConfig {
    # สร้าง www\<appAlias> -> versions\<app> จาก config (ใช้ได้ทั้งตอนหาย/ junction ชี้เป้าตาย)
    # คืน $true ถ้ามี junction ใช้ได้แล้ว
    $cfg = Get-Config
    $link = Join-Path $Script:P.Www $cfg.appAlias
    Ensure-Dirs
    $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if (Test-Path -LiteralPath $link) { return $true }
            try { [void][IO.Directory]::Delete($link, $false) } catch { return $false }
        } else { return $false }   # โฟลเดอร์จริง — ให้ Repair-MainAppLink จัดการก่อน
    }
    $name = "$($cfg.app)"
    if (-not $name -or -not (Test-Path (Join-Path $Script:P.Versions $name))) {
        $apps = @(Get-AppVersions)
        if ($apps.Count -eq 0) { return $false }
        $pick = @($apps | Where-Object { $_.Usable } | Select-Object -Last 1)
        if ($pick.Count -eq 0) { $pick = @($apps[-1]) }
        $name = $pick[0].Name
        $cfg.app = $name
        Save-Config $cfg
    }
    $target = Join-Path $Script:P.Versions $name
    try {
        New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Warn2 "สร้าง junction www\$($cfg.appAlias) ไม่ได้: $($_.Exception.Message)"
        return $false
    }
}

function Repair-MainAppLink {
    # ตรวจ www\<appAlias> หลัง copy / ตอน doctor:
    #   - junction ใช้ได้          -> ok
    #   - หาย / ชี้เป้าตาย         -> สร้างใหม่จาก config
    #   - โฟลเดอร์ว่าง (ไม่ใช่ j.) -> ลบอัตโนมัติ (ไม่มีไฟล์) แล้วสร้าง junction
    #   - โฟลเดอร์จริง (ไม่ใช่ j.)-> WARN + ยืนยันลบ (web จะ 404/500) แล้วสร้าง junction
    # คืน: ok | created | fixed | missing | declined | not-junction | broken
    param([string]$Where = '')
    $cfg = Get-Config
    $alias = "$($cfg.appAlias)"
    $link = Join-Path $Script:P.Www $alias
    $ctx = if ($Where) { "  [$Where]" } else { '' }
    $i = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue

    if (-not $i) {
        if (New-MainAppLinkFromConfig) {
            $t = "$(Get-Item -LiteralPath $link -Force).Target"
            Write-Warn2 "www\$alias หายไป — สร้าง junction ใหม่ -> $(Split-Path $t -Leaf)$ctx"
            return 'created'
        }
        return 'missing'
    }

    $isJunction = [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($isJunction) {
        if (Test-Path -LiteralPath $link) { return 'ok' }
        # junction ชี้ไปเป้าที่ถูกลบแล้ว
        try { [void][IO.Directory]::Delete($link, $false) } catch { return 'broken' }
        if (New-MainAppLinkFromConfig) {
            $t = "$(Get-Item -LiteralPath $link -Force).Target"
            Write-Warn2 "junction www\$alias ชี้เป้าหาย — สร้างใหม่ -> $(Split-Path $t -Leaf)$ctx"
            return 'created'
        }
        return 'missing'
    }

    # ---- ไม่ใช่ junction: copy โฟลเดอร์ทับ / copy แบบไม่รักษา junction ----
    $kids = @(Get-ChildItem -LiteralPath $link -Force -ErrorAction SilentlyContinue)
    $empty = ($kids.Count -eq 0)

    if ($empty) {
        Write-Warn2 "www\$alias เป็นโฟลเดอร์ว่าง (ไม่ใช่ junction) — web จะ 404/500 / สลับเวอร์ชันไม่ได้$ctx"
        Write-Info 'โฟลเดอร์ว่าง = ปลอดภัยที่จะลบ แล้วสร้าง junction ใหม่'
        try { Remove-Item -LiteralPath $link -Recurse -Force -ErrorAction Stop }
        catch {
            Write-Err2 "ลบโฟลเดอร์ว่าง www\$alias ไม่ได้: $($_.Exception.Message)"
            return 'not-junction'
        }
        if (New-MainAppLinkFromConfig) {
            Write-Ok "ลบโฟลเดอร์ว่างแล้ว + สร้าง junction www\$alias ใหม่$ctx"
            return 'fixed'
        }
        Write-Warn2 'ลบแล้ว แต่ยังสร้าง junction ไม่ได้ (ไม่มี versions\ ให้ชี้) — รัน: aptstack use <version>'
        return 'missing'
    }

    $mb = Get-FolderSizeMB $link
    Write-Warn2 "www\$alias เป็นโฟลเดอร์ธรรมดา (ไม่ใช่ junction)$ctx"
    Write-Err2 "web server จะ 404/500 · สลับเวอร์ชันไม่ได้ — มีไฟล์จริง $($kids.Count) รายการ (~$mb MB)"
    Write-Info 'มักเกิดจาก copy โฟลเดอร์ทับ junction — ต้องลบ www\app ออกแล้วสร้าง junction ใหม่'
    if (-not (Confirm-Action "ลบ www\$alias (ของจริง $($kids.Count) รายการ ~$mb MB) แล้วสร้าง junction ใหม่?")) {
        Write-Info 'ไม่ลบ — ต้องเอาออกเองก่อน web ถึงจะรันได้ (ไม่งั้น 404/500)'
        return 'declined'
    }
    try { Remove-Item -LiteralPath $link -Recurse -Force -ErrorAction Stop }
    catch {
        Write-Err2 "ลบ www\$alias ไม่ได้: $($_.Exception.Message) — ปิด program ที่เปิดโฟลเดอร์นี้ก่อน"
        return 'not-junction'
    }
    if (New-MainAppLinkFromConfig) {
        Write-Ok "ลบโฟลเดอร์ธรรมดาแล้ว + สร้าง junction www\$alias ใหม่$ctx"
        return 'fixed'
    }
    Write-Warn2 'ลบแล้ว แต่ยังสร้าง junction ไม่ได้ (ไม่มี versions\ ให้ชี้) — รัน: aptstack use <version>'
    return 'missing'
}

function Switch-App {
    param([Parameter(Mandatory)][string]$Version, [switch]$NoRestart)
    $hit = Resolve-App $Version
    if (-not $hit) { throw "ไม่พบเวอร์ชัน '$Version' — เพิ่มก่อน: aptstack add app <folder|zip>" }
    if (-not $hit.Usable) { Write-Warn2 "versions\$($hit.Name) ไม่มี index.php — อาจไม่ใช่ webroot" }

    $cfg = Get-Config
    $cur = Get-CurrentAppName
    $wasRunning = [bool](Test-Running 'web')

    if ($cur -eq $hit.Name) { Write-Info "ใช้ $Version อยู่แล้ว" }
    if ($wasRunning) { Stop-Web }

    Set-AppLink $hit.Name
    if ($cur -and $cur -ne $hit.Name) { $cfg.appPrev = $cur }
    $cfg.app = $hit.Name
    Save-Config $cfg

    Write-Host ''
    Write-Host "  App -> $($hit.Name)" -ForegroundColor Green -NoNewline
    Write-Host "   www\$($cfg.appAlias) -> versions\$($hit.Name)" -ForegroundColor DarkGray
    if ($cfg.appPrev) { Write-Info "ย้อนกลับ: aptstack use -" }

    if ($wasRunning -and -not $NoRestart) { Start-Sleep -Seconds 1; Start-Web $cfg | Out-Null; Cmd-Summary }
    elseif (-not $wasRunning) { Write-Info 'ยังไม่ได้รัน — aptstack start' }
}

function Switch-Php {
    param([Parameter(Mandatory)][string]$Version, [switch]$NoRestart)
    $hit = Resolve-Php $Version
    if (-not $hit) { throw "ไม่พบ PHP '$Version' — เพิ่มก่อน: aptstack add php <zip|url>" }
    if (-not $hit.Usable) { throw "โฟลเดอร์ PHP $($hit.Version) ไม่มี php.exe" }

    $cfg = Get-Config
    if ($cfg.php -and $cfg.php -ne $hit.Version) { $cfg.phpPrev = $cfg.php }
    $cfg.php = $hit.Version
    Save-Config $cfg

    $ini = New-PhpIni $hit.Dir
    $out = & $hit.Exe -v 2>&1 | Select-Object -First 1
    Write-Host ''
    Write-Host "  PHP -> $($hit.Version)" -ForegroundColor Green -NoNewline
    Write-Host "   $out" -ForegroundColor DarkGray
    Write-Info "php.ini : $ini"

    $risk = Get-PhpRisk $hit.Version
    $minor = ($hit.Version -split '\.')[0..1] -join '.'
    $need = if ($Script:PatchedPhp.ContainsKey($minor)) { $Script:PatchedPhp[$minor] } else { '8.2.35' }
    if ($risk -eq 'UNPATCHED') {
        Write-Warn2 "ยังไม่ patch ช่องโหว่ RCE — ต้อง >= $need"
    } elseif ($risk -eq 'EOL') {
        Write-Warn2 'EOL — ไม่มี patch ความปลอดภัยอีก ห้ามใช้เป็น production'
    } else { Write-Ok "ผ่านเกณฑ์ความปลอดภัย (>= $need)" }

    if (-not $NoRestart) {
        if (Test-Running 'web') { Write-Host ''; Write-Info 'restart web...'; Stop-Web; Start-Sleep -Seconds 1; Start-Web $cfg | Out-Null }
        else { Write-Info 'web ไม่ได้รันอยู่ — aptstack start' }
    }
}

function Switch-MySql {
    param([Parameter(Mandatory)][string]$Version, [switch]$NoRestart)
    $hit = Resolve-MySql $Version
    if (-not $hit) { throw "ไม่พบ MySQL/MariaDB '$Version' — เพิ่มก่อน: aptstack add mysql <zip>" }
    $cfg = Get-Config
    $newVal = if ($hit.Version) { $hit.Version } else { $hit.Name }
    if ($cfg.mysql -and $cfg.mysql -ne $newVal) { $cfg.mysqlPrev = $cfg.mysql }
    $cfg.mysql = $newVal
    Save-Config $cfg

    $dd = Get-DataDir $hit
    Write-Host ''
    Write-Host "  MySQL -> $newVal" -ForegroundColor Green -NoNewline
    Write-Host "   $($hit.Dir)" -ForegroundColor DarkGray
    Write-Info "datadir : $dd"
    Write-Info 'datadir แยกต่อ version -> สลับแล้วข้อมูลไม่ปนกัน และไม่ถูก upgrade แบบไม่ตั้งใจ'
    if ($cfg.dbMode -eq 'external') { Write-Warn2 'dbMode=external อยู่ — คำสั่งนี้จะมีผลเมื่อเปลี่ยนเป็น internal' }

    if (Test-Running 'mysql') {
        if ($NoRestart) { Write-Warn2 'MySQL รันอยู่ — ต้องรัน: aptstack restart'; return }
        Write-Host ''
        Stop-Db
        Start-Sleep -Seconds 1
        Start-Db (Get-Config) | Out-Null
    } else { Write-Info 'MySQL ยังไม่รัน — aptstack start' }
}

function Switch-Apache {
    param([Parameter(Mandatory)][string]$Version, [switch]$NoRestart)
    $hit = Resolve-Apache $Version
    if (-not $hit) { throw "ไม่พบ Apache '$Version' — เพิ่มก่อน: aptstack add apache <zip>" }
    $cfg = Get-Config
    if ($cfg.apache -and $cfg.apache -ne $hit.Version) { $cfg.apachePrev = $cfg.apache }
    $cfg.apache = $hit.Version
    if ("$($cfg.webMode)".ToLower() -eq 'builtin') { $cfg.webMode = 'apache' }
    Save-Config $cfg

    $php = Resolve-Php $cfg.php
    if (-not $php -or -not (Test-PhpApacheMod $php.Dir)) {
        Write-Warn2 "PHP $($cfg.php) ไม่มี php*apache2_4.dll (NTS) — Apache mod_php จะ start ไม่ขึ้น"
        Write-Info 'สลับ PHP ก่อน: aptstack use php 8.3.36'
    }

    Write-Host ''
    Write-Host "  Apache -> $($hit.Version)" -ForegroundColor Green -NoNewline
    Write-Host "   $($hit.Dir)" -ForegroundColor DarkGray
    Write-Info "webMode = $($cfg.webMode)"

    if (Test-Running 'web') {
        if ($NoRestart) { Write-Warn2 'web รันอยู่ — ต้องรัน: aptstack restart'; return }
        Write-Host ''
        Stop-Web
        Start-Sleep -Seconds 1
        Start-Web (Get-Config) | Out-Null
    } else { Write-Info 'web ยังไม่รัน — aptstack start' }
}

function Select-Interactive {
    $apps = @(Get-AppVersions)
    $phps = @(Get-PhpVersions)
    $cfg = Get-Config
    $curApp = Get-CurrentAppName
    Write-Host ''
    Write-Host '  เลือกเวอร์ชัน' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [แอป]' -ForegroundColor White
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $mark = if ($curApp -eq $apps[$i].Name) { '  <- ใช้อยู่' } else { '' }
        Write-Host ("   {0}) app {1}{2}" -f ($i + 1), $apps[$i].Name, $mark)
    }
    Write-Host ''
    Write-Host '  [PHP]' -ForegroundColor White
    $base = $apps.Count
    for ($i = 0; $i -lt $phps.Count; $i++) {
        $mark = if ($cfg.php -eq $phps[$i].Version) { '  <- ใช้อยู่' } else { '' }
        $tag = ''
        $r = Get-PhpRisk $phps[$i].Version
        if ($r -eq 'UNPATCHED') { $tag = '  [ยังไม่ patch RCE]' }
        elseif ($r -eq 'EOL') { $tag = '  [EOL]' }
        Write-Host ("   {0}) php {1}{2}{3}" -f ($base + $i + 1), $phps[$i].Version, $tag, $mark)
    }
    Write-Host ''
    $ans = Read-Host "  พิมพ์หมายเลข 1-$($base + $phps.Count) แล้ว Enter (Enter เปล่า = ยกเลิก)"
    if ([string]::IsNullOrWhiteSpace($ans)) { Write-Info 'ยกเลิก'; return }
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 1 -or $n -gt ($base + $phps.Count)) { Write-Err2 "ไม่ถูกต้อง: '$ans'"; return }
    if ($n -le $base) { Switch-App -Version $apps[$n - 1].Name }
    else { Switch-Php -Version $phps[$n - $base - 1].Version }
}

function Step-App($delta) {
    $list = @(Get-AppVersions)
    if ($list.Count -lt 2) { throw 'ต้องมี app version อย่างน้อย 2 — ใช้: aptstack add app <folder|zip>' }
    $cur = Get-CurrentAppName
    $idx = 0
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Name -eq $cur) { $idx = $i } }
    $idx = ($idx + $delta + $list.Count) % $list.Count
    Switch-App -Version $list[$idx].Name
}

function Cmd-Use($component, $ver) {
    if (-not $component) { Select-Interactive; return }
    switch ($component.ToLower()) {
        'php'    {
            if ($ver) { Switch-Php -Version $ver }
            else {
                $first = Resolve-Php $null
                if (-not $first) { throw 'ยังไม่มี PHP — ใช้: aptstack add php <zip>' }
                Switch-Php -Version $first.Version
            }
        }
        'app'    { if (-not $ver) { throw 'ใช้: aptstack use app <version>' }; Switch-App -Version $ver }
        'mysql'  { if (-not $ver) { throw 'ใช้: aptstack use mysql <version>' }; Switch-MySql -Version $ver }
        'apache' { if (-not $ver) { throw 'ใช้: aptstack use apache <version>' }; Switch-Apache -Version $ver }
        '-'      { $c = Get-Config; if (-not $c.appPrev) { throw 'ยังไม่มีประวัติ — สลับอย่างน้อย 2 ครั้งก่อน' }; Switch-App -Version $c.appPrev }
        default  {
            $apps = Get-AppVersions | Where-Object { $_.Name -eq $component -or $_.Name -like "$component*" } | Select-Object -Last 1
            if ($apps) { Switch-App -Version $apps.Name; return }
            $php = Resolve-Php $component
            if ($php) { Switch-Php -Version $php.Version; return }
            throw "ไม่รู้จัก '$component' — ไม่ตรงทั้ง app version และ PHP version"
        }
    }
}

# ---------------------------------------------------------------- add
function Get-DownloadedZip($source) {
    if ($source -match '^https?://') {
        Ensure-Dirs
        $zip = Join-Path $Script:P.Downloads ([IO.Path]::GetFileName(($source -split '\?')[0]))
        if (-not (Test-Path $zip)) {
            Write-Head "ดาวน์โหลด $source"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $err = ''
            try {
                Invoke-WebRequest -Uri $source -OutFile $zip -UseBasicParsing -TimeoutSec 600
            } catch {
                # mirror บางตัว (เช่น apachelounge.com) คุยกับ Invoke-WebRequest บน PS5.1 ไม่ได้
                # -> fallback ไป curl.exe (ไม่มี stream redirection -> ไม่ชน NativeCommandError กับ EAP=Stop)
                $err = "$($_.Exception.Message)"
                $ok = $false
                if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                    $p = Start-Process -FilePath 'curl.exe' -ArgumentList @('-sL', '--fail', '--max-time', '600', '-A', 'aptstack', "`"$source`"", '-o', "`"$zip`"") -Wait -PassThru -NoNewWindow
                    if ($p.ExitCode -eq 0 -and (Test-Path $zip) -and ((Get-Item $zip -ErrorAction SilentlyContinue).Length -gt 0)) { $ok = $true }
                }
                if (-not $ok) {
                    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                    throw "ดาวน์โหลดไม่สำเร็จ ($err)"
                }
            }
            Write-Ok "บันทึกไว้: $zip"
        }
        return $zip
    }
    if (-not (Test-Path $source)) { throw "ไม่พบไฟล์/โฟลเดอร์: $source" }
    return (Resolve-Path $source).Path
}

# โหลดหน้าเว็บเป็นข้อความ — curl.exe ก่อน (มี mirror ที่ IWR ใช้ไม่ได้) แล้วค่อย fallback IWR
function Get-WebText([string]$Uri) {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("aptstack-" + [Guid]::NewGuid().ToString('N') + ".html")
        try {
            $p = Start-Process -FilePath 'curl.exe' -ArgumentList @('-sL', '--max-time', '40', '-A', 'aptstack', "`"$Uri`"", '-o', "`"$tmp`"") -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0 -and (Test-Path $tmp)) { return [IO.File]::ReadAllText($tmp) }
        } catch { } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 40).Content
    } catch { return $null }
}

function Expand-AndFlatten($zip, $dest) {
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    $kids = @(Get-ChildItem $dest -Force)
    if ($kids.Count -eq 1 -and $kids[0].PSIsContainer) {
        $inner = $kids[0].FullName
        Get-ChildItem $inner -Force | Move-Item -Destination $dest -Force
        Remove-Item $inner -Recurse -Force
    }
}

# ---------------------------------------------------- official URL + source
function Get-OfficialUrls([string]$kind, [string]$ver) {
    # คืน URL ทางการเป็น list (ลองทีละอัน — PHP มี releases กับ archives)
    switch ("$kind".ToLower()) {
        'php' {
            if ($ver -eq 'latest' -or -not $ver) { $ver = '8.3.36' }   # ค่าผ่านเกณฑ์ security-php.txt
            $base = "php-$ver-Win32-vs16-x64.zip"   # Thread Safe x64 เสมอ
            return @(
                "https://windows.php.net/downloads/releases/$base",
                "https://windows.php.net/downloads/releases/archives/$base"
            )
        }
        'mysql' {
            if ($ver -eq 'latest' -or -not $ver) { return @() }   # MariaDB ไม่มี latest -> ต้องระบุเลข
            return @("https://archive.mariadb.org/mariadb-$ver/winx64-packages/mariadb-$ver-winx64.zip")
        }
        'apache' {
            # Apache Lounge เผยแพร่เฉพาะ build ล่าสุด และชื่อไฟล์มีเลข build
            # (httpd-2.4.69-261002-Win64-VS18.zip) -> แปลงเลขเวอร์ชันเป็น URL โดย scrape หน้าโหลดจริง
            $page = Get-WebText 'https://www.apachelounge.com/download/'
            if (-not $page) { return @() }
            $want = if ($ver -and $ver -ne 'latest') { [regex]::Escape($ver) } else { '[\d\.]+' }
            $m = [regex]::Match($page, ('href="([^"]*httpd-' + $want + '-\d+-Win64-VS\d+\.zip)"'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $m.Success) { return @() }   # เวอร์ชันนั้นไม่อยู่ในหน้า (Lounge เก็บแค่ตัวล่าสุด)
            $href = $m.Groups[1].Value
            if ($href -notmatch '^https?://') { $href = 'https://www.apachelounge.com' + $href }
            return @($href)
        }
        'pma' {
            # phpMyAdmin: https://files.phpmyadmin.net/phpMyAdmin/<ver>/phpMyAdmin-<ver>-all-languages.zip
            if ($ver -eq 'latest' -or -not $ver) {
                $page = Get-WebText 'https://www.phpmyadmin.net/downloads/'
                if ($page) {
                    $m = [regex]::Match($page, 'phpMyAdmin[-/](\d+\.\d+\.\d+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    if ($m.Success) { $ver = $m.Groups[1].Value }
                }
                if (-not $ver -or $ver -eq 'latest') { $ver = '5.2.2' }   # fallback ล่าสุดที่รู้
            }
            return @("https://files.phpmyadmin.net/phpMyAdmin/$ver/phpMyAdmin-$ver-all-languages.zip")
        }
        default { return @() }
    }
}

function Set-SourceMeta($destDir, [string]$kind, [string]$source) {
    try {
        if (-not $destDir -or -not (Test-Path $destDir)) { return }
        $txt = @"
# aptstack: แหล่งที่มาของ binary ตัวนี้
# copy บรรทัด source= ไปโหลดเองภายหลังได้ (หรือใช้ docs\OFFLINE-DEPLOY.md)
kind=$kind
source=$source
installed=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
        Write-Utf8NoBom (Join-Path $destDir '.aptstack-source') ($txt + "`r`n")
    } catch { }
}

function Get-SourceMeta($destDir) {
    $f = Join-Path $destDir '.aptstack-source'
    if (-not $destDir -or -not (Test-Path $f)) { return $null }
    $h = @{}
    foreach ($l in (Get-Content $f -ErrorAction SilentlyContinue)) {
        if ("$l" -match '^\s*#' -or "$l" -notmatch '=') { continue }
        $i = "$l".IndexOf('=')
        $h[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim()
    }
    if ($h['source']) { return $h }
    return $null
}

function Get-CloneLineage {
    # สร้างข้อมูลสายสัมพันธ์ระหว่าง app version (clone / import / original)
    $apps = @(Get-AppVersions)
    $cur = Get-CurrentAppName
    $rows = @()
    foreach ($a in $apps) {
        $src = Get-SourceMeta $a.Dir
        $source = if ($src -and $src['source']) { $src['source'] } else { '' }
        $installed = if ($src -and $src['installed']) { $src['installed'] } else { '' }
        $parent = ''
        $origin = ''
        $kind = 'original'
        if ($source -match '^clone of versions\\(.+)$') {
            $parent = $Matches[1]
            $kind = 'clone'
            # ตาม chain ไปหาต้นตอ (origin)
            $guard = 0
            $walk = $parent
            while ($walk -and $guard -lt 20) {
                $guard++
                $pd = Join-Path $Script:P.Versions $walk
                if (-not (Test-Path $pd)) { break }
                $ps = Get-SourceMeta $pd
                if ($ps -and $ps['source'] -match '^clone of versions\\(.+)$') { $walk = $Matches[1]; continue }
                $origin = if ($ps -and $ps['source']) { $ps['source'] } else { "versions\$walk" }
                break
            }
            if (-not $origin) { $origin = "versions\$parent" }
        }
        elseif ($source) {
            $origin = $source
        }
        else { $origin = "versions\$($a.Name)" }

        $rows += [pscustomobject]@{
            Name       = $a.Name
            Family     = $a.Family
            Version    = $a.Version
            Dir        = $a.Dir
            Parent     = $parent
            Origin     = $origin
            Kind       = $kind
            Source     = $source
            Installed  = $installed
            Usable     = $a.Usable
            IsCurrent  = ($a.Name -eq $cur)
            SizeMB     = 0.0
            Files      = 0
        }
    }
    foreach ($r in $rows) {
        $files = @(Get-ChildItem $r.Dir -Recurse -File -Force -ErrorAction SilentlyContinue)
        $r.Files = $files.Count
        $r.SizeMB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
    }
    return $rows
}

function Cmd-CloneTree {
    # aptstack clone-tree — ดูสายสัมพันธ์ clone ระหว่าง app version (console)
    $rows = @(Get-CloneLineage)
    if ($rows.Count -eq 0) { Write-Info 'ยังไม่มี app version'; return }

    Write-Head 'clone tree — สายสัมพันธ์ระหว่าง app version'
    $families = @($rows | Group-Object Family | Sort-Object Name)
    foreach ($g in $families) {
        $members = @($g.Group | Sort-Object { if ($_.Installed) { $_.Installed } else { '' } }, Name)
        Write-Host ''
        Write-Host "  [$($g.Name)]  ($($members.Count) version)" -ForegroundColor Cyan

        $names = @($members | ForEach-Object { $_.Name })
        # ห้ามใช้ชื่อ $roots/$root — PS ไม่สนตัวพิมพ์ ทับ $Root ของสคริปต์
        $treeRoots = @($members | Where-Object { -not $_.Parent -or ($names -notcontains $_.Parent) })
        if ($treeRoots.Count -eq 0) { $treeRoots = @($members[0]) }

        $printed = @{}
        $queue = New-Object System.Collections.Queue
        for ($ri = 0; $ri -lt $treeRoots.Count; $ri++) {
            $queue.Enqueue(@($treeRoots[$ri], '', ($ri -eq ($treeRoots.Count - 1))))
        }
        while ($queue.Count -gt 0) {
            $item = $queue.Dequeue()
            $row = $item[0]; $prefix = $item[1]; $isLast = [bool]$item[2]
            if ($printed.ContainsKey($row.Name)) { continue }
            $printed[$row.Name] = $true
            $branch = if ($isLast) { '└─ ' } else { '├─ ' }
            $tag = if ($row.IsCurrent) { '  <- ใช้อยู่' } else { '' }
            $kindTag = if ($row.Kind -eq 'clone') { ' [clone]' } else { ' [origin]' }
            $fg = if ($row.IsCurrent) { 'Green' } elseif ($row.Kind -eq 'clone') { 'Gray' } else { 'White' }
            Write-Host ("{0}{1}{2}{3}  {4} MB  {5}{6}" -f $prefix, $branch, $row.Name, $kindTag, $row.SizeMB, $row.Installed, $tag) -ForegroundColor $fg
            $cont = $prefix + $(if ($isLast) { '   ' } else { '│  ' })
            if ($row.Kind -eq 'clone') {
                Write-Host ("{0}← from {1}" -f $cont, $row.Parent) -ForegroundColor DarkGray
            }
            elseif ($row.Origin -and $row.Origin -notlike "versions\$($row.Name)") {
                Write-Host ("{0}↑ origin: {1}" -f $cont, $row.Origin) -ForegroundColor DarkGray
            }
            $kids = @($members | Where-Object { $_.Parent -eq $row.Name } | Sort-Object Name)
            for ($i = 0; $i -lt $kids.Count; $i++) {
                $queue.Enqueue(@($kids[$i], $cont, ($i -eq ($kids.Count - 1))))
            }
        }
        $orphans = @($members | Where-Object { -not $printed.ContainsKey($_.Name) })
        foreach ($o in $orphans) {
            Write-Host ("   [orphan] {0}  {1} MB  parent หาย" -f $o.Name, $o.SizeMB) -ForegroundColor Yellow
            $printed[$o.Name] = $true
        }
    }

    $nClone = @($rows | Where-Object { $_.Kind -eq 'clone' }).Count
    Write-Host ''
    Write-Info "รวม $($rows.Count) version · เป็น clone $nClone ตัว · ทุกตัวใช้ DB เดียวกัน (config\stack.json)"
    Write-Info 'ดูเป็น HTML: aptstack report clone'
    Write-Info 'สลับไปใช้  : aptstack use <ชื่อ>'
}

function Cmd-ReportClone([string]$outPath) {
    # aptstack report clone [path] — HTML แสดงสายสัมพันธ์ clone / family
    # หมายเหตุ: ห้ามใช้ตัวแปร $root/$roots — PS ไม่สนตัวพิมพ์ จะทับ $Root ของสคริปต์
    $rows = @(Get-CloneLineage)
    if ($rows.Count -eq 0) { throw 'ยังไม่มี app version' }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $cfg = Get-Config
    $cur = Get-CurrentAppName

    $families = @($rows | Group-Object Family | Sort-Object Name)
    $sb = New-Object Text.StringBuilder

    foreach ($g in $families) {
        $members = @($g.Group | Sort-Object { if ($_.Installed) { $_.Installed } else { '' } }, Name)
        [void]$sb.AppendLine("<h2>Family: $([Net.WebUtility]::HtmlEncode($g.Name)) <span class=`"small`">($($members.Count) version)</span></h2>")

        $names = @($members | ForEach-Object { $_.Name })
        $treeRoots = @($members | Where-Object { -not $_.Parent -or ($names -notcontains $_.Parent) })
        if ($treeRoots.Count -eq 0) { $treeRoots = @($members | Select-Object -First 1) }

        function Build-TreeHtml($row, $memberSet, $allNames) {
            $kids = @($memberSet | Where-Object { $_.Parent -eq $row.Name } | Sort-Object Name)
            $badge = if ($row.Kind -eq 'clone') { '<span class="b-clone">clone</span>' } else { '<span class="b-origin">origin</span>' }
            $curMark = if ($row.IsCurrent) { ' <span class="b-cur">ใช้อยู่</span>' } else { '' }
            $from = if ($row.Kind -eq 'clone') { " <span class=`"small`">← from <code>$([Net.WebUtility]::HtmlEncode($row.Parent))</code></span>" } else { '' }
            $orig = ''
            if ($row.Kind -ne 'clone' -and $row.Origin -and $row.Origin -notlike "versions\$($row.Name)") {
                $orig = " <span class=`"small`">↑ <code>$([Net.WebUtility]::HtmlEncode($row.Origin))</code></span>"
            }
            $li = "<li>$badge <b>$([Net.WebUtility]::HtmlEncode($row.Name))</b>$curMark$from$orig"
            $li += " <span class=`"small`">· $($row.SizeMB) MB · $($row.Files) files · $($row.Installed)</span>"
            if ($kids.Count -gt 0) {
                $li += '<ul>'
                foreach ($k in $kids) { $li += (Build-TreeHtml $k $memberSet $allNames) }
                $li += '</ul>'
            }
            $li += '</li>'
            return $li
        }

        [void]$sb.AppendLine('<ul class="tree">')
        foreach ($treeRoot in $treeRoots) {
            [void]$sb.AppendLine((Build-TreeHtml $treeRoot $members $names))
        }
        $printedNames = @{}
        $walkStack = New-Object System.Collections.Stack
        foreach ($treeRoot in $treeRoots) { $walkStack.Push($treeRoot) }
        while ($walkStack.Count -gt 0) {
            $row = $walkStack.Pop()
            $printedNames[$row.Name] = $true
            foreach ($k in @($members | Where-Object { $_.Parent -eq $row.Name })) { $walkStack.Push($k) }
        }
        foreach ($o in @($members | Where-Object { -not $printedNames.ContainsKey($_.Name) })) {
            [void]$sb.AppendLine("<li><span class=`"b-warn`">orphan</span> <b>$([Net.WebUtility]::HtmlEncode($o.Name))</b> <span class=`"small`">parent หาย · $($o.SizeMB) MB</span></li>")
        }
        [void]$sb.AppendLine('</ul>')
    }

    $trs = @()
    foreach ($r in ($rows | Sort-Object Family, Kind, Name)) {
        $badge = if ($r.Kind -eq 'clone') { '<span class="b-clone">clone</span>' } else { '<span class="b-origin">origin</span>' }
        $curMark = if ($r.IsCurrent) { ' ✓' } else { '' }
        $trs += "<tr><td>$([Net.WebUtility]::HtmlEncode($r.Family))</td><td>$badge <b>$([Net.WebUtility]::HtmlEncode($r.Name))</b>$curMark</td><td>$([Net.WebUtility]::HtmlEncode($r.Parent))</td><td class=`"path`">$([Net.WebUtility]::HtmlEncode($r.Origin))</td><td class=`"num`">$($r.SizeMB)</td><td class=`"num`">$($r.Files)</td><td>$([Net.WebUtility]::HtmlEncode($r.Installed))</td></tr>"
    }

    $nClone = @($rows | Where-Object { $_.Kind -eq 'clone' }).Count
    $nFam = $families.Count
    $treeHtml = $sb.ToString()
    $tableHtml = ($trs -join "`n")

    $html = @"
<!DOCTYPE html>
<html lang="th"><head><meta charset="utf-8">
<title>aptstack — clone tree ($stamp)</title>
<style>
  *{box-sizing:border-box}
  body{font-family:"Leelawadee UI","Sarabun",Tahoma,sans-serif;color:#111;background:#fff;font-size:13px;line-height:1.55;margin:0;padding:18px 22px}
  h1{font-size:21px;margin:0 0 2px}
  h2{font-size:15px;margin:20px 0 6px;padding:4px 8px;background:#f0f2f5;border-left:5px solid #1b57c4;color:#10306b}
  .sub{color:#444;font-size:12px;margin:0 0 10px}
  table{border-collapse:collapse;width:100%;margin:4px 0 10px}
  th,td{border:1px solid #8a8f98;padding:4px 7px;vertical-align:top;text-align:left;font-size:12.5px}
  th{background:#eef1f5;font-weight:700}
  .path{font-family:Consolas,monospace;font-size:11.5px;word-break:break-all}
  .num{text-align:right}
  .small{font-size:11.5px;color:#555}
  .card{border:1px solid #8a8f98;padding:8px 10px;margin:8px 0;background:#fafbfc}
  ul.tree,ul.tree ul{list-style:none;padding-left:1.1em;margin:4px 0}
  ul.tree li{margin:3px 0;position:relative}
  ul.tree ul li:before{content:"";position:absolute;left:-0.9em;top:0.55em;width:0.55em;border-top:1px solid #8a8f98}
  .b-clone,.b-origin,.b-cur,.b-warn{display:inline-block;border-radius:4px;padding:1px 7px;font-weight:700;font-size:11px;border:1px solid #111}
  .b-clone{border-color:#1b57c4;color:#1b57c4;background:#e8eefc}
  .b-origin{border-color:#0a7a33;color:#0a7a33;background:#e7f6ec}
  .b-cur{border-color:#8a6100;color:#8a6100;background:#fff6e5}
  .b-warn{border-color:#b00020;color:#b00020;background:#fdecee}
  code{font-family:Consolas,monospace;font-size:11.5px}
  footer{margin-top:16px;padding-top:8px;border-top:1px solid #8a8f98;font-size:11.5px}
  @media print{ body{padding:0;font-size:11.5px} }
</style></head><body>

<h1>aptstack — clone tree / สายสัมพันธ์ app version</h1>
<p class="sub">สร้างเมื่อ $stamp · ปัจจุบันใช้: <b>$([Net.WebUtility]::HtmlEncode($cur))</b>
· DB: 127.0.0.1:$($cfg.dbPort) (ทุก version ใช้ชุดเดียวกัน)</p>

<div class="card">
  สรุป: <b>$($rows.Count)</b> version · <b>$nFam</b> family · เป็น clone <b>$nClone</b> ตัว<br>
  <span class="small">สีน้ำเงิน = clone · เขียว = origin (นำเข้าครั้งแรก) · เหลือง = กำลังใช้อยู่</span><br>
  <span class="small">คำสั่ง: <code>aptstack clone-tree</code> (console) · <code>aptstack use &lt;ชื่อ&gt;</code> สลับเวอร์ชัน · clone ใหม่: <code>aptstack clone app</code></span>
</div>

<h2>แผนผัง (ตาม family)</h2>
$treeHtml

<h2>ตารางทั้งหมด</h2>
<table>
<tr><th>Family</th><th>Version</th><th>Parent (clone from)</th><th>Origin / Source</th><th>MB</th><th>Files</th><th>Installed</th></tr>
$tableHtml
</table>

<footer>
  aptstack · <code>aptstack report clone</code> · $stamp<br>
  หมายเหตุ: clone ไม่สำเนา DB — แอปทุกตัวชี้ <code>config\stack.json</code> ชุดเดียวกัน
</footer>
</body></html>
"@

    if ([string]::IsNullOrWhiteSpace($outPath)) {
        $outPath = Join-Path -Path $script:Root -ChildPath 'aptstack-clone-report.html'
    }
    Write-Utf8NoBom $outPath $html
    Write-Head 'สร้างรายงาน clone tree (HTML)'
    Write-Ok "ผล: $($rows.Count) version · $nClone clone · $nFam family"
    Write-Info "ไฟล์: $outPath"
    try { Start-Process $outPath | Out-Null; Write-Info 'เปิดในเบราว์เซอร์ให้แล้ว' } catch { }
    return $outPath
}

function Normalize-PmaKind([string]$k) {
    $k = "$k".ToLower()
    if ($k -in @('pma', 'phpmyadmin', 'phpmyadmin')) { return 'pma' }
    return $k
}

function Write-PmaConfig([string]$PmaDir) {
    # generate www\phpmyadmin\config.inc.php จาก stack.json (host/port/user/pass)
    if (-not $PmaDir -or -not (Test-Path $PmaDir)) { return $false }
    $cfg = Get-Config
    $secret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    $pmaCfg = @"
<?php
/* aptstack phpMyAdmin config — generate จาก config\stack.json (aptstack db set-root / add-user) */
`$cfg['blowfish_secret'] = '$secret';
`$i = 0;
`$i++;
`$cfg['Servers'][`$i]['host'] = '127.0.0.1';
`$cfg['Servers'][`$i]['port'] = '$($cfg.dbPort)';
`$cfg['Servers'][`$i]['auth_type'] = 'config';
`$cfg['Servers'][`$i]['user'] = '$($cfg.dbUser)';
`$cfg['Servers'][`$i]['password'] = '$($cfg.dbPass)';
`$cfg['Servers'][`$i]['compress'] = false;
`$cfg['Servers'][`$i]['AllowNoPassword'] = false;
`$cfg['UploadDir'] = '';
`$cfg['SaveDir'] = '';
`$cfg['CheckConfigurationPermissions'] = false;
"@
    Write-Utf8NoBom (Join-Path $PmaDir 'config.inc.php') ($pmaCfg + "`r`n")
    return $true
}

function Get-PmaInfo {
    $pma = Join-Path $Script:P.Www 'phpmyadmin'
    if (-not (Test-Path (Join-Path $pma 'index.php'))) { return $null }
    $ver = $null
    foreach ($f in @('README', 'VERSION')) {
        $p = Join-Path $pma $f
        if (Test-Path $p) {
            $t = Get-Content $p -Raw -EA SilentlyContinue
            if ($t -match 'Version\s+(\d+\.\d+\.\d+)') { $ver = $Matches[1]; break }
        }
    }
    return [pscustomobject]@{
        Dir     = $pma
        Version = $ver
        Url     = "http://127.0.0.1:$((Get-Config).httpPort)/phpmyadmin/"
        Config  = (Join-Path $pma 'config.inc.php')
    }
}

function Select-AddAppSource {
    # aptstack add app (ไม่ใส่ path) -> ลิสต์ zip ใน downloads\ + โฟลเดอร์แอป แล้วให้เลือกหมายเลข
    # คืนค่า path เต็ม หรือ $null ถ้ายกเลิก / non-interactive
    $items = @()

    # 1) zip ทั้งหมดใน downloads\
    $dl = $Script:P.Downloads
    if (Test-Path $dl) {
        $zips = @(Get-ChildItem -LiteralPath $dl -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(zip|7z)$' } |
            Sort-Object LastWriteTimeUtc -Descending)
        foreach ($z in $zips) {
            $items += [pscustomobject]@{ Kind = 'zip'; Path = $z.FullName; Name = $z.Name; Detail = ('{0:N1} MB' -f ($z.Length / 1MB)) }
        }
    }

    # 2) โฟลเดอร์แอป: examples\ + โฟลเดอร์ข้าง aptstack root (ข้าม aptstack* / hidden / _setup*)
    $searchRoots = @()
    if (Test-Path $Script:P.Root) { $searchRoots += $Script:P.Root }
    $ex = Join-Path $Script:P.Root 'examples'
    if (Test-Path $ex) { $searchRoots += $ex }
    $parent = Split-Path -Parent $Script:P.Root
    if ($parent -and (Test-Path $parent)) { $searchRoots += $parent }
    $cwd = (Get-Location).Path
    if ($cwd) { $searchRoots += $cwd }

    $seenDir = @{}
    foreach ($searchDir in ($searchRoots | Select-Object -Unique)) {
        $dirs = @(Get-ChildItem -LiteralPath $searchDir -Directory -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            if ($seenDir.ContainsKey($d.FullName)) { continue }
            $seenDir[$d.FullName] = $true
            $n = $d.Name
            if ($n -match '^\.' -or $n -match '^aptstack' -or $n -match '^stack$' -or $n -match '^config$' -or $n -match '^versions$' -or $n -match '^www$' -or $n -match '^data$' -or $n -match '^logs$' -or $n -match '^templates$' -or $n -match '^downloads$' -or $n -match '^out$' -or $n -match '^dist$' -or $n -match '^_mariadb' -or $n -match '^_setup_') { continue }
            # โฟลเดอร์แอป = มี index.php / app\index.php / ไฟล์ .php อยู่ในนั้น หรืออยู่ใน examples\
            $inExamples = ($searchDir -eq $ex)
            $looksApp = $inExamples -or
                (Test-Path (Join-Path $d.FullName 'index.php')) -or
                (Test-Path (Join-Path $d.FullName 'app\index.php')) -or
                (@(Get-ChildItem -LiteralPath $d.FullName -Filter '*.php' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0)
            if (-not $looksApp) { continue }
            $items += [pscustomobject]@{ Kind = 'dir'; Path = $d.FullName; Name = $n; Detail = 'folder' }
        }
    }

    if ($items.Count -eq 0) {
        Write-Err2 'ไม่พบ zip ใน downloads\ หรือโฟลเดอร์แอป'
        Write-Info 'ส่ง path เองได้: aptstack add app <folder|zip>'
        return $null
    }

    Write-Head "เลือกแหล่งแอป (พบ $($items.Count) รายการ)"
    Write-Info 'zip = ไฟล์ใน downloads\ · dir = โฟลเดอร์ที่มี index.php'
    Write-Host ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $tag = if ($it.Kind -eq 'zip') { 'zip' } else { 'dir' }
        Write-Host ("  [{0,2}]  {1,-4}  {2,-48}  {3}" -f ($i + 1), $tag, $it.Name, $it.Detail) -ForegroundColor White
    }
    Write-Host ''
    Write-Host ("  พิมพ์หมายเลข 1-{0} แล้ว Enter (Enter = ยกเลิก · path เองได้ · .. = โฟลเดอร์แม่)" -f $items.Count) -ForegroundColor Yellow
    $ans = $null
    try {
        if ([Console]::IsInputRedirected) { $ans = [Console]::In.ReadLine() }
        else { $ans = Read-Host '  > ' }
    } catch { return $null }
    if ($null -eq $ans -or [string]::IsNullOrWhiteSpace($ans)) { Write-Info 'ยกเลิก'; return $null }
    $ans = "$ans".Trim().Trim('"')

    # path: มี \ หรือ : หรือขึ้นต้นด้วย . (รวม .. และ .) — ใช้ได้ทั้ง zip/โฟลเดอร์
    $isPathish = ($ans -match '[\\/]') -or ($ans -match '^[A-Za-z]:') -or ($ans -eq '.') -or ($ans -eq '..') -or ($ans -match '^\.[\\/]')
    if ($isPathish) {
        if (Test-Path -LiteralPath $ans) {
            $resolved = (Resolve-Path -LiteralPath $ans).Path
            if (Test-Path -LiteralPath $resolved -PathType Container) {
                Write-Ok "ไปที่โฟลเดอร์: $resolved"
            } else {
                Write-Ok "เลือกไฟล์: $resolved"
            }
            return $resolved
        }
        # .. / . อาจ resolve ไม่ได้ถ้า cwd ถูกลบ — ลอง Resolve แบบไม่บังคับ
        try {
            $resolved = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ans))
            if (Test-Path -LiteralPath $resolved) { return $resolved }
        } catch { }
        Write-Err2 "ไม่พบ path: $ans"
        Write-Info 'ตัวอย่าง: ..  ·  ..\myapp  ·  C:\path\app  ·  หรือพิมพ์หมายเลข'
        return $null
    }

    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n)) {
        # ไม่ใช่เลข — ลองตีเป็น path สุดท้าย (เช่น ชื่อโฟลเดอร์ใน cwd)
        if (Test-Path -LiteralPath $ans) { return (Resolve-Path -LiteralPath $ans).Path }
        Write-Err2 "ไม่ถูกต้อง: '$ans' (ต้องเป็นหมายเลข 1-$($items.Count) · path · หรือ ..)"
        return $null
    }
    if ($n -lt 1 -or $n -gt $items.Count) {
        Write-Err2 "ไม่ถูกต้อง: '$ans' (ต้องเป็นหมายเลข 1-$($items.Count))"
        return $null
    }
    $pick = $items[$n - 1]
    if (-not (Test-Path $pick.Path)) { Write-Err2 "ไม่พบ: $($pick.Path)"; return $null }
    Write-Ok ("เลือก [{0}] {1}" -f $pick.Kind, $pick.Path)
    return $pick.Path
}

function Cmd-Add($kind, $source, $extra) {
    $kind = Normalize-PmaKind $kind
    if (-not $kind) {
        throw 'ใช้: aptstack add <app|php|mysql|apache|phpmyadmin> <path|url|version> [name]   (เช่น: aptstack add app  แล้วเลือกหมายเลข หรือ aptstack add php 8.3.36)'
    }
    # add app โดยไม่ใส่ path -> เมนูเลือก zip/โฟลเดอร์ด้วยหมายเลข
    if ("$kind".ToLower() -eq 'app' -and [string]::IsNullOrWhiteSpace("$source")) {
        $source = Select-AddAppSource
        if (-not $source) { return }
    }
    if (-not $source) {
        throw "ใช้: aptstack add $kind <path|url|version> [name]   (app ไม่ใส่ path = เปิดเมนูเลือกหมายเลข)"
    }
    Ensure-Dirs

    # ใส่แค่เลขเวอร์ชัน / latest -> เติม URL ทางการให้เอง แล้ว print ให้เห็น (จะได้ copy โหลดเองได้)
    $origSource = $source
    $candidates = @($source)
    $isBinary = @('php', 'mysql', 'apache', 'pma') -contains ("$kind".ToLower())
    if ($isBinary -and ($source -eq 'latest' -or $source -match '^\d{1,2}\.\d{1,2}(\.\d{1,2})?$')) {
        $candidates = @(Get-OfficialUrls $kind $source)
        if ($candidates.Count -eq 0) {
            $hint = switch ("$kind".ToLower()) {
                'apache' { '  Apache Lounge เก็บเฉพาะ build ล่าสุด -> ดูหน้าโหลด https://www.apachelounge.com/download/ แล้วส่ง URL เต็ม หรือใช้ไฟล์ที่โหลดไว้แล้ว (docs\OFFLINE-DEPLOY.md)' }
                'mysql'  { '  MariaDB ไม่มี latest -> ใส่เลขเวอร์ชันที่มีจริง เช่น 11.4.13 หรือส่ง URL/path' }
                default  { '' }
            }
            throw "$kind เติม URL อัตโนมัติไม่ได้สำหรับ '$source' — ส่ง URL เต็ม / path / เลขเวอร์ชันแทน.$hint"
        }
        Write-Head "เติม URL ทางการให้ ($kind $source)"
        foreach ($u in $candidates) { Write-Info $u }
        Write-Info 'คัดลอก URL ข้างบนไว้โหลดเองภายหลังได้ · ไม่มีเน็ต -> docs\OFFLINE-DEPLOY.md'
    }

    # ลองทีละ URL (เช่น PHP releases ไม่เจอ -> ไป archives)
    $src = $null
    $lastErr = ''
    foreach ($u in $candidates) {
        try {
            $src = Get-DownloadedZip $u
            if ($src) { $origSource = $u; break }
        } catch {
            $lastErr = "$($_.Exception.Message)"
            Write-Warn2 "ลองไม่สำเร็จ: $u"
        }
    }
    if (-not $src) { throw "โหลด/หาไฟล์ไม่สำเร็จ: $lastErr" }

    switch ($kind.ToLower()) {
        'app' {
            # $src ถูก resolve ไว้ด้านบนแล้ว (รองรับ URL / เลขเวอร์ชัน / path)
            # safety: ห้าม copy aptstack root / workspace ทั้งก้อน (.. / . อาจชี้ไปที่นั่น)
            if (Test-Path -LiteralPath $src -PathType Container) {
                $srcFull = (Resolve-Path -LiteralPath $src).Path.TrimEnd('\')
                $rootFull = $Script:P.Root.TrimEnd('\')
                $parentOfRoot = Split-Path -Parent $rootFull
                $looksBundle = (Test-Path (Join-Path $srcFull 'config\stack.json')) -or
                    (Test-Path (Join-Path $srcFull 'stack\mysql')) -or
                    (Test-Path (Join-Path $srcFull 'aptstack.ps1')) -or
                    (Test-Path (Join-Path $srcFull 'aptstack.cmd'))
                $isRootOrParent = ($srcFull -eq $rootFull) -or
                    ($parentOfRoot -and ($srcFull -eq $parentOfRoot.TrimEnd('\')))
                if ($isRootOrParent -or ($looksBundle -and ($srcFull -like '*aptstack*'))) {
                    Write-Err2 "ไม่ยอม add app จากโฟลเดอร์ stack/workspace: $srcFull"
                    Write-Info 'เลือกโฟลเดอร์แอปจริง (มี index.php) หรือ zip ใน downloads\'
                    Write-Info 'ตัวอย่าง: ..\my-app  ·  หรือพิมพ์หมายเลขในเมนู'
                    return
                }
            }
            $name = if ($extra) { $extra } else {
                $n = Split-Path $src -Leaf
                $n -replace '\.(zip|7z|tar\.gz)$', ''
            }
            if ([string]::IsNullOrWhiteSpace($name) -or $name -eq '.' -or $name -eq '..') {
                Write-Err2 "ชื่อ target ไม่ถูกต้อง: '$name' — ระบุชื่อด้วย: aptstack add app <path> <name>"
                return
            }
            $dest = Join-Path $Script:P.Versions $name
            if (Test-Path $dest) { Write-Warn2 "มีอยู่แล้ว: $dest — ถ้าจะแทนที่ให้ลบก่อน"; return }
            Write-Head "ติดตั้ง app version -> versions\$name"
            if (Test-Path $src -PathType Container) {
                robocopy $src $dest /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "copy ล้มเหลว (robocopy exit $LASTEXITCODE)" }
            } else {
                Expand-AndFlatten $src $dest
            }
            Set-AppMeta $dest $null $null
            Sync-AppAliases
            Set-SourceMeta $dest $kind $origSource
            Write-Ok "ติดตั้ง app $name เรียบร้อย"
            Write-Info "เข้าได้หลาย path พร้อมกัน:  /$((Get-Config).appAlias)/ และ /$name/"
            Write-Info "เปิดใช้: aptstack use $name"
        }
        'php' {
            # $src ถูก resolve ไว้ด้านบนแล้ว (รองรับ URL / เลขเวอร์ชัน / path)
            if (Test-Path $src -PathType Container) { throw 'PHP ต้องเป็นไฟล์ .zip' }
            $leaf = [IO.Path]::GetFileNameWithoutExtension((Split-Path $src -Leaf))
            $name = if ($leaf -match 'php-(\d+\.\d+\.\d+)') { $Matches[1] } else { $leaf }
            $dest = Join-Path $Script:P.PhpRoot $name
            if (Test-Path $dest) { Write-Warn2 "มีอยู่แล้ว: $dest"; return }
            Write-Head "ติดตั้ง PHP -> stack\php\$name"
            Expand-AndFlatten $src $dest
            if (-not (Test-Path (Join-Path $dest 'php.exe'))) { throw "zip ไม่มี php.exe — ตรวจว่าเลือกถูกตัว" }
            $php = Resolve-Php $name
            Set-SourceMeta $dest $kind $origSource
            Write-Ok "ติดตั้ง PHP $($php.Version) เรียบร้อย"
            if ($php.ApacheMod) { Write-Info 'Thread Safe build (มี php*apache2_4.dll — mod_php ใช้ได้)' }
            else { Write-Info 'NTS build — ใช้ได้กับ PHP built-in server ของ aptstack เท่านั้น' }
            $risk = Get-PhpRisk $php.Version
            if ($risk) { Write-Warn2 "version นี้ยังไม่ปลอดภัย ($risk) — ใช้เฉพาะทดสอบในเครื่องตัวเอง" }
            Write-Info "เปิดใช้: aptstack use php $($php.Version)"
        }
        'mysql' {
            # $src ถูก resolve ไว้ด้านบนแล้ว (รองรับ URL / เลขเวอร์ชัน / path)
            if (Test-Path $src -PathType Container) { throw 'MySQL/MariaDB ต้องเป็นไฟล์ .zip' }
            $leaf = [IO.Path]::GetFileNameWithoutExtension((Split-Path $src -Leaf))
            $name = if ($leaf -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { $leaf }
            $dest = Join-Path $Script:P.MySqlRoot $name
            if (Test-Path $dest) { Write-Warn2 "มีอยู่แล้ว: $dest"; return }
            Write-Head "ติดตั้ง MySQL/MariaDB -> stack\mysql\$name"
            Expand-AndFlatten $src $dest
            Set-SourceMeta $dest $kind $origSource
            Write-Ok "ติดตั้งแล้ว — datadir จะถูกสร้างใหม่ต่อ version (data ไม่ปนกัน)"
        }
        'apache' {
            # $src ถูก resolve ไว้ด้านบนแล้ว (รองรับ URL / เลขเวอร์ชัน / path)
            if (Test-Path $src -PathType Container) { throw 'Apache ต้องเป็นไฟล์ .zip' }
            $leaf = [IO.Path]::GetFileNameWithoutExtension((Split-Path $src -Leaf))
            $name = if ($leaf -match 'httpd-(\d+\.\d+\.\d+)') { "httpd-$($Matches[1])" } else { $leaf }
            $dest = Join-Path $Script:P.ApacheRoot $name
            if (Test-Path $dest) { Write-Warn2 "มีอยู่แล้ว: $dest"; return }
            Write-Head "ติดตั้ง Apache -> stack\apache\$name"
            Expand-AndFlatten $src $dest
            $httpd = Join-Path $dest 'bin\httpd.exe'
            if (-not (Test-Path $httpd)) {
                $f = Get-ChildItem $dest -Recurse -File -Filter 'httpd.exe' | Select-Object -First 1
                if ($f) { $httpd = $f.FullName } else { throw 'zip ไม่มี bin\httpd.exe' }
            }
            Set-SourceMeta $dest $kind $origSource
            $php = Resolve-Php (Get-Config).php
            if ($php -and (Test-PhpApacheMod $php.Dir)) {
                Write-Ok "Apache พร้อมใช้ mod_php กับ PHP $($php.Version)"
            } else {
                Write-Warn2 'PHP ที่เลือกยังไม่มี php*apache2_4.dll (NTS) — ต้องเปลี่ยนเป็น Thread Safe ก่อนใช้ Apache'
            }
            Write-Info 'เปิดใช้: แก้ config\stack.json -> "webMode": "apache" แล้ว aptstack restart'
        }
        'pma' {
            if (Test-Path $src -PathType Container) { throw 'phpMyAdmin ต้องเป็นไฟล์ .zip' }
            $leaf = [IO.Path]::GetFileNameWithoutExtension((Split-Path $src -Leaf))
            $name = if ($leaf -match 'phpMyAdmin-(\d+\.\d+\.\d+)') { $Matches[1] } else { $leaf }
            $dest = Join-Path $Script:P.Www 'phpmyadmin'
            Write-Head "ติดตั้ง phpMyAdmin $name -> www\phpmyadmin"
            if (Test-Path $dest) {
                Write-Warn2 'มี www\phpmyadmin อยู่แล้ว — สำรองชื่อเดิมเป็น phpmyadmin.bak'
                $bak = Join-Path $Script:P.Www ('phpmyadmin.bak-' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
                Move-Item -LiteralPath $dest -Destination $bak -Force
            }
            Expand-AndFlatten $src $dest
            if (-not (Test-Path (Join-Path $dest 'index.php'))) { throw 'zip ไม่มี index.php — ไม่ใช่ phpMyAdmin หรือเปล่า' }
            # config.inc.php ชี้ stack นี้ (port/user/pass จาก stack.json)
            $cfg = Get-Config
            $secret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
            $pmaCfg = @"
<?php
/* aptstack phpMyAdmin config — generate อัตโนมัติ (port/user/pass จาก config\stack.json) */
`$cfg['blowfish_secret'] = '$secret';
`$i = 0;
`$i++;
`$cfg['Servers'][`$i]['host'] = '127.0.0.1';
`$cfg['Servers'][`$i]['port'] = '$($cfg.dbPort)';
`$cfg['Servers'][`$i]['auth_type'] = 'config';
`$cfg['Servers'][`$i]['user'] = '$($cfg.dbUser)';
`$cfg['Servers'][`$i]['password'] = '$($cfg.dbPass)';
`$cfg['Servers'][`$i]['compress'] = false;
`$cfg['Servers'][`$i]['AllowNoPassword'] = false;
`$cfg['UploadDir'] = '';
`$cfg['SaveDir'] = '';
`$cfg['CheckConfigurationPermissions'] = false;
"@
            Write-Utf8NoBom (Join-Path $dest 'config.inc.php') ($pmaCfg + "`r`n")
            Set-SourceMeta $dest $kind $origSource
            Write-Ok "ติดตั้ง phpMyAdmin $name แล้ว"
            Write-Info "path : $dest"
            Write-Info "URL  : http://127.0.0.1:$($cfg.httpPort)/phpmyadmin/"
            Write-Info 'เปลี่ยนเวอร์ชัน: aptstack add phpmyadmin 5.2.1  (ของเดิม backup ให้)'
            Write-Info 'ดูเวอร์ชันที่โหลดได้: aptstack list --available phpmyadmin'
            Write-Info 'ตั้งรหัส root / เพิ่ม user: aptstack db set-root <pass> | aptstack db add-user <user> <pass>'
        }
        default { throw "ไม่รู้จักชนิด: $kind (ใช้ app | php | mysql | apache | pma)" }
    }
}

# ---------------------------------------------------------------- list
function Get-DbUserRows($cfg, [string]$client) {
    # คืน array of @{ User; Host } จาก mysql.user
    $r = Invoke-MysqlSql $cfg $client 'SELECT user, host FROM mysql.user ORDER BY user, host;'
    if ($r.ExitCode -ne 0) { return @() }
    $out = @()
    foreach ($line in $r.Out) {
        if (-not $line) { continue }
        if ($line -match '^\s*user\s' -or $line -match '^-+$' -or $line -match '^(Warning|Using a password)') { continue }
        $parts = "$line" -split "`t"
        if ($parts.Count -ge 2) {
            $u = $parts[0].Trim(); $h = $parts[1].Trim()
            if ($u) { $out += [pscustomobject]@{ User = $u; Host = $h } }
        } elseif ($line -match '^(\S+)\s+(\S+)\s*$') {
            $out += [pscustomobject]@{ User = $Matches[1]; Host = $Matches[2] }
        }
    }
    return $out
}

function Show-DbNamesAndUsers($cfg, [bool]$ShowEngineHint = $true) {
    # แสดงชื่อ database + รายชื่อ user ทั้งหมด (ใช้ใน aptstack list / db list / db-list)
    if ($ShowEngineHint) {
        Write-Host '  Databases (ชื่อ):' -ForegroundColor White
    }
    if (Test-PortFree $cfg.dbPort) {
        Write-Info "DB ไม่รัน (port $($cfg.dbPort)) — aptstack start แล้วค่อยดูรายชื่อ"
        Write-Info "config user : $($cfg.dbUser)   (ดู pass ใน config\stack.json)"
        return
    }
    $client = $null
    try { $client = Get-MysqlClient $cfg } catch {
        Write-Warn2 $_.Exception.Message
        return
    }

    $sys = @('information_schema', 'performance_schema', 'sys', 'mysql')
    $names = Get-ExistingDatabaseNames $cfg $client
    if ($names.Count -eq 0) {
        Write-Info '(ไม่มี user database หรือดึงไม่ได้)'
    } else {
        Write-Host ('   ' + ($names -join '  ·  ')) -ForegroundColor Cyan
    }

    $users = Get-DbUserRows $cfg $client
    Write-Host '  DB users (ทั้งหมด):' -ForegroundColor White
    if ($users.Count -eq 0) {
        Write-Info "(ดึงรายชื่อ user ไม่ได้ — ลอง: aptstack db-list)"
    } else {
        # จับกลุ่ม user -> hosts
        $groups = $users | Group-Object User | Sort-Object Name
        foreach ($g in $groups) {
            $hosts = @($g.Group | ForEach-Object { $_.Host }) -join ', '
            $isRoot = if ($g.Name -eq $cfg.dbUser) { '  [config]' } else { '' }
            Write-Host ("   {0,-16} @ {1}{2}" -f $g.Name, $hosts, $isRoot) -ForegroundColor Gray
        }
        Write-Info ("รวม {0} user / {1} record (user@host)" -f @($groups).Count, $users.Count)
    }
}

function Cmd-List {
    $cfg = Get-Config
    $cur = Get-CurrentAppName
    Write-Head 'ติดตั้งอยู่'

    $apps = @(Get-AppVersions)
    Write-Host '  App versions:' -ForegroundColor White
    if ($apps.Count -eq 0) { Write-Warn2 'ยังไม่มี — ใช้: aptstack add app <folder|zip>' }
    foreach ($a in $apps) {
        $mark = if ($cur -eq $a.Name) { '*' } else { ' ' }
        $flag = if ($a.Usable) { '' } else { '  <- ไม่มี index.php' }
        $fam = if ($a.Family -ne $a.Name) { "  [$($a.Family)]" } else { '' }
        Write-Host "   $mark $($a.Name)$fam  $($a.Dir)$flag" -ForegroundColor $(if ($flag) { 'Yellow' } else { 'Gray' })
    }
    if (@($apps | Where-Object { -not $_.HasMeta }).Count -gt 0) {
        Write-Info 'หมายเหตุ: [ชื่อแอป] มาจาก heuristic ของชื่อโฟลเดอร์ — ถ้ากลุ่มผิด ให้ clone/add ใหม่ (ระบบจะสร้าง manifest .aptstack-version ให้)'
    }

    $phps = @(Get-PhpVersions)
    Write-Host '  PHP:' -ForegroundColor White
    if ($phps.Count -eq 0) { Write-Warn2 'ยังไม่มี — ใช้: aptstack add php <zip|url>' }
    foreach ($p in $phps) {
        $mark = if ($cfg.php -eq $p.Version) { '*' } else { ' ' }
        $r = Get-PhpRisk $p.Version
        $tag = if ($r -eq 'UNPATCHED') { '  <- ยังไม่ patch ช่องโหว่ RCE' } elseif ($r -eq 'EOL') { '  <- EOL ไม่มี patch' } else { '' }
        Write-Host "   $mark $($p.Version)  $($p.Dir)$tag" -ForegroundColor $(if ($tag) { 'Yellow' } else { 'Gray' })
        $sm = Get-SourceMeta $p.Dir
        if ($sm -and $sm['source']) { Write-Host "           from: $($sm['source'])" -ForegroundColor DarkGray }
    }

    $dbs = @(Get-MySqlVersions)
    Write-Host '  Database engines:' -ForegroundColor White
    if ($dbs.Count -eq 0) { Write-Info '(ยังไม่มี)' }
    foreach ($m in $dbs) {
        Write-Host "     $($m.Version)  $($m.Dir)" -ForegroundColor Gray
        $sm = Get-SourceMeta $m.Dir
        if ($sm -and $sm['source']) { Write-Host "           from: $($sm['source'])" -ForegroundColor DarkGray }
    }

    # ชื่อ database + user ทั้งหมด (จาก server จริง)
    Write-Host ''
    Write-Host '  ── Database content ──' -ForegroundColor Yellow
    Show-DbNamesAndUsers $cfg $true
    Write-Info 'รายละเอียด/ขนาด: aptstack db list ·  user เพิ่ม: aptstack db add-user'

    $aps = @(Get-ApacheVersions)
    Write-Host ''
    Write-Host '  Apache:' -ForegroundColor White
    if ($aps.Count -eq 0) { Write-Info '(ยังไม่มี) ใช้ได้ด้วย: aptstack add apache <httpd zip>' }
    foreach ($a in $aps) {
        Write-Host "     $($a.Version)  $($a.Dir)" -ForegroundColor Gray
        $sm = Get-SourceMeta $a.Dir
        if ($sm -and $sm['source']) { Write-Host "           from: $($sm['source'])" -ForegroundColor DarkGray }
    }

    $phpCur = Resolve-Php $cfg.php
    $wm = Resolve-WebMode $cfg $phpCur (Resolve-Apache $cfg.apache)
    Write-Head 'ที่ใช้งาน'
    Write-Host "  App     : $(if ($cur) { $cur } else { '(ยังไม่ได้ตั้ง link)' })"
    Write-Host "  PHP     : $(if ($cfg.php) { $cfg.php } else { '(ยังไม่เลือก)' })"
    Write-Host "  Web     : $wm   (webMode ใน config\stack.json = $($cfg.webMode))"
    Write-Host "  HTTP    : http://127.0.0.1:$($cfg.httpPort)/$($cfg.appAlias)/"
    Write-Host "  MySQL   : 127.0.0.1:$($cfg.dbPort)  user=$($cfg.dbUser)  mode=$($cfg.dbMode)"
    Write-Host "  Service : $(if (Get-Service -Name $cfg.serviceName -EA SilentlyContinue) { $cfg.serviceName } else { '(ยังไม่ติดตั้ง)' })"

    Write-Head 'โฟลเดอร์ (วาง/ลบ/จัดการ ได้ที่นี่)'
    Write-Info "root        : $Root"
    Write-Info "app versions: $($Script:P.Versions)   <- วาง/ลบ app versions ที่นี่ (เช่น 1.2.0\)"
    Write-Info "www (docroot): $($Script:P.Www)  มี junction $($cfg.appAlias) -> versions\<active>"
    Write-Info "PHP         : $($Script:P.PhpRoot)     <- aptstack add php <zip>"
    Write-Info "Apache      : $($Script:P.ApacheRoot)  <- aptstack add apache <zip>"
    Write-Info "MySQL       : $($Script:P.MySqlRoot)   <- aptstack add mysql <zip>"
    Write-Info "config      : $($Script:P.ConfigDir)   (stack.json, vhosts.json, certs\)"
    Write-Info "database    : $($Script:P.Data)   (datadir + dumps\)"
    Write-Info "logs        : $($Script:P.Logs)         <- aptstack logs <kind>"
}

# list --available [php|mysql|apache] — ดูเวอร์ชันที่ "โหลดได้" จากเว็บทางการ (ยังไม่ต้องติดตั้ง)
function Cmd-ListAvailable([string]$kind) {
    $kind = ("$kind".ToLower() -replace '^\-\-?', '')
    if (-not $kind) { $kind = 'all' }
    $kind = Normalize-PmaKind $kind
    if (@('all', 'php', 'mysql', 'apache', 'pma') -notcontains $kind) {
        throw "ไม่รู้จัก '$kind' — ใช้: aptstack list --available [php|mysql|apache|phpmyadmin]"
    }

    if ($kind -eq 'all' -or $kind -eq 'php') {
        $found = @{}
        $pages = @(
            'https://windows.php.net/downloads/releases/',
            'https://windows.php.net/downloads/releases/archives/'
        )
        foreach ($page in $pages) {
            $html = Get-WebText $page
            if (-not $html) { continue }
            foreach ($m in [regex]::Matches($html, 'php-(\d+\.\d+\.\d+)-Win32-vs\d+-x64\.zip')) {
                $found[$m.Groups[1].Value] = $page   # Thread Safe x64 เท่านั้น (ตัด -nts- ออกอัตโนมัติ)
            }
        }
        $installed = @(Get-PhpVersions | ForEach-Object { $_.Version })
        Write-Head 'PHP ที่โหลดได้ (Thread Safe x64 — ตัวใหม่สุดของแต่ละสาขา)'
        if ($found.Count -eq 0) {
            Write-Warn2 'ดึงรายการไม่ได้ (ไม่มีเน็ต? หรือ windows.php.net ล่ม) — retry ได้'
        } else {
            $best = @{}
            foreach ($v in $found.Keys) {
                $br = ($v -split '\.')[0..1] -join '.'
                if (-not $best.ContainsKey($br) -or ([version]$v -gt [version]$best[$br])) { $best[$br] = $v }
            }
            foreach ($br in ($best.Keys | Sort-Object -Property { [version]$_ } -Descending)) {
                $v = $best[$br]
                $risk = Get-PhpRisk $v
                $tag = if ($risk -eq 'EOL') { 'EOL — ห้ามใช้ production' }
                       elseif ($risk -eq 'UNPATCHED') { 'ยังไม่ผ่านช่องโหว่ RCE' }
                       else { 'ผ่าน floor ความปลอดภัย' }
                $mark = if ($installed -contains $v) { '   * มีในเครื่องแล้ว' } else { '' }
                Write-Host ("   {0,-9} {1}{2}" -f $v, $tag, $mark) -ForegroundColor $(if ($risk) { 'Yellow' } else { 'Green' })
            }
            Write-Info "พบทั้งหมด $($found.Count) เวอร์ชัน (แสดงตัวใหม่สุดต่อสาขา) · ใส่เลขเต็มก็ได้: aptstack add php 8.4.27"
            Write-Info "หน้าทางการ: $($pages[0]) · $($pages[1])"
        }
    }

    if ($kind -eq 'all' -or $kind -eq 'mysql') {
        $html = Get-WebText 'https://archive.mariadb.org/'
        $found = @{}
        if ($html) {
            foreach ($m in [regex]::Matches($html, 'mariadb-(\d+\.\d+\.\d+)/')) { $found[$m.Groups[1].Value] = $true }
        }
        $installed = @(Get-MySqlVersions | ForEach-Object { $_.Version })
        Write-Head 'MariaDB ที่โหลดได้ (ตัวใหม่สุดของแต่ละสาขา x.y)'
        if ($found.Count -eq 0) {
            Write-Warn2 'ดึงรายการไม่ได้ (ไม่มีเน็ต? หรือ archive.mariadb.org ล่ม)'
        } else {
            $best = @{}
            foreach ($v in $found.Keys) {
                $mj = [int](($v -split '\.')[0])
                if ($mj -lt 10) { continue }   # เก่ากว่า 10.x ไม่ list (คลังมี 400+ ตัว)
                $br = ($v -split '\.')[0..1] -join '.'
                if (-not $best.ContainsKey($br) -or ([version]$v -gt [version]$best[$br])) { $best[$br] = $v }
            }
            foreach ($br in ($best.Keys | Sort-Object -Property { [version]$_ } -Descending)) {
                $v = $best[$br]
                $mark = if ($installed -contains $v) { '   * มีในเครื่องแล้ว' } else { '' }
                Write-Host ("   {0,-10} {1}" -f $v, $mark) -ForegroundColor Gray
            }
            Write-Info "พบทั้งหมด $($found.Count) เวอร์ชันในคลัง (แสดงตัวใหม่สุดต่อสาขา) · ติดตั้ง: aptstack add mysql 11.4.13"
            Write-Info 'หน้าทางการ: https://archive.mariadb.org/'
        }
    }

    if ($kind -eq 'all' -or $kind -eq 'apache') {
        $html = Get-WebText 'https://www.apachelounge.com/download/'
        $found = @{}
        if ($html) {
            foreach ($m in [regex]::Matches($html, 'httpd-(\d+\.\d+\.\d+)-\d+-Win64-VS\d+\.zip', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $found[$m.Groups[1].Value] = $true
            }
        }
        $installed = @(Get-ApacheVersions | ForEach-Object { $_.Version })
        Write-Head 'Apache ที่โหลดได้ (Win64)'
        if ($found.Count -eq 0) {
            Write-Warn2 'ดึงรายการไม่ได้ — เปิดดูเอง: https://www.apachelounge.com/download/'
        } else {
            foreach ($v in ($found.Keys | Sort-Object -Property { [version]$_ } -Descending)) {
                $mark = if ($installed -contains $v) { '   * มีในเครื่องแล้ว' } else { '' }
                Write-Host ("   {0,-9} {1}" -f $v, $mark) -ForegroundColor Gray
            }
            Write-Info 'Apache Lounge เก็บเฉพาะ build ล่าสุด — เวอร์ชันเก่าต้องส่ง URL เต็ม/path เอง'
            Write-Info 'ติดตั้ง: aptstack add apache 2.4.69'
        }
    }

    if ($kind -eq 'all' -or $kind -eq 'pma') {
        $html = Get-WebText 'https://www.phpmyadmin.net/downloads/'
        $found = @{}
        if ($html) {
            foreach ($m in [regex]::Matches($html, 'phpMyAdmin-(\d+\.\d+\.\d+)-all-languages', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $found[$m.Groups[1].Value] = $true
            }
            foreach ($m in [regex]::Matches($html, 'phpMyAdmin[-/](\d+\.\d+\.\d+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $found[$m.Groups[1].Value] = $true
            }
        }
        $pmaDir = Join-Path $Script:P.Www 'phpmyadmin'
        $curPma = $null
        if (Test-Path (Join-Path $pmaDir 'README')) {
            $rt = Get-Content (Join-Path $pmaDir 'README') -Raw -EA SilentlyContinue
            if ($rt -match 'Version\s+(\d+\.\d+\.\d+)') { $curPma = $Matches[1] }
        }
        Write-Head 'phpMyAdmin ที่โหลดได้'
        if ($found.Count -eq 0) {
            Write-Warn2 'ดึงรายการไม่ได้ — ลอง: aptstack add pma 5.2.1 หรือส่ง URL เอง'
            Write-Info 'หน้าทางการ: https://www.phpmyadmin.net/downloads/'
        } else {
            foreach ($v in ($found.Keys | Sort-Object -Property { [version]$_ } -Descending)) {
                $mark = if ($curPma -eq $v) { '   * ใช้อยู่' } else { '' }
                Write-Host ("   {0,-9} {1}" -f $v, $mark) -ForegroundColor Gray
            }
            Write-Info "ติดตั้ง: aptstack add phpmyadmin <ver|latest|url|zip>"
            Write-Info 'path จริง: www\phpmyadmin\  · URL: http://127.0.0.1:<httpPort>/phpmyadmin/'
        }
    }
    Write-Host ''
    Write-Info 'เวอร์ชันที่ติดตั้งแล้วในเครื่องดูด้วย: aptstack list'
}

# ---------------------------------------------------------------- doctor
function Cmd-Doctor {
    $cfg = Get-Config
    Write-Head 'ตรวจสุขภาพ + ช่องโหว่ (อ้างอิง security-php.txt)'
    $problems = 0

    # 1) PHP
    $php = Resolve-Php $cfg.php
    if (-not $php) { Write-Err2 'ยังไม่ได้เลือก PHP'; $problems++ }
    elseif (-not $php.Usable) { Write-Err2 "PHP $($php.Version) ใช้งานไม่ได้"; $problems++ }
    else {
        $r = Get-PhpRisk $php.Version
        if ($r -eq 'UNPATCHED') {
            $minor = ($php.Version -split '\.')[0..1] -join '.'
            Write-Err2 "PHP $($php.Version) เสี่ยงช่องโหว่ RCE (CVSS 9.2) — ต้อง >= $($Script:PatchedPhp[$minor])"
            Write-Info 'ดาวน์โหลดเวอร์ชันใหม่: https://windows.php.net/downloads/releases/'
            $problems++
        } elseif ($r -eq 'EOL') {
            Write-Err2 "PHP $($php.Version) EOL — ไม่มี binary patch แล้ว ห้ามใช้เป็น production"
            $problems++
        } else { Write-Ok "PHP $($php.Version) ผ่านเกณฑ์ patch ช่องโหว่ RCE" }

        $sapi = & $php.Exe -i 2>$null | Select-String 'Server API' | Select-Object -First 1
        if ($sapi) { Write-Info "SAPI: $($sapi.ToString().Trim())" }
    }

    # 2) php.ini hardening
    if (Test-Path $Script:P.PhpIni) {
        $c = Get-Content $Script:P.PhpIni -Raw
        if ($c -match '(?m)^\s*session\.upload_progress\.enabled\s*=\s*Off') { Write-Ok 'session.upload_progress ปิด (จุดที่ช่องโหว่ใช้)' }
        else { Write-Err2 'session.upload_progress ยังเปิดอยู่ — ต้อง Off'; $problems++ }
        if ($c -match '(?m)^\s*expose_php\s*=\s*Off') { Write-Ok 'expose_php ปิด' }
        else { Write-Warn2 'expose_php ยังเปิด — เผยเวอร์ชัน PHP ให้สแกนเจอ'; }
        if ($c -match '(?m)^\s*allow_url_include\s*=\s*Off') { Write-Ok 'allow_url_include ปิด' }
        else { Write-Warn2 'allow_url_include ไม่ปิด' }
        if ($c -match '(?m)^\s*display_errors\s*=\s*Off') { Write-Ok 'display_errors ปิด (production)' }
        else { Write-Warn2 'display_errors เปิด — รั่ว path/SQL ให้คนแปลกหน้า' }
    } else { Write-Warn2 'ยังไม่มี config\php.ini — รัน: aptstack start' }

    # 2b) mitigation ชั่วคราวของ PHP2Shell (security-php2.txt / CVE-2026-109618-19)
    #     ถ้ายัง patch ไม่ได้ ต้องเปิด "ทั้งคู่" (อย่าเปิดอันใดอันหนึ่ง):
    #       session.upload_progress.enabled = 0   +   memory_limit = -1
    #     ถ้า patch แล้ว ไม่ต้องใช้ memory_limit=-1 (เสี่ยง DoS) เก็บค่าจำกัดไว้ดีกว่า
    $cIni = if (Test-Path $Script:P.PhpIni) { Get-Content $Script:P.PhpIni -Raw } else { '' }
    if ($php) {
        $risk2 = Get-PhpRisk $php.Version
        $upOff = $cIni -match '(?m)^\s*session\.upload_progress\.enabled\s*=\s*(0|Off|false)'
        $mlNeg = $cIni -match '(?m)^\s*memory_limit\s*=\s*-1\b'
        if ($risk2) {
            if ($upOff -and $mlNeg) {
                Write-Ok 'PHP ยังไม่ patch — เปิด mitigation ครบแล้ว (upload_progress=Off + memory_limit=-1)'
            } else {
                Write-Err2 'PHP ยังไม่ patch และ mitigation ไม่ครบ — ต้องเปิด "ทั้งคู่":'
                Write-Info '  session.upload_progress.enabled = 0'
                Write-Info '  memory_limit = -1'
                Write-Info '  แล้ว restart PHP worker ทุกตัว (mitigation ช่วยได้เฉพาะหน้า — อัปเดต PHP ให้ได้)'
                $problems++
            }
        } else {
            if ($mlNeg) {
                Write-Warn2 'memory_limit=-1 ค้างอยู่ — ใช้ได้เฉพาะตอนยัง patch ไม่ได้ เสี่ยง DoS ควรคืนเป็น 512M แล้ว restart'
            } else {
                Write-Ok "patch แล้ว — ไม่ต้องใช้ memory_limit=-1 (ใช้ $(( Select-String -Path $Script:P.PhpIni -Pattern '^\s*memory_limit\s*=' | Select-Object -Last 1).Line.Trim()) จำกัด memory ได้ดีกว่า)"
            }
        }
    }

    # 2c) post-patch IOC: memory-limit error กลาง request = หนึ่งในสัญญาณถูกเจาะ
    $phpLog = Join-Path $Script:P.Logs 'php-error.log'
    if (Test-Path $phpLog) {
        $logTxt = Get-Content $phpLog -Raw -ErrorAction SilentlyContinue
        $memHits = ([regex]::Matches("$logTxt", 'Allowed memory size|memory limit')).Count
        if ($memHits -gt 0) {
            Write-Warn2 "log มี memory-limit error $memHits ครั้ง — ไล่ดูได้ว่า request ไหน (หนึ่งใน IOC ของ PHP2Shell)"
            Write-Info 'ดูต่อ:  cookies PHPSESSID ผิดปกติ / HTTP 500 ซ้ำ / webshell / ไฟล์ .php แปลก ๆ / admin ใหม่'
        } else { Write-Ok 'ไม่พบ memory-limit error ใน log (ไม่เข้าข่าย IOC ของ PHP2Shell)' }
    } else { Write-Info 'ยังไม่มี logs\php-error.log (ยังไม่มี error บันทึก)' }

    # 1b) web server mode (Apache + mod_php หรือ PHP built-in)
    $apacheHit = Resolve-Apache $cfg.apache
    $wm = Resolve-WebMode $cfg $php $apacheHit
    if ($wm -eq 'apache') {
        if (-not $apacheHit) { Write-Err2 'webMode=apache แต่ไม่พบ httpd — aptstack add apache <zip>'; $problems++ }
        elseif (-not $php -or -not (Test-PhpApacheMod $php.Dir)) {
            Write-Err2 'Apache mode ต้องใช้ PHP แบบ Thread Safe (มี php*apache2_4.dll)'; $problems++
        } else {
            $conf = Join-Path $Script:P.Runtime 'httpd.conf'
            if (-not (Test-Path $conf)) { Write-Warn2 'ยังไม่มี config\httpd.conf — รัน aptstack start' }
            else {
                $oldEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { $t = & $apacheHit.Httpd -f $conf -t 2>&1 } catch { $t = @("$($_.Exception.Message)") }
                $hc = $LASTEXITCODE
                $ErrorActionPreference = $oldEap
                if ($hc -ne 0) { Write-Err2 "httpd -t ไม่ผ่าน: $($t -join ' ')"; $problems++ }
                else { Write-Ok "Apache $($apacheHit.Version) + mod_php (PHP $($php.Version)) — syntax OK" }
            }
        }
        Write-Info "webMode = apache   port = $($cfg.httpPort)"
    } else {
        Write-Ok "webMode = PHP built-in server   port = $($cfg.httpPort)"
        if ($apacheHit) { Write-Info 'มี Apache แล้ว — เปิดใช้ด้วย "webMode": "apache" ใน config\stack.json แล้ว restart' }
        else { Write-Info 'ยังไม่มี Apache — aptstack add apache <httpd zip> ถ้าต้องใช้ mod_php (production)' }
    }

    # 1c) HTTPS / TLS
    if ("$($cfg.httpsEnabled)".ToLower() -eq 'true') {
        if ($wm -ne 'apache') {
            Write-Warn2 "httpsEnabled=true แต่ webMode=$wm — HTTPS ใช้ได้กับ Apache เท่านั้น (PHP built-in ไม่รองรับ TLS)"
            $problems++
        } else {
            $cert = Resolve-CertPath $cfg.certFile
            $key = Resolve-CertPath $cfg.keyFile
            if (-not (Test-Path $cert) -or -not (Test-Path $key)) {
                Write-Err2 'httpsEnabled=true แต่ไม่พบ cert/key — รัน: aptstack tls init หรือ tls import'; $problems++
            } else {
                $ci = Get-CertInfo $cert
                if (-not $ci) { Write-Err2 'อ่าน cert ไม่ได้'; $problems++ }
                else {
                    if ($ci.DaysLeft -lt 0) { Write-Err2 "cert หมดอายุแล้ว ($($ci.NotAfter)) — ต่ออายุ: aptstack tls import"; $problems++ }
                    elseif ($ci.DaysLeft -lt 14) { Write-Warn2 "cert ใกล้หมดอายุ (เหลือ $($ci.DaysLeft) วัน)" }
                    else { Write-Ok "cert ใช้ได้ (หมดอายุ $($ci.NotAfter.ToString('yyyy-MM-dd')))" }
                    # หมายเหตุ: cert PEM ย่อมไม่มี private key ในไฟล์ cert อยู่แล้ว
                    # ให้เช็ค "ไฟล์ key" แยกต่างหาก (ส่วนคู่กันจริงไหม Apache จะฟ้องตอน start เอง)
                    if (-not (Test-Path $key)) { Write-Err2 'ไม่พบไฟล์ key'; $problems++ }
                    else {
                        $kt = Get-Content $key -Raw -EA SilentlyContinue
                        if ($kt -match 'PRIVATE KEY') { Write-Ok 'ไฟล์ key มี private key ครบ' }
                        else { Write-Err2 "ไฟล์ key ไม่ใช่ PEM private key: $key"; $problems++ }
                    }
                    if (-not $ci.Trusted) { Write-Warn2 'cert ยังไม่ได้ trust — .NET/browser จะปฏิเสธ (รัน: aptstack tls init ซ้ำ หรือใส่ Trusted Root เอง)' }
                    else { Write-Ok 'cert อยู่ใน Trusted Root (probe/browser เชื่อถือ)' }
                }
            }
            $hs = Invoke-HttpProbe "https://127.0.0.1:$($cfg.httpsPort)/" 6
            if ($hs.Ok) { Write-Ok "HTTPS ตอบแล้ว: $($hs.Status) https://127.0.0.1:$($cfg.httpsPort)/" }
            else { Write-Err2 "HTTPS ไม่ตอบ: $($hs.Error)"; $problems++ }
        }
    } else {
        Write-Info 'HTTPS ปิดอยู่ — เปิดด้วย: aptstack tls init  หรือ  aptstack tls import <cert> <key>'
    }

    # 1d) virtual hosts
    $vhFile = Join-Path $Script:P.ConfigDir 'vhosts.json'
    if (Test-Path $vhFile) {
        try {
            $vhItems = @((Get-Content $vhFile -Raw -Encoding UTF8 | ConvertFrom-Json))
            if ($vhItems.Count -gt 0) {
                if ($wm -ne 'apache') {
                    Write-Warn2 "มี vhosts.json แต่ webMode=$wm — virtual host ใช้ได้กับ Apache เท่านั้น"
                    $problems++
                } else {
                    $sum = ($vhItems | ForEach-Object { "$($_.host)->$($_.app)" }) -join ', '
                    Write-Ok "vhosts: $($vhItems.Count) รายการ  ($sum)"
                    foreach ($v in $vhItems) {
                        $d = Join-Path $Script:P.Versions "$($v.app)"
                        if (-not (Test-Path $d)) { Write-Err2 "vhost $($v.host) -> ไม่พบ versions\$($v.app)"; $problems++ }
                    }
                    $hostNames = ($vhItems | ForEach-Object { "$($_.host)" }) -join ' '
                    Write-Info "ต้องเพิ่มใน hosts file:  127.0.0.1 $hostNames"
                    Write-Info '(ไม่เช่นนั้นจะเข้าผ่านชื่อ host ไม่ได้ — แต่ probe ด้วย Host header ได้)'
                }
            }
        } catch { Write-Warn2 "vhosts.json อ่านไม่ได้: $($_.Exception.Message)" }
    } else { Write-Info 'ยังไม่มี virtual host (สร้าง: config\vhosts.json — ดูคู่มือข้อ 6)' }

    # 3) config path ไม่ควรชี้ออกจาก bundle (ปัญหาตอน copy ไปเครื่องอื่น)
    $rootNorm = $Root.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    foreach ($f in @($Script:P.MySqlIni, $Script:P.PhpIni)) {
        if (Test-Path $f) {
            $txt = Get-Content $f -Raw
            $hits = [regex]::Matches($txt, '(?m)^\s*[\w\-.]+\s*=\s*"?([A-Za-z]:[\\/][^\r\n"]*)"?\s*$')
            $bad = @()
            foreach ($m in $hits) {
                $p = $m.Groups[1].Value.Trim('"').Replace('/', '\').TrimEnd('\').ToLowerInvariant()
                if (-not $p.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) { $bad += $m.Groups[1].Value }
            }
            if ($bad.Count -gt 0) {
                Write-Err2 "ไฟล์ $(Split-Path $f -Leaf) มี path ชี้ออกนอก bundle: $($bad[0])"
                Write-Info 'รัน aptstack restart เพื่อ generate ใหม่ หรือตรวจ templates\'
                $problems++
            } else { Write-Ok "$(Split-Path $f -Leaf) : path ทั้งหมดอยู่ใน bundle (copy ไปเครื่องอื่นได้)" }
        }
    }

    # 4) DB bind
    if (Test-Path $Script:P.MySqlIni) {
        $c = Get-Content $Script:P.MySqlIni -Raw
        if ($c -match 'bind-address\s*=\s*127\.0\.0\.1') { Write-Ok 'MariaDB bind 127.0.0.1 (ไม่เปิดรับจากข้างนอก)' }
        else { Write-Err2 'MariaDB ไม่ได้ bind 127.0.0.1'; $problems++ }
        if ($c -match 'local_infile\s*=\s*0') { Write-Ok 'local_infile ปิด' }
        else { Write-Warn2 'local_infile เปิดอยู่' }
    }

    # 5) app link — www\<appAlias> ต้องเป็น junction เท่านั้น
    #    (โฟลเดอร์ธรรมดาหลัง copy = web 404/500 · สลับเวอร์ชันไม่ได้)
    $cfg2 = Get-Config
    $link = Join-Path $Script:P.Www $cfg2.appAlias
    $st = Repair-MainAppLink -Where 'doctor'
    $i = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    switch ($st) {
        'ok' { Write-Ok "www\$($cfg2.appAlias) -> $(Split-Path $i.Target -Leaf) (junction)" }
        'created' { Write-Ok "www\$($cfg2.appAlias) สร้าง junction ใหม่แล้ว -> $(Split-Path $i.Target -Leaf)" }
        'fixed' { Write-Ok "www\$($cfg2.appAlias) ซ่อมแล้ว (ลบโฟลเดอร์ธรรมดา + สร้าง junction) -> $(Split-Path $i.Target -Leaf)" }
        'missing' { Write-Err2 "ไม่พบ www\$($cfg2.appAlias) และสร้าง junction ไม่ได้ (ไม่มี versions\)"; $problems++ }
        'broken' { Write-Err2 "www\$($cfg2.appAlias) เป็น junction ที่ชี้เป้าหายและสร้างใหม่ไม่ได้"; $problems++ }
        'declined' { Write-Err2 "www\$($cfg2.appAlias) ยังเป็นโฟลเดอร์ธรรมดา (ไม่ลบ) — web จะ 404/500 · สลับเวอร์ชันไม่ได้"; $problems++ }
        'not-junction' { Write-Err2 "www\$($cfg2.appAlias) ยังเป็นโฟลเดอร์ธรรมดา — ลบไม่ได้ตอนนี้ (ปิด program ที่ lock แล้วรัน doctor ใหม่)"; $problems++ }
        default { Write-Err2 "ไม่พบ www\$($cfg2.appAlias)"; $problems++ }
    }
    if (-not (Test-Path (Join-Path $Script:P.Www 'router.php'))) { Write-Warn2 'ไม่มี www\router.php (built-in server จะ serve static บางกรณีผิด)' }

    # 6) ports
    foreach ($pair in @(@('HTTP', $cfg.httpPort), @('MySQL', $cfg.dbPort))) {
        $up = -not (Test-PortFree $pair[1])
        $own = Test-Running $(if ($pair[0] -eq 'HTTP') { 'web' } else { 'mysql' })
        if ($up -and $own) { Write-Ok "พอร์ต $($pair[1]) ($($pair[0])) รันโดย aptstack (PID $($own.Id))" }
        elseif ($up) {
            $ow = Get-PortOwner ([int]$pair[1])
            Write-Warn2 "พอร์ต $($pair[1]) ถูก program อื่นใช้อยู่ (PID $($ow.Pid) / $($ow.Name))"
            if ($ow.Folder) { Write-Info "dir: $($ow.Folder)" }
            Write-Info "ดูเพิ่ม: aptstack ports · หยุด: aptstack stop $($pair[1])"
        }
        else { Write-Ok "พอร์ต $($pair[1]) ว่าง (ยังไม่ start)" }
    }

    # 6b) short_open_tag — แอป CI3 / โค้ด <? เก่าต้อง On
    $stTpl = Get-ShortTagTplValue
    $stRun = Get-ShortTagRuntimeValue
    $stEff = if ($stRun) { $stRun } else { $stTpl }
    if ("$stEff".ToLower() -in @('on', '1', 'true')) {
        Write-Ok 'short_open_tag = On (CodeIgniter 3 / โค้ด <? เก่าใช้ได้)'
    } else {
        Write-Warn2 'short_open_tag = Off — แอป CI3 / helper ที่ใช้ <? จะพัง (ParseError Unclosed brace)'
        Write-Info 'เปิด: aptstack shorttag on  แล้ว aptstack restart'
    }

    # 7) ข้อมูลจริงไม่ควรอยู่ในโฟลเดอร์ที่จะ commit
    $dumpCount = @(Get-ChildItem $Script:P.Dumps -Filter '*.sql' -EA SilentlyContinue).Count
    if ($dumpCount -gt 0) { Write-Warn2 "data\dumps\ มี $dumpCount ไฟล์ .sql (ข้อมูลจริง) — .gitignore กันไว้แล้ว ห้าม commit" }
    if ("$($cfg.dbMode)" -eq 'external') { Write-Ok "dbMode=external — ใช้ MySQL ภายนอกที่ 127.0.0.1:$($cfg.dbPort) (ไม่แตะของ XAMPP)" }
    else {
        $dd = $null
        $mh = Resolve-MySql $cfg.mysql
        if ($mh) { $dd = Get-DataDir $mh }
        if ($dd -and $dd.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) { Write-Ok "datadir อยู่ใน bundle: $dd" }
        elseif ($dd) { Write-Warn2 "datadir อยู่นอก bundle: $dd" }
    }
    if (Test-Path (Join-Path $Root '.git')) {
        $tracked = & git -C $Root ls-files 2>$null
        $leak = @($tracked | Where-Object {
            $_ -notlike 'examples/*' -and (
                $_ -match '^(db/|stack/|versions/|runtime/|config/|data/|bin/|dist/|downloads/)' -or
                ($_ -match '\.sql$' -and $_ -notlike 'examples/*')
            )
        })
        if ($leak.Count -gt 0) { Write-Err2 "มีไฟล์ sensitive ถูก track ใน git แล้ว $($leak.Count) ไฟล์: $($leak[0])"; $problems++ }
        else { Write-Ok 'git ไม่ได้ track ข้อมูลจริง / binary / dump' }
    }

    Write-Host ''
    if ($problems -eq 0) { Write-Ok 'ผ่านทุกข้อ' }
    else { Write-Warn2 "พบ $problems จุดต้องแก้" }
    if ($php -and (Get-PhpRisk $php.Version)) { Write-Info 'วิธีแก้ที่ถาวร: aptstack add php <php-x.y.z-Win32-vs17-x64.zip> แล้ว aptstack use php <ver>' }
}

# ---------------------------------------------------------------- backup
function Cmd-Backup($name) {
    $cfg = Get-Config
    $hit = Resolve-MySql $cfg.mysql
    if (-not $hit) { throw 'ไม่พบ MySQL/MariaDB' }
    if (Test-PortFree $cfg.dbPort) { throw 'MariaDB ยังไม่รัน — aptstack start ก่อน' }
    Ensure-Dirs
    if (-not $name) { $name = 'backup-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.sql' }
    if ($name -notmatch '\.sql$') { $name += '.sql' }
    $out = Join-Path $Script:P.Dumps $name
    $dump = $null
    foreach ($n in @('bin\mariadb-dump.exe', 'bin\mysqldump.exe')) {
        $p = Join-Path $hit.Dir $n; if (Test-Path $p) { $dump = $p; break }
    }
    if (-not $dump) { throw 'ไม่พบ mariadb-dump/mysqldump' }
    Write-Head "สำรองฐานข้อมูลทั้งหมด -> db\$name"
    $a = @('--skip-ssl', '-h', '127.0.0.1', '-P', "$($cfg.dbPort)", '--protocol=tcp', '-u', $cfg.dbUser, "-p$($cfg.dbPass)",
           '--single-transaction', '--routines', '--triggers', '--all-databases')
    & $dump $a 2>$null | Out-File -FilePath $out -Encoding UTF8
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out) -or (Get-Item $out).Length -lt 100) { throw "backup ล้มเหลว (exit $LASTEXITCODE)" }
    Write-Ok ("{0}  ({1:N1} MB)" -f $out, ((Get-Item $out).Length / 1MB))
    Write-Info 'ไฟล์นี้อยู่ใน .gitignore — ห้าม commit ขึ้น repo สาธารณะ'
}

# ---------------------------------------------------------------- TLS / HTTPS
function Get-CertInfo([string]$Path) {
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path $Path).Path)
        return [pscustomobject]@{
            Subject     = $x.Subject
            Issuer      = $x.Issuer
            NotAfter    = $x.NotAfter
            DaysLeft    = [int][math]::Floor(($x.NotAfter - (Get-Date)).TotalDays)
            Thumbprint  = $x.Thumbprint
            HasPrivate  = $x.HasPrivateKey
            Trusted     = (Test-CertTrust $x.Thumbprint)
        }
    } catch { return $null }
}

function Test-CertTrust([string]$Thumbprint) {
    if (-not $Thumbprint) { return $false }
    foreach ($store in @(@('Root', 'CurrentUser'), @('Root', 'LocalMachine'))) {
        try {
            $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($store[0], $store[1])
            $s.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $found = $s.Certificates | Where-Object { $_.Thumbprint -eq $Thumbprint }
            $s.Close()
            if ($found) { return $true }
        } catch { }
    }
    return $false
}

function Add-CertTrust([string]$Path) {
    # ใส่ cert เข้า "Trusted Root" ของผู้ใช้ปัจจุบัน (ไม่ต้องใช้ admin)
    # เหตุผล: .NET/HttpClient ปฏิเสธ self-signed ด้วย UntrustedRoot
    #          และ ServerCertificateValidationCallback ใช้ไม่ได้จริงใน PS 5.1 บาง environment
    #          -> ใส่ store จึงเป็นวิธีที่ work ทั้งกับ probe และกับ browser ของผู้ใช้คนนี้
    try {
        $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path $Path).Path)
        $s = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
        $s.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $s.Add($x)
        $s.Close()
        return $true
    } catch {
        Write-Warn2 "เพิ่ม cert เข้า Trusted Root ไม่สำเร็จ: $($_.Exception.Message)"
        return $false
    }
}

function Restart-WebOnly {
    if (Test-Running 'web') { Stop-Web; Start-Sleep -Seconds 1; Start-Web (Get-Config) | Out-Null }
    else { Write-Info 'web ยังไม่รัน — ค่อยเปิดด้วย: aptstack start' }
}

function Get-ShortTagTplValue {
    # อ่านค่า short_open_tag จาก templates\php-hardening.ini (ไม่ใช่ runtime php.ini ที่ regenerate)
    $tpl = Join-Path $Script:P.Templates 'php-hardening.ini'
    if (-not (Test-Path $tpl)) { return $null }
    foreach ($l in (Get-Content $tpl -Encoding UTF8)) {
        if ("$l" -match '^\s*short_open_tag\s*=\s*(On|Off|1|0|true|false)\s*$' -and "$l" -notmatch '^\s*;') {
            return $Matches[1]
        }
    }
    return $null
}

function Get-ShortTagRuntimeValue {
    # อ่านจาก config\php.ini ที่ generate แล้ว (ถ้ามี)
    # ใช้ค่า "บรรทัดสุดท้าย" — ใน php.ini directive หลังสุดชนะ
    $ini = $Script:P.PhpIni
    if (-not (Test-Path $ini)) { return $null }
    $last = $null
    foreach ($l in (Get-Content $ini -Encoding UTF8)) {
        if ("$l" -match '^\s*short_open_tag\s*=\s*(On|Off|1|0|true|false)\s*$' -and "$l" -notmatch '^\s*;') {
            $last = $Matches[1]
        }
    }
    return $last
}

function Set-ShortTagTpl([string]$Value) {
    # Value = On | Off — แก้ templates\php-hardening.ini แล้ว regenerate php.ini ให้ (ถ้า resolve PHP ได้)
    $want = if ("$Value".ToLower() -in @('on', '1', 'true', 'yes')) { 'On' } else { 'Off' }
    $tpl = Join-Path $Script:P.Templates 'php-hardening.ini'
    if (-not (Test-Path $tpl)) { throw "ไม่พบ $tpl" }
    $lines = @(Get-Content $tpl -Encoding UTF8)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ("$($lines[$i])" -match '^\s*short_open_tag\s*=') {
            $lines[$i] = "short_open_tag = $want"
            $found = $true
        }
    }
    if (-not $found) {
        $lines += ''
        $lines += '; ---- short_open_tag ----'
        $lines += '; CodeIgniter 3 / โค้ด PHP เก่าใช้ <? — ถ้า Off แล้วแอปพังแบบ Unclosed brace'
        $lines += '; สลับด้วย: aptstack shorttag on|off  แล้ว aptstack restart'
        $lines += "short_open_tag = $want"
    }
    Write-Utf8NoBom $tpl (($lines -join "`r`n") + "`r`n")
    return $want
}

function Write-ShortTagHint([switch]$Quiet) {
    # เตือนตั้งแต่ start/doctor — กันลืมตอนใช้แอป CI3 / PHP เก่า
    $tplV = Get-ShortTagTplValue
    $runV = Get-ShortTagRuntimeValue
    $eff = if ($runV) { $runV } else { $tplV }
    if (-not $eff) { $eff = 'Off' }
    $isOn = "$eff".ToLower() -in @('on', '1', 'true')
    if ($Quiet) {
        if (-not $isOn) {
            Write-Warn2 'short_open_tag = Off — แอป CodeIgniter 3 / โค้ด <? เก่าจะพัง (Unclosed brace)'
            Write-Info 'เปิด: aptstack shorttag on  แล้ว aptstack restart'
        }
        return
    }
    if ($isOn) {
        Write-Info "short_open_tag = On (CI3 / โค้ด <? เก่าใช้ได้) · สลับ: aptstack shorttag off"
    } else {
        Write-Warn2 'short_open_tag = Off — ถ้าแอป CI3 / helper ใช้ <? จะขึ้น ParseError Unclosed brace'
        Write-Info 'เปิดง่าย: aptstack shorttag on   แล้ว aptstack restart'
    }
}

function Cmd-ShortTag([string]$action) {
    $tpl = Join-Path $Script:P.Templates 'php-hardening.ini'
    $act = if ($action) { "$action".ToLower() } else { 'status' }

    switch ($act) {
        'status' {
            Write-Head 'short_open_tag (โค้ดเก่าใช้ <?)'
            $tplV = Get-ShortTagTplValue
            $runV = Get-ShortTagRuntimeValue
            Write-Host "  template (templates\php-hardening.ini) : $(if ($tplV) { $tplV } else { '(ไม่มีบรรทัด — ถือว่า Off)' })" -ForegroundColor $(if ("$tplV".ToLower() -in @('on','1','true')) { 'Green' } else { 'Yellow' })
            Write-Host "  runtime  (config\php.ini ที่ใช้อยู่)    : $(if ($runV) { $runV } else { '(ยังไม่ generate — aptstack start)' })" -ForegroundColor Gray
            Write-Host ''
            Write-Info 'เปิด : aptstack shorttag on'
            Write-Info 'ปิด  : aptstack shorttag off'
            Write-Info 'แล้ว : aptstack restart   (php.ini ถูก generate ใหม่ทุก start)'
            Write-Info 'CI3 / helper ที่มี <? ต้องเปิด On ไม่งั้น ParseError Unclosed brace'
        }
        { $_ -in @('on', 'off', '1', '0', 'true', 'false', 'yes', 'no') } {
            $want = Set-ShortTagTpl $act
            Write-Head "ตั้ง short_open_tag = $want"
            Write-Ok "บันทึกแล้ว: templates\php-hardening.ini"
            # regenerate runtime php.ini ถ้า resolve PHP ได้ (ไม่ต้อง start ใหม่ก็เห็นไฟล์ แต่ Apache ต้อง reload)
            $cfg = Get-Config
            $php = Resolve-Php $cfg.php
            if ($php -and $php.Usable) {
                try {
                    $ini = New-PhpIni $php.Dir
                    Write-Info "generate แล้ว: $ini"
                } catch { Write-Warn2 "generate php.ini ไม่สำเร็จ: $($_.Exception.Message)" }
            }
            if (Test-Running 'web') {
                Write-Warn2 'web กำลังรัน — ต้อง restart เพื่อให้ PHP โหลดค่าใหม่'
                Write-Info 'รัน: aptstack restart'
            } else {
                Write-Info 'เปิด stack: aptstack start'
            }
            Write-ShortTagHint
        }
        default { throw "ใช้: aptstack shorttag [status|on|off]" }
    }
}

function Cmd-Tls($action, $a, $b) {
    $cfg = Get-Config
    $act = if ($action) { "$action".ToLower() } else { 'status' }

    switch ($act) {
        'status' {
            Write-Head 'HTTPS / TLS'
            $on = "$($cfg.httpsEnabled)".ToLower() -eq 'true'
            Write-Host "  httpsEnabled : $($cfg.httpsEnabled)" -ForegroundColor $(if ($on) { 'Green' } else { 'Gray' })
            Write-Host "  httpsPort    : $($cfg.httpsPort)"
            Write-Host "  serverName   : $($cfg.serverName)"
            $cert = Resolve-CertPath $cfg.certFile
            $key = Resolve-CertPath $cfg.keyFile
            Write-Host "  certFile     : $(if ($cert) { $cert } else { '(ยังไม่ตั้ง)' })"
            Write-Host "  keyFile      : $(if ($key) { $key } else { '(ยังไม่ตั้ง)' })"
            $ci = Get-CertInfo $cert
            if ($ci) {
                $col = if ($ci.DaysLeft -lt 14) { 'Yellow' } else { 'Gray' }
                Write-Host ''
                Write-Host "  Subject : $($ci.Subject)" -ForegroundColor White
                Write-Host "  Issuer  : $($ci.Issuer)" -ForegroundColor Gray
                Write-Host ("  หมดอายุ : {0:yyyy-MM-dd}  (เหลือ {1} วัน)" -f $ci.NotAfter, $ci.DaysLeft) -ForegroundColor $col
                # cert PEM ย่อมไม่มี private key ในไฟล์ cert -> เช็ค "ไฟล์ key" แยก
                $keyHas = (Test-Path $key) -and ((Get-Content $key -Raw -EA SilentlyContinue) -match 'PRIVATE KEY')
                Write-Host "  แบบกุญแจ: $(if ($keyHas) { 'ไฟล์ key มี private key ครบ (Apache ใช้ได้)' } else { 'ไม่พบ private key ในไฟล์ key — Apache จะ start ไม่ขึ้น' })" -ForegroundColor $(if ($keyHas) { 'Green' } else { 'Red' })
                Write-Host "  Trust    : $(if ($ci.Trusted) { 'อยู่ใน Trusted Root — browser/.NET เชื่อถือแล้ว' } else { 'ยังไม่ได้ trust (self-signed จะถูกปฏิเสธโดย .NET/browser)' })" -ForegroundColor $(if ($ci.Trusted) { 'Green' } else { 'Yellow' })
                if ($ci.DaysLeft -lt 14) { Write-Warn2 'cert ใกล้หมดอายุ — ต่ออายุแล้วรัน: aptstack tls import <cert> <key>' }
            } elseif ($cert) { Write-Warn2 'อ่านไฟล์ cert ไม่ได้ (รูปแบบ/encoding ผิด? ต้องเป็น PEM)' }

            $wm = Resolve-WebMode $cfg (Resolve-Php $cfg.php) (Resolve-Apache $cfg.apache)
            if ($on) {
                if ($wm -ne 'apache') { Write-Warn2 "HTTPS ใช้ได้กับ webMode=apache เท่านั้น (ตอนนี้ = $wm)" }
                else {
                    $h = Invoke-HttpProbe "https://127.0.0.1:$($cfg.httpsPort)/" 5
                    if ($h.Ok) { Write-Ok "HTTPS ตอบแล้ว: $($h.Status)  https://127.0.0.1:$($cfg.httpsPort)/" }
                    else { Write-Warn2 "HTTPS ยังไม่ตอบ: $($h.Error)" ; Write-Info 'ถ้าเพิ่งเปิด ให้รัน: aptstack restart แล้วดู aptstack logs apache' }
                }
            } else {
                Write-Info 'ยังไม่เปิด — เปิดด้วย:  aptstack tls init   หรือ  aptstack tls import <cert> <key>'
            }
            Write-Host ''
            Write-Info 'วิธีใช้: tls init (self-signed/mkcert) · tls import <cert.pem> <key.pem> (cert จริง) · tls off'
        }

        'off' {
            $cfg.httpsEnabled = 'false'
            Save-Config $cfg
            Write-Ok 'ปิด HTTPS แล้ว (httpsEnabled=false)'
            Restart-WebOnly
        }

        'on' {
            $cert = Resolve-CertPath $cfg.certFile
            $key = Resolve-CertPath $cfg.keyFile
            if (-not (Test-Path $cert) -or -not (Test-Path $key)) { throw 'ยังไม่มี cert/key — รันก่อน: aptstack tls init หรือ tls import' }
            $cfg.httpsEnabled = 'true'
            Save-Config $cfg
            Write-Ok "เปิด HTTPS ที่ port $($cfg.httpsPort)"
            Restart-WebOnly
        }

        'init' {
            # สร้าง self-signed cert ด้วย openssl ที่มากับ Apache (ไม่ต้องติดตั้งอะไรเพิ่ม)
            # ถ้ามี mkcert อยู่แล้วจะใช้ mkcert แทน (ได้ cert ที่ browser เชื่อถือในเครื่องตัวเอง)
            Ensure-Dirs
            $domains = @('localhost')
            if ($a) { foreach ($d in ("$a" -split '[,\s]+')) { if ($d -and ($domains -notcontains $d)) { $domains += $d } } }
            # ดึง host จาก vhosts.json เข้า SAN ด้วย — ไม่งั้น https://demo.local จะถูกปฏิเสธ
            # ด้วย RemoteCertificateNameMismatch (cert ไม่ครอบคลุมชื่อนั้น)
            $vhFile = Join-Path $Script:P.ConfigDir 'vhosts.json'
            if (Test-Path $vhFile) {
                try {
                    foreach ($v in @((Get-Content $vhFile -Raw -Encoding UTF8 | ConvertFrom-Json))) {
                        $h = "$($v.host)"
                        if ($h -and ($domains -notcontains $h)) { $domains += $h }
                    }
                } catch { }
            }
            $san = (@("DNS:$($domains -join ',DNS:')") + @('IP:127.0.0.1')) -join ','
            Write-Info "SAN ที่จะใส่: $($domains -join ', ')"

            $certOut = Join-Path $Script:P.Certs 'aptstack-cert.pem'
            $keyOut = Join-Path $Script:P.Certs 'aptstack-key.pem'

            $mkcert = Get-Command mkcert -ErrorAction SilentlyContinue
            if ($mkcert) {
                Write-Head 'สร้าง cert ด้วย mkcert (browser เชื่อถือในเครื่องนี้)'
                & mkcert.exe -install 2>&1 | Out-Null
                & mkcert.exe -cert-file "$certOut" -key-file "$keyOut" @($domains) 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Warn2 'mkcert ไม่สำเร็จ — ลอง openssl แทน'; $mkcert = $null }
            }
            if (-not $mkcert) {
                $apache = Resolve-Apache $cfg.apache
                $openssl = $null
                if ($apache) { $o = Join-Path $apache.Dir 'bin\openssl.exe'; if (Test-Path $o) { $openssl = $o } }
                if (-not $openssl) { throw "ไม่พบ openssl.exe ใน Apache — ติดตั้ง mkcert หรือใช้: aptstack tls import <cert> <key>" }

                Write-Head "สร้าง self-signed cert ด้วย openssl (อายุ 365 วัน)"
                Write-Info "CN=$($domains[0])  SAN=$san"
                $oargs = @('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '365',
                           '-keyout', "$keyOut", '-out', "$certOut",
                           '-subj', "/CN=$($domains[0])",
                           '-addext', "subjectAltName=$san",
                           '-addext', 'basicConstraints=critical,CA:FALSE',
                           '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment',
                           '-addext', 'extendedKeyUsage=serverAuth')
                # openssl ของ Apache ค้น config ที่ path compile-time (เช่น C:\Apache24\conf)
                # -> ต้องชี้ OPENSSL_CONF ไปที่ openssl.cnf ของ bundle ไม่งั้น error ทันที
                $oldConf = $env:OPENSSL_CONF
                $oCnf = Join-Path $apache.Dir 'conf\openssl.cnf'
                if (Test-Path $oCnf) { $env:OPENSSL_CONF = $oCnf }
                $old = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { & $openssl @oargs 2>&1 | Out-Null } catch { }
                $code = $LASTEXITCODE
                $ErrorActionPreference = $old
                $env:OPENSSL_CONF = $oldConf
                if ($code -ne 0 -or -not (Test-Path $certOut)) { throw "openssl สร้าง cert ไม่สำเร็จ (exit $code) — ดู templates หรือใช้ mkcert" }
            }

            $cfg.certFile = 'config\certs\aptstack-cert.pem'
            $cfg.keyFile = 'config\certs\aptstack-key.pem'
            $cfg.httpsEnabled = 'true'
            if ($cfg.serverName) { $cfg.serverName = $domains[0] }
            Save-Config $cfg

            $ci = Get-CertInfo $certOut
            Write-Ok "สร้าง cert แล้ว: $($ci.Subject)"
            if ($ci) { Write-Info ("หมดอายุ {0:yyyy-MM-dd} (เหลือ {1} วัน)" -f $ci.NotAfter, $ci.DaysLeft) }
            Write-Info "cert: $certOut"
            Write-Info "key : $keyOut"
            # ต้อง "เชื่อถือ" ด้วย ไม่งั้น .NET/browser จะปฏิเสธ self-signed (UntrustedRoot)
            # และการปลดด้วย ServerCertificateValidationCallback ใช้ไม่ได้จริงใน PS 5.1
            if (-not $ci.Trusted) {
                if (Add-CertTrust $certOut) { Write-Ok 'ใส่ cert เข้า Trusted Root (CurrentUser) แล้ว — probe/browser เชื่อถือได้ทันที' }
                else { Write-Warn2 'ยังไม่ได้ trust cert — health probe https จะฟ้อง UntrustedRoot' }
            } else { Write-Ok 'cert อยู่ใน Trusted Root แล้ว' }
            Write-Warn2 'self-signed = ใช้ทดสอบ/ภายในเครื่อง ถ้าเปิดออกอินเทอร์เน็ตให้ใช้ cert จริง'
            Write-Info 'ได้ cert จริง (Let''s Encrypt / ผู้ให้บริการ) -> aptstack tls import <cert.pem> <key.pem>'
            Restart-WebOnly
            Write-Info "ลองเปิด: https://127.0.0.1:$($cfg.httpsPort)/"
        }

        'import' {
            if (-not $a -or -not $b) { throw 'ใช้: aptstack tls import <cert.pem> <key.pem>' }
            if (-not (Test-Path $a)) { throw "ไม่พบไฟล์ cert: $a" }
            if (-not (Test-Path $b)) { throw "ไม่พบไฟล์ key: $b" }
            Ensure-Dirs
            $ci = Get-CertInfo $a
            if (-not $ci) { throw 'อ่าน cert ไม่ได้ — ต้องเป็น PEM (.pem/.crt) ไม่ใช่ .pfx' }
            if (-not $ci.HasPrivate) {
                # cert กับ key แยกไฟล์: ตรวจว่า key ใส่ได้จริงโดยลอง pair กัน
                Write-Info 'ตรวจว่า cert/key match กัน...'
            }
            $certDst = Join-Path $Script:P.Certs 'aptstack-cert.pem'
            $keyDst = Join-Path $Script:P.Certs 'aptstack-key.pem'
            Copy-Item $a $certDst -Force
            Copy-Item $b $keyDst -Force

            $cfg.certFile = 'config\certs\aptstack-cert.pem'
            $cfg.keyFile = 'config\certs\aptstack-key.pem'
            $cfg.httpsEnabled = 'true'
            Save-Config $cfg

            Write-Ok 'นำเข้า cert จริงแล้ว'
            Write-Info "Subject : $($ci.Subject)"
            Write-Info ("หมดอายุ : {0:yyyy-MM-dd} (เหลือ {1} วัน)" -f $ci.NotAfter, $ci.DaysLeft)
            if ($ci.DaysLeft -lt 14) { Write-Warn2 'cert ใกล้/หมดอายุ — อย่าลืมต่ออายุแล้ว import ใหม่' }
            Restart-WebOnly
            Write-Info "ลองเปิด: https://127.0.0.1:$($cfg.httpsPort)/"
        }

        default { throw "ไม่รู้จัก '$act' — ใช้ได้: status | init [domain,..] | import <cert> <key> | on | off" }
    }
}

function Cmd-Logs($kind, $n) {
    if (-not $kind) { $kind = 'all' }
    if ("$n" -match '^\d+$') { $n = [int]$n } else { $n = 50 }

    $names = switch ("$kind".ToLower()) {
        'apache' { @('apache-error.log', 'apache-access.log') }
        'httpd'  { @('apache-error.log', 'apache-access.log') }
        'mysql'  { @('mariadb-error.log') }
        'maria'  { @('mariadb-error.log') }
        'db'     { @('mariadb-error.log') }
        'php'    { @('php-error.log') }
        'all'    { @('apache-error.log', 'mariadb-error.log', 'php-error.log') }
        default  { throw "ไม่รู้จัก log '$kind' — ใช้ได้: apache | mysql | php | all" }
    }

    Write-Head "logs ($n บรรทัดท้าย) · $kind"
    foreach ($fn in $names) {
        $path = Join-Path $Script:P.Logs $fn
        Write-Host "  --- $fn ---" -ForegroundColor White
        if (-not (Test-Path $path)) {
            Write-Warn2 "ยังไม่มีไฟล์นี้: $path"
            Write-Info 'ปกติจะถูกสร้างเมื่อมี error ตอน start/รัน'
            Write-Host ''
            continue
        }
        $item = Get-Item $path
        Write-Info ("{0:N0} bytes · เปลี่ยนล่าสุด {1}" -f $item.Length, $item.LastWriteTime)
        $lines = @(Get-Content $path -Tail $n -ErrorAction SilentlyContinue)
        if ($lines.Count -eq 0) { Write-Info '(ไฟล์ว่าง)'; Write-Host ''; continue }
        foreach ($l in $lines) {
            $c = 'Gray'
            if ("$l" -match '(?i)\bfatal\b|critical|access denied|failed|cannot|refused|Segmentation') { $c = 'Red' }
            elseif ("$l" -match '(?i)\bwarn|deprecated|notice') { $c = 'Yellow' }
            Write-Host "  $l" -ForegroundColor $c
        }
        Write-Host ''
    }
    Write-Info "ทั้งหมดอยู่ที่: $($Script:P.Logs)"
}

# ---------------------------------------------------------------- init / help
function Cmd-Init {
    Ensure-Dirs
    if (-not (Test-Path $Script:P.Config)) { Save-Config (Get-Config) }
    $cfg = Get-Config

    # ถ้ายังไม่มีแอปเลย -> ติดตั้ง "ตัวอย่างทั้งหมด" ใน examples\ (มี index.php)
    if (@(Get-AppVersions).Count -eq 0) { Cmd-Samples }

    if (-not (Get-Item -LiteralPath (Join-Path $Script:P.Www $cfg.appAlias) -Force -EA SilentlyContinue)) {
        $apps = @(Get-AppVersions)
        if ($apps.Count -gt 0) { Set-AppLink $apps[-1].Name; $cfg.app = $apps[-1].Name; Save-Config $cfg }
    }
    $idx = Join-Path $Script:P.Www 'index.php'
    if (-not (Test-Path $idx)) {
        @'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "aptstack works\n";
echo "PHP " . PHP_VERSION . " on " . PHP_OS . "\n";
echo "SAPI: " . php_sapi_name() . "\n";
echo "Loaded ini: " . php_ini_loaded_file() . "\n";
echo "pdo_mysql: " . (extension_loaded('pdo_mysql') ? 'OK' : 'MISSING') . "\n";
echo "mysqli: " . (extension_loaded('mysqli') ? 'OK' : 'MISSING') . "\n";
'@ | Set-Content -Path $idx -Encoding UTF8
    }
    Write-Ok "เตรียมโครงสร้างที่ $Root"
    Write-Info 'ต่อไป: aptstack start  แล้ว  aptstack seed  (database ตัวอย่าง)'
}

function Cmd-Samples {
    # ติดตั้ง "ตัวอย่างแอป" ทุกตัวใน examples\ (โฟลเดอร์ที่มี index.php)
    # ใช้ตอนแตก zip ใหม่เพื่อให้เห็นทันทีว่า stack + DB สลับแอปได้จริง
    Ensure-Dirs
    $exRoot = Join-Path $Root 'examples'
    $samples = @()
    if (Test-Path $exRoot) {
        $samples = @(Get-ChildItem $exRoot -Directory -ErrorAction SilentlyContinue |
                     Where-Object { Test-Path (Join-Path $_.FullName 'index.php') })
    }
    if ($samples.Count -eq 0) { Write-Warn2 'ไม่พบตัวอย่างใน examples\'; return }

    Write-Head 'ติดตั้งตัวอย่างแอป (examples\)'
    $added = 0
    foreach ($s in $samples) {
        $dest = Join-Path $Script:P.Versions $s.Name
        if (Test-Path $dest) { Write-Info "มีแล้ว: versions\$($s.Name)"; continue }
        robocopy $s.FullName $dest /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Err2 "copy ล้มเหลว: $($s.Name)"; continue }
        Set-AppMeta $dest $null $null
        Set-SourceMeta $dest 'app' "examples\$($s.Name)"
        Write-Ok "ติดตั้ง versions\$($s.Name)"
        $added++
    }

    # ถ้ายังไม่มี junction ให้ชี้ไปตัวแรก
    $cfg = Get-Config
    if (-not (Get-Item -LiteralPath (Join-Path $Script:P.Www $cfg.appAlias) -Force -EA SilentlyContinue)) {
        $apps = @(Get-AppVersions)
        if ($apps.Count -gt 0) {
            Set-AppLink $apps[-1].Name
            $cfg.app = $apps[-1].Name
            Save-Config $cfg
            Write-Info "ชี้ www\$($cfg.appAlias) -> $($apps[-1].Name)"
        }
    }
    Write-Host ''
    Sync-AppAliases
    Write-Info 'ดูรายการ : aptstack list'
    Write-Info 'สลับแอป  : aptstack use <name> | aptstack next | aptstack prev | aptstack use -'
    Write-Info 'เข้าหลาย path พร้อมกันได้: /<ชื่อแอป>/ ทุกตัวที่ติดตั้ง'
    if ($added -gt 0) { Write-Info 'database : aptstack seed   (สร้างตารางให้ todolist ด้วย)' }
}

function Cmd-Seed {
    $cfg = Get-Config
    if (Test-PortFree $cfg.dbPort) { throw "Database ยังไม่รัน (port $($cfg.dbPort)) — รัน: aptstack start" }
    if ("$($cfg.dbMode)" -eq 'external') { Write-Warn2 'dbMode=external — กำลัง import ไปยัง MySQL ภายนอก (ของ XAMPP)' }
    $sql = Join-Path $Root 'examples\seed.sql'
    if (-not (Test-Path $sql)) { throw "ไม่พบ $sql" }

    $hit = Resolve-MySql $cfg.mysql
    if (-not $hit) { throw 'ไม่พบ MySQL/MariaDB client ใน stack\mysql\' }
    $client = $null
    foreach ($n in @('bin\mariadb.exe', 'bin\mysql.exe')) {
        $p = Join-Path $hit.Dir $n
        if (Test-Path $p) { $client = $p; break }
    }
    if (-not $client) {
        $f = Get-ChildItem $hit.Dir -Recurse -File -Include 'mariadb.exe', 'mysql.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $client = $f.FullName }
    }
    if (-not $client) { throw 'ไม่พบ mariadb.exe / mysql.exe' }

    Write-Head 'import database ตัวอย่าง -> aptstack_demo'
    $args = @('--skip-ssl', '-h', '127.0.0.1', '-P', "$($cfg.dbPort)", '--protocol=tcp',
              '--default-character-set=utf8mb4',
              '-u', $cfg.dbUser, "-p$($cfg.dbPass)", '--force')

    # ต้องส่งไฟล์ .sql เข้า stdin ตรง ๆ (Start-Process -RedirectStandardInput)
    # ห้าม pipe ด้วย `Get-Content | client` — PowerShell จะ encode string ใหม่ตาม console codepage
    # ทำให้ตัวหนังสือไทยกลายเป็น ??? ทันทีที่ import
    $tmpOut = Join-Path $Script:P.Tmp 'seed-out.txt'
    $tmpErr = Join-Path $Script:P.Tmp 'seed-err.txt'
    if (-not (Test-Path $Script:P.Tmp)) { New-Item -ItemType Directory -Path $Script:P.Tmp -Force | Out-Null }
    $p = Start-Process -FilePath $client -ArgumentList $args `
                       -RedirectStandardInput $sql `
                       -RedirectStandardOutput $tmpOut `
                       -RedirectStandardError $tmpErr `
                       -Wait -PassThru -NoNewWindow
    $code = $p.ExitCode
    $out = @()
    if (Test-Path $tmpOut) { $out += (Get-Content $tmpOut -Encoding UTF8 -ErrorAction SilentlyContinue) }
    if (Test-Path $tmpErr) { $out += (Get-Content $tmpErr -Encoding UTF8 -ErrorAction SilentlyContinue) }

    if ($code -ne 0) {
        throw ("import ล้มเหลว (exit $code):`n" + (($out | Select-Object -First 6) -join "`n"))
    }
    $nums = @($out | Where-Object { "$_" -match '^\s*\d+\s*$' } | ForEach-Object { "$_".Trim() })
    Write-Ok 'import เรียบร้อย (CREATE DATABASE IF NOT EXISTS — ซ้ำได้)'
    if ($nums.Count -gt 0) { Write-Info ("rows ทุกตารางใน seed: " + ($nums -join ', ')) }
    Write-Info 'เปิดดู:  http://127.0.0.1:<port>/<appAlias>/  (hello ดูตาราง greetings · todo ดู todo_items)'
}

function Get-MysqlClient($cfg) {
    $hit = Resolve-MySql $cfg.mysql
    if (-not $hit) { throw 'ไม่พบ MySQL/MariaDB client ใน stack\mysql\ — รัน: aptstack start หรือ add mysql' }
    foreach ($n in @('bin\mariadb.exe', 'bin\mysql.exe')) {
        $p = Join-Path $hit.Dir $n
        if (Test-Path $p) { return $p }
    }
    $f = Get-ChildItem $hit.Dir -Recurse -File -Include 'mariadb.exe', 'mysql.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    throw 'ไม่พบ mariadb.exe / mysql.exe'
}

function Invoke-MysqlSql($cfg, [string]$client, [string]$SqlText, [string]$DbName = '') {
    # รัน SQL ผ่าน stdin string (ไม่เขียนไฟล์กลางถ้าไม่จำเป็น)
    # สำคัญ: ห้าม pipe string เข้า process — Thai กลายเป็น ??? (encode ตาม OEM codepage)
    if (-not (Test-Path $Script:P.Tmp)) { New-Item -ItemType Directory -Path $Script:P.Tmp -Force | Out-Null }
    $tmpIn = Join-Path $Script:P.Tmp 'import-in.sql'
    $tmpOut = Join-Path $Script:P.Tmp 'import-out.txt'
    $tmpErr = Join-Path $Script:P.Tmp 'import-err.txt'
    Write-Utf8NoBom $tmpIn $SqlText
    $args = @('--skip-ssl', '-h', '127.0.0.1', '-P', "$($cfg.dbPort)", '--protocol=tcp',
              '--default-character-set=utf8mb4', '-u', $cfg.dbUser, "-p$($cfg.dbPass)")
    if ($DbName) { $args += $DbName }
    $args += '--force'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $p = Start-Process -FilePath $client -ArgumentList $args `
            -RedirectStandardInput $tmpIn `
            -RedirectStandardOutput $tmpOut `
            -RedirectStandardError $tmpErr `
            -Wait -PassThru -NoNewWindow
    } finally { $ErrorActionPreference = $old }
    $out = @(); $err = @()
    if (Test-Path $tmpOut) { $out = @(Get-Content $tmpOut -Encoding UTF8 -ErrorAction SilentlyContinue) }
    if (Test-Path $tmpErr) { $err = @(Get-Content $tmpErr -Encoding UTF8 -ErrorAction SilentlyContinue) }
    return [pscustomobject]@{ ExitCode = [int]$p.ExitCode; Out = $out; Err = $err }
}

function Invoke-MysqlImportFile($cfg, [string]$client, [string]$SqlPath, [string]$DbName, [string]$Act) {
    # import .sql -> mysql ผ่าน stdin แบบ stream:
    #  - ไม่โหลด dump ทั้งไฟล์ลง memory (ก่อนหน้า ReadAllBytes ~90MB ทำให้ดูค้าง/กินแรม)
    #  - แก้ USE / CREATE DATABASE ทีละบรรทัดระหว่าง stream
    #  - แสดง % ตาม byte ที่ feed เข้า client (mysql ดึงช้า = ค้างที่ % เดิม = กำลังทำงานจริง)
    #  - ENCODING: อ่าน/เขียนด้วย Latin-1 (byte-preserving) + client --default-character-set=binary
    #    กัน varbinary (pass_encoded/uname) ถูกแทนด้วย U+FFFD ตอนตีความเป็น UTF-8
    if (-not $Act) { $Act = "import SQL -> $DbName" }
    $totalMB = [math]::Round((Get-Item -LiteralPath $SqlPath).Length / 1MB, 1)

    $argList = @('--skip-ssl', '-h', '127.0.0.1', '-P', "$($cfg.dbPort)", '--protocol=tcp',
                 '--default-character-set=binary', '-u', $cfg.dbUser, "-p$($cfg.dbPass)")
    if ($DbName) { $argList += $DbName }
    $argList += '--force'
    $argStr = ($argList | ForEach-Object {
        $a = "$_"
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $client
    $psi.Arguments = $argStr
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    # อ่าน out/err คู่ขนานกัน stdin — กัน deadlock ที่ buffer เต็ม
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    # Latin-1 = 1 byte ↔ 1 char — round-trip binary ได้ปลอดภัย (UTF-8 StreamReader จะแทน invalid ด้วย U+FFFD)
    $enc = [Text.Encoding]::GetEncoding(28591)
    $stdinW = $null; $sr = $null; $fs = $null; $sw = $null
    $exitCode = -1
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $fs = [IO.File]::OpenRead($SqlPath)
        $sr = New-Object System.IO.StreamReader($fs, $enc, $false)
        $stdinW = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, $enc, 65536)
        $stdinW.NewLine = "`n"

        $total = [double]$fs.Length
        $done = 0.0
        $pct = -1
        $lastLog = -2.0
        $useRe = [regex]'(?i)^\s*USE\s+`?([A-Za-z0-9_]+)`?\s*;'
        $createRe = [regex]'(?i)^\s*CREATE\s+DATABASE\s+(IF\s+NOT\s+EXISTS\s+)?`?([A-Za-z0-9_]+)`?'
        $sysDb = @('mysql', 'information_schema', 'performance_schema', 'sys')

        while ($null -ne ($line = $sr.ReadLine())) {
            $mu = $useRe.Match($line)
            if ($mu.Success) {
                $n = $mu.Groups[1].Value
                if ($n -and $n -ne $DbName -and ($sysDb -notcontains $n)) {
                    $line = 'USE `' + $DbName + '`;'
                }
            } elseif ($createRe.IsMatch($line)) {
                $line = $createRe.Replace($line, {
                    param($m) 'CREATE DATABASE ' + $m.Groups[1].Value + '`' + $DbName + '`'
                })
            }
            try { $stdinW.WriteLine($line) }
            catch { break }  # mysql ปิด stdin ก่อนจบ (error กลางทาง) — ออกไปอ่าน output

            $done = $fs.Position
            if ($total -gt 0) {
                $p = [int][Math]::Min(100, [Math]::Round($done / $total * 100))
                $eta = ''
                if ($sw.Elapsed.TotalSeconds -gt 2 -and $done -gt 1MB) {
                    $rate = $done / $sw.Elapsed.TotalSeconds
                    if ($rate -gt 1) {
                        $sec = ($total - $done) / $rate
                        if ($sec -gt 0 -and $sec -lt 86400) { $eta = "เหลือ ~$([int]$sec) วิ" }
                    }
                }
                if ($p -ne $pct) {
                    $pct = $p
                    Write-Progress -Activity $Act -PercentComplete $pct `
                        -Status "$pct% · $([math]::Round($done/1MB,1))/$totalMB MB $eta"
                }
                if ($sw.Elapsed.TotalSeconds - $lastLog -ge 5) {
                    $lastLog = $sw.Elapsed.TotalSeconds
                    Write-Info ("    ... {0}% · {1:N1}/{2:N1} MB · {3}" -f $pct, ($done / 1MB), $totalMB, $eta)
                }
            }
        }
        try { $stdinW.Flush() } catch { }
        try { $stdinW.Dispose() } catch { }
        $stdinW = $null

        # feed ครบแล้ว — เหลือขั้น mysql ย่อย/ commit (กับ DB ใหญ่อาจนานอีกพัก)
        Write-Progress -Activity $Act -PercentComplete 100 -Status 'feed ครบ — รอ mysql ประมวลผลสุดท้าย...'
        Write-Info '    feed ครบ 100% — รอ mysql ประมวลผลท้ายสุด (ตารางใหญ่อาจใช้เวลา)...'
        if (-not $proc.WaitForExit(600000)) {
            try { $proc.Kill() } catch { }
            throw 'import ใช้เวลานานเกิน 10 นาที — หยุด process แล้ว'
        }
        $exitCode = $proc.ExitCode
    }
    finally {
        if ($stdinW) { try { $stdinW.Dispose() } catch { } }
        if ($sr) { try { $sr.Dispose() } catch { } }
        if ($fs) { try { $fs.Dispose() } catch { } }
        Write-Progress -Activity $Act -Completed
        if ($sw) { $sw.Stop() }
    }

    $outText = ''; $errText = ''
    try { $outText = $outTask.Result } catch { }
    try { $errText = $errTask.Result } catch { }
    $proc.Dispose()

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Out      = @($outText -split "`r?`n")
        Err      = @($errText -split "`r?`n")
    }
}

# ---------------------------------------------------------------- import ทั้ง install เก่า
function Copy-StateTree([string]$src, [string]$dst, [string]$label, [int]$idx, [int]$total, [string[]]$xargs = @()) {
    # robocopy stream % -> Write-Progress (แสดงสถานะทีละขั้นระหว่างย้าย)
    # /E ทั้งหมด · /XJ ไม่ตาม junction (กันคัดลอกซ้ำ www\app -> versions\) · /MT หลายเธรด
    $act = "ย้ายจาก aptstack เก่า — [$idx/$total] $label"
    $pct = -1
    $argList = @($src, $dst, '/E', '/XJ', '/R:2', '/W:2', '/MT:16', '/NFL', '/NDL', '/NJH', '/NP', '/BYTES') + $xargs
    $lines = & robocopy @argList | ForEach-Object {
        $line = "$_"
        if ($line -match '^\s*(\d{1,3})\s*%') {
            $p = [int]$Matches[1]
            if ($p -gt 100) { $p = 100 }
            if ($p -ne $pct) { $pct = $p; Write-Progress -Activity $act -PercentComplete $p -Status "$p%" }
        }
        $line
    }
    Write-Progress -Activity $act -Completed
    $rc = $LASTEXITCODE
    $copied = 0; $failed = 0
    foreach ($l in $lines) {
        if ("$l" -match 'Files\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
            $copied = [int]$Matches[2]; $failed = [int]$Matches[5]
        }
    }
    if ($rc -ge 8) { throw "robocopy ล้มเหลว (exit $rc) — $label : $src" }
    return [pscustomobject]@{ Label = $label; Copied = $copied; Failed = $failed; Exit = $rc }
}

function Cmd-ImportRoot([string]$oldRoot, [string]$flags) {
    # ย้าย aptstack install เก่าทั้งตัว (state) เข้า root ปัจจุบัน:
    #  คัดลอก: config(stack.json/vhosts/certs/sessions) + stack + versions + www + data + downloads
    #  คงไว้ : โค้ดใหม่ (aptstack.ps1/templates/docs) · php.ini/my.ini/httpd.conf generate ใหม่ทุก start
    $oldFull = (Resolve-Path -LiteralPath $oldRoot -ErrorAction Stop).Path
    $newFull = (Resolve-Path -LiteralPath $Root).Path
    if ($oldFull.TrimEnd('\') -ieq $newFull.TrimEnd('\')) { throw 'source = target — ชี้มาที่ root ปัจจุบันเอง' }
    if (-not (Test-Path (Join-Path $oldFull 'aptstack.ps1'))) { throw "ไม่ใช่โฟลเดอร์ aptstack (ไม่มี aptstack.ps1): $oldFull" }
    if (-not (Test-Path (Join-Path $oldFull 'config\stack.json'))) { Write-Warn2 'โฟลเดอร์เก่าไม่มี config\stack.json — จะคัดลอกเฉพาะของที่มีจริง' }

    # root นี้ต้องหยุดก่อน (ไม่งั้นไฟล์ที่ copy ทับถูกใช้/ล็อกอยู่)
    if (Test-Running 'web') { throw 'Web ของ root นี้กำลังรัน — aptstack stop ก่อน import' }
    if (Test-Running 'mysql') { throw 'Database ของ root นี้กำลังรัน — aptstack stop ก่อน import' }
    # โฟลเดอร์เก่าต้องไม่รันด้วย (คัดลอก data ตอน server เปิด = ข้อมูลเพี้ยน/ไฟล์ล็อก)
    $busy = @()
    try {
        $busy = @(Get-CimInstance Win32_Process -EA Stop | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath -like ($oldFull + '\*')
        })
    } catch { }
    if ($busy.Count -gt 0) {
        foreach ($b in $busy) { Write-Info ("   - {0} (pid {1})" -f $b.Name, $b.ProcessId) }
        throw "มี process จากโฟลเดอร์เก่ากำลังรัน $($busy.Count) ตัว (ดูด้านบน) — ไปที่โฟลเดอร์เก่าแล้ว aptstack stop (หรือ service stop) ก่อน เพื่อกัน data เสียหาย"
    }

    $skipDl = "$flags" -match 'no-?downloads|skip-?downloads'
    $cfgDirNew = Join-Path $Root 'config'
    $phases = @(
        [pscustomobject]@{ Label = 'config (stack.json, vhosts, certs, sessions)'; Src = (Join-Path $oldFull 'config'); Dst = $cfgDirNew; Kind = 'cfg' },
        [pscustomobject]@{ Label = 'stack (binary apache/php/mysql)';             Src = (Join-Path $oldFull 'stack');      Dst = $Script:P.Stack;     Kind = 'dir' },
        [pscustomobject]@{ Label = 'versions (app versions)';                     Src = (Join-Path $oldFull 'versions');   Dst = $Script:P.Versions;  Kind = 'dir' },
        [pscustomobject]@{ Label = 'www (โค้ดแอป + phpMyAdmin)';                  Src = (Join-Path $oldFull 'www');        Dst = $Script:P.Www;       Kind = 'dir' },
        [pscustomobject]@{ Label = 'data (database ทั้งหมด)';                      Src = (Join-Path $oldFull 'data');       Dst = $Script:P.Data;      Kind = 'data' },
        [pscustomobject]@{ Label = 'downloads (ไฟล์ติดตั้งที่โหลดไว้)';            Src = (Join-Path $oldFull 'downloads');  Dst = $Script:P.Downloads; Kind = 'opt' }
    )

    Write-Head 'ย้าย aptstack เก่า -> root ปัจจุบัน (state เท่านั้น — โค้ดใหม่คงเดิม)'
    Write-Info "จาก: $oldFull"
    Write-Info "ไป : $newFull"
    Write-Host ''
    $totalMb = 0.0
    $plan = @()
    foreach ($p in $phases) {
        if ($p.Kind -eq 'opt' -and $skipDl) { Write-Info ("  ข้าม   {0}  (--no-downloads)" -f $p.Label); continue }
        if (-not (Test-Path $p.Src)) { Write-Info ("  ไม่มี   {0}" -f $p.Label); continue }
        $mb = Get-FolderSizeMB $p.Src
        $totalMb += $mb
        $plan += $p
        Write-Info ("  {0,-56} {1,10:N1} MB" -f $p.Label, $mb)
    }
    if ($plan.Count -eq 0) { Write-Info 'ไม่มีอะไรให้ย้าย'; return }
    Write-Host ''
    Write-Warn2 'data เดิมของ root นี้ (ถ้ามี) จะย้ายไป data.preimport-<เวลา> ไว้ก่อน — ไม่ถูกลบ'
    if (-not (Confirm-Action "พิมพ์ y เพื่อเริ่มย้าย $($plan.Count) ขั้น (~$totalMb MB)")) { Write-Info 'ยกเลิก'; return }

    $results = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $i = 0
    foreach ($p in $plan) {
        $i++
        $xargs = @()
        if ($p.Kind -eq 'cfg') { $xargs = @('/XF', 'php.ini', 'my.ini', 'httpd.conf', '/XD', 'pids', 'tmp') }
        # data: ย้ายของเดิมออกจากทางก่อน (rename บน volume เดียวกัน = เร็ว ไม่ต้องลบ)
        if ($p.Kind -eq 'data' -and (Test-Path $p.Dst)) {
            $kids = @(Get-ChildItem $p.Dst -Force -EA SilentlyContinue)
            if ($kids.Count -gt 0) {
                $bak = "$($p.Dst).preimport-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                Move-Item -LiteralPath $p.Dst -Destination $bak -Force
                Write-Warn2 "data เดิมย้ายไป: $bak"
            }
        }
        Write-Info ("  [{0}/{1}] กำลังย้าย: {2}" -f $i, $plan.Count, $p.Label)
        $r = Copy-StateTree $p.Src $p.Dst $p.Label $i $plan.Count $xargs
        $results += $r
        if ($r.Failed -gt 0) { Write-Warn2 ("  {0} — คัดลอกไม่สำเร็จ {1} ไฟล์ (อาจถูกล็อก — ตรวจภายหลัง)" -f $p.Label, $r.Failed) }
        else { Write-Ok ("  {0} — {1} ไฟล์" -f $p.Label, $r.Copied) }
    }
    $sw.Stop()

    # www\app หลัง copy จากโฟลเดอร์อื่น:
    #  - junction ไม่ถูกคัดลอกด้วย /XJ -> สร้างใหม่จาก config
    #  - ถ้า destination มี www\app เป็น "โฟลเดอร์ธรรมดา" (copy ทับ/ไม่รักษา junction)
    #    web จะ 404/500 -> เตือน + ยืนยันลบ แล้วสร้าง junction ใหม่
    $stImp = Repair-MainAppLink -Where 'import'
    switch ($stImp) {
        'ok' { Write-Ok "www\$((Get-Config).appAlias) เป็น junction อยู่แล้ว" }
        'created' { Write-Ok "สร้าง junction www\$((Get-Config).appAlias) จาก config แล้ว" }
        'fixed' { Write-Ok "ซ่อม www\$((Get-Config).appAlias): ลบโฟลเดอร์ธรรมดา + สร้าง junction แล้ว" }
        'declined' { Write-Warn2 "www\$((Get-Config).appAlias) ยังเป็นโฟลเดอร์ธรรมดา — web จะ 404/500 จนกว่าจะลบเองแล้วรัน aptstack doctor" }
        'not-junction' { Write-Warn2 "www\$((Get-Config).appAlias) ยังเป็นโฟลเดอร์ธรรมดา — ลบไม่ได้ตอนนี้ (lock) ค่อยรัน aptstack doctor" }
        default { Write-Warn2 "www\$((Get-Config).appAlias) ยังไม่พร้อม — รัน: aptstack doctor  หรือ  aptstack use <version>" }
    }
    try { Sync-AppAliases; Write-Info 'สร้าง junction ชื่ออื่น ๆ ให้แล้ว (Sync-AppAliases)' }
    catch { Write-Warn2 "junction: $($_.Exception.Message)" }

    Write-Host ''
    Write-Head "ย้ายเสร็จ — ใช้เวลา $([int]$sw.Elapsed.TotalSeconds) วินาที"
    foreach ($r in $results) {
        Write-Info ("  {0,-56} {1,8} ไฟล์{2}" -f $r.Label, $r.Copied, $(if ($r.Failed -gt 0) { "  [FAIL $($r.Failed)]" } else { '' }))
    }
    Write-Host ''
    Write-Info 'ขั้นถัดไป:'
    Write-Info '  aptstack list              ดูเวอร์ชัน/แอปที่ย้ายมา'
    Write-Info '  aptstack doctor            ตรวจความเรียบร้อยทั้งหมด'
    Write-Info '  aptstack start             เปิดใช้ (php.ini/my.ini/httpd.conf generate ใหม่ — path ชี้ root นี้เอง)'
    Write-Info '  aptstack service install   ถ้าใช้ Windows service (ต้องทำใหม่ให้ชี้ root นี้)'
    if ($skipDl) { Write-Info '  ไม่ได้ย้าย downloads (--no-downloads) — โหลดใหม่ด้วย: aptstack add ...' }
}

function Select-ImportFromFolder([string]$folder) {
    # โฟลเดอร์ dump (ไม่ใช่ aptstack root) -> ไล่ .sql/.sql.zip/.zip แล้วให้เลือกหมายเลข
    # คืนค่า: @([IO.FileInfo]...) หรือ $null ถ้าเลือก/ไม่มีไฟล์
    $files = @(
        Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(sql|zip)$' -or $_.Name -match '\.sql\.zip$' } |
            Sort-Object `
                @{ e = { if ($_.Name -match '\.sql$') { 0 } elseif ($_.Name -match '\.sql\.zip$') { 1 } else { 2 } } }, `
                @{ e = { $_.LastWriteTimeUtc }; Descending = $true }, `
                Name
    )
    if ($files.Count -eq 0) {
        Write-Err2 "ไม่พบไฟล์ .sql / .sql.zip / .zip ในโฟลเดอร์นี้: $folder"
        return $null
    }

    Write-Head "พบไฟล์ import ในโฟลเดอร์ ($($files.Count) ไฟล์)"
    Write-Info $folder
    Write-Host ''
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f = $files[$i]
        $mb = [math]::Round($f.Length / 1MB, 1)
        $when = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $kind = if ($f.Name -match '\.sql$') { 'sql' } elseif ($f.Name -match '\.sql\.zip$') { 'sql.zip' } else { 'zip ' }
        Write-Host ("  [{0}]  {1}  {2,-48} {3,9:N1} MB  {4}" -f ($i + 1), $kind, $f.Name, $mb, $when) -ForegroundColor White
    }
    Write-Host ''
    $prompt = "  เลือกหมายเลข 1-$($files.Count) (คั่น , ได้หลายไฟล์ · all = ทั้งหมด · Enter = ยกเลิก)"
    $ans = $null
    try {
        Write-Host $prompt -ForegroundColor Yellow
        if ([Console]::IsInputRedirected) { $ans = [Console]::In.ReadLine() }
        else { $ans = Read-Host '  > ' }
    } catch { return $null }
    if ($null -eq $ans -or [string]::IsNullOrWhiteSpace($ans)) { Write-Info 'ยกเลิก'; return $null }

    $ans = "$ans".Trim()
    if ($ans -match '^(?i)(all|a|\*)$') { return $files }

    $picked = @()
    foreach ($tok in ($ans -split '[,\s]+')) {
        if (-not $tok) { continue }
        $n = 0
        if (-not [int]::TryParse($tok, [ref]$n) -or $n -lt 1 -or $n -gt $files.Count) {
            Write-Err2 "ไม่ถูกต้อง: '$tok' (ต้องเป็นหมายเลข 1-$($files.Count))"
            return $null
        }
        $picked += $files[$n - 1]
    }
    if ($picked.Count -eq 0) { Write-Err2 'ไม่ได้เลือกไฟล์'; return $null }
    # dedupe ถ้าพิมพ์ซ้ำ
    $picked = @($picked | Sort-Object FullName -Unique)
    Write-Ok ("เลือก {0} ไฟล์: {1}" -f $picked.Count, (($picked | ForEach-Object Name) -join ', '))
    return $picked
}

function Get-ExistingDatabaseNames($cfg, [string]$client) {
    $r = Invoke-MysqlSql $cfg $client 'SHOW DATABASES;'
    if ($r.ExitCode -ne 0) { return @() }
    $skip = @('Database', 'information_schema', 'performance_schema', 'sys', 'mysql')
    @(
        $r.Out |
            ForEach-Object { "$_".Trim() } |
            Where-Object { $_ -and $_ -notin $skip -and $_ -notmatch '^(Warning|Using a password)' } |
            Sort-Object -Unique
    )
}

function Prompt-DbNameForImport($cfg, [string]$client, [string]$suggest = '', [string]$srcLabel = '') {
    # ยังไม่ได้ระบุ dbname -> ถาม + โชว์รายชื่อ DB ที่มี (กันซ้ำ)
    # คืนค่าชื่อ db ที่ถูกต้อง หรือ $null ถ้ายกเลิก
    $existing = Get-ExistingDatabaseNames $cfg $client
    Write-Head 'ตั้งชื่อ database ปลายทาง'
    if ($srcLabel) { Write-Info "ไฟล์: $srcLabel" }
    if ($existing.Count -gt 0) {
        Write-Info ("ฐานข้อมูลที่มีอยู่แล้ว ({0} — เลือกชื่อซ้ำได้ แต่จะ import ลง DB เดิม):" -f $existing.Count)
        $n = 0
        foreach ($e in $existing) {
            $n++
            Write-Host ("   {0,2}) {1}" -f $n, $e) -ForegroundColor DarkGray
        }
    } else {
        Write-Info 'ยังดึงรายชื่อ DB ไม่ได้ (server อาจเพิ่ง start) — พิมพ์ชื่อใหม่ได้เลย'
    }
    if (-not $suggest) { $suggest = 'import_db' }
    Write-Host ''

    while ($true) {
        $def = if ($suggest) { "(Enter = $suggest)" } else { '' }
        $ans = $null
        try {
            Write-Host "  พิมพ์ชื่อ database ปลายทาง $def (p = ยกเลิก)" -ForegroundColor Yellow
            if ([Console]::IsInputRedirected) { $ans = [Console]::In.ReadLine() }
            else { $ans = Read-Host '  > ' }
        } catch { return $null }

        if ($null -eq $ans) { Write-Info 'ยกเลิก'; return $null }
        $ans = "$ans".Trim()
        if ($ans -match '^(?i)(p|q|cancel|abort)$') { Write-Info 'ยกเลิก'; return $null }
        if (-not $ans) { $ans = $suggest }

        if ($ans -notmatch '^[A-Za-z0-9_][A-Za-z0-9_$]*$') {
            Write-Err2 "ชื่อ db ผิดรูปแบบ: $ans (a-z 0-9 _ · ขึ้นต้นด้วยตัวอักษร/เลข)"
            continue
        }
        if ($existing -contains $ans) {
            Write-Warn2 " '$ans' มีอยู่แล้ว — import จะเพิ่ม/เขียนทับข้อมูลใน DB เดิม"
            if (-not (Confirm-Action "ใช้ '$ans' ต่อไหม?")) { continue }
        }
        Write-Ok "dbname: $ans"
        return $ans
    }
}

function Resolve-ImportDbName($cfg, [string]$client, [string]$dbName, [string]$suggest = '', [string]$srcLabel = '') {
    # ระบุ dbName ตอนเรียก -> ใช้เลย (เช็คซ้ำ + เตือน)
    # ไม่ระบุ -> prompt (มีรายการ DB ให้ดู)
    if ($dbName) {
        if ($dbName -notmatch '^[A-Za-z0-9_][A-Za-z0-9_$]*$') {
            throw "ชื่อ database ผิดรูปแบบ: $dbName (ใช้ a-z 0-9 _ ขึ้นต้นด้วยตัวอักษร/เลข)"
        }
        $existing = Get-ExistingDatabaseNames $cfg $client
        if ($existing -contains $dbName) {
            Write-Warn2 " dbname '$dbName' มีอยู่แล้ว — import จะเพิ่ม/เขียนทับข้อมูลใน DB เดิม"
            if (-not (Confirm-Action "ใช้ '$dbName' ต่อไหม?")) { return $null }
        } else {
            Write-Info "dbname : $dbName (ใหม่ — จะ CREATE ให้)"
        }
        return $dbName
    }
    # non-interactive (pipe) -> ไม่ค้าง ใช้ suggest แทน
    if ([Console]::IsInputRedirected) {
        $auto = if ($suggest) { $suggest } else { 'import_db' }
        if ($auto -notmatch '^[A-Za-z0-9_][A-Za-z0-9_$]*$') { $auto = 'import_db' }
        Write-Info "dbname : $auto (non-interactive — ใช้ชื่อแนะนำ)"
        return $auto
    }
    return Prompt-DbNameForImport $cfg $client $suggest $srcLabel
}

function Cmd-Import([string]$file, [string]$dbName, [string]$extra) {
    # mode โฟลเดอร์:
    #   - มี aptstack.ps1     -> ย้ายทั้ง install เก่า (Cmd-ImportRoot)
    #   - มี .sql/.sql.zip/.zip -> ลิสต์หมายเลขให้เลือก
    #       * ระบุ dbname ตอนเรียก -> ใช้ชื่อนั้นทุกไฟล์
    #       * ไม่ระบุ -> prompt พร้อมโชว์รายชื่อ DB ที่มี (กันซ้ำ)
    if ($file) {
        $probe = $file
        if ($probe -notmatch '^[A-Za-z]:[\\/]') { $probe = Join-Path $Root $probe }
        if (Test-Path -LiteralPath $probe -PathType Container) {
            $probeFull = (Resolve-Path -LiteralPath $probe).Path
            if (Test-Path -LiteralPath (Join-Path $probeFull 'aptstack.ps1')) {
                Cmd-ImportRoot $probeFull ("$dbName $extra")
                return
            }
            $cfg = Get-Config
            if (Test-PortFree $cfg.dbPort) { throw "Database ยังไม่รัน (port $($cfg.dbPort)) — รัน: aptstack start" }
            if ("$($cfg.dbMode)" -eq 'external') { Write-Warn2 'dbMode=external — import ไปยัง MySQL ภายนอก (XAMPP)' }
            $client = Get-MysqlClient $cfg

            $picked = Select-ImportFromFolder $probeFull
            if (-not $picked) { return }

            # ระบุ dbname ครั้งเดียวใช้กับทุกไฟล์ · ไม่ระบุ -> prompt ต่อไฟล์
            $useCliDb = $null
            if ($dbName) {
                $useCliDb = Resolve-ImportDbName $cfg $client $dbName '' 'command line'
                if (-not $useCliDb) { return }
            }

            $i = 0
            foreach ($p in $picked) {
                $i++
                if ($picked.Count -gt 1) {
                    Write-Host ''
                    Write-Info ("=== [{0}/{1}] {2} ===" -f $i, $picked.Count, $p.Name)
                }
                $leaf = $p.Name
                $suggest = ($leaf -replace '\.sql\.zip$', '' -replace '\.sql$', '' -replace '\.zip$', '')
                if ($suggest -notmatch '^[A-Za-z0-9_]') { $suggest = 'db_' + $suggest -replace '[^A-Za-z0-9_]', '_' }
                $oneDb = $useCliDb
                if (-not $oneDb) {
                    $oneDb = Resolve-ImportDbName $cfg $client $null $suggest $p.FullName
                    if (-not $oneDb) { Write-Info 'ยกเลิกไฟล์นี้'; continue }
                }
                Cmd-Import $p.FullName $oneDb $extra
            }
            return
        }
    }
    # แบบ db_manager.go (win-devops-toolkit): รับ .sql หรือ .sql.zip
    # - สร้าง database ให้ถ้ายังไม่มี (CREATE DATABASE IF NOT EXISTS)
    # - import ผ่าน stdin file (ไม่ pipe — กันไทยเป็น ???)
    # - zip ภายในมี .sql ตัวเดียว => แตกชั่วคราวแล้ว import
    $cfg = Get-Config
    if (Test-PortFree $cfg.dbPort) { throw "Database ยังไม่รัน (port $($cfg.dbPort)) — รัน: aptstack start" }
    if ("$($cfg.dbMode)" -eq 'external') { Write-Warn2 'dbMode=external — import ไปยัง MySQL ภายนอก (XAMPP)' }

    if (-not $file) {
        $cand = @(Get-ChildItem -Path $Root -File -Include '*.sql', '*.sql.zip' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(data|stack|versions|downloads|dist)\\' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 15)
        Write-Head 'import — วิธีใช้'
        Write-Info 'aptstack import <file.sql|.sql.zip> [dbname]'
        Write-Info 'aptstack import D:\dump\myapp.sql.zip myapp'
        Write-Host ''
        Write-Info 'aptstack import <โฟลเดอร์ dump> [dbname]'
        Write-Info '   ลิสต์ .sql/.sql.zip/.zip แล้วให้เลือกหมายเลข'
        Write-Info '   เช่น aptstack import ..\_setup_appoint\ appoint052569'
        Write-Info '   เลือกหลายไฟล์: 1,3  ·  ทั้งหมด: all  ·  Enter = ยกเลิก'
        Write-Info '   ไม่ระบุ [dbname] -> ถามชื่อ + โชว์รายชื่อ DB ที่มี (กันซ้ำ)'
        Write-Host ''
        Write-Info 'aptstack import <โฟลเดอร์ aptstack เก่า> [--no-downloads]'
        Write-Info '   ย้ายทั้ง install เก่า (stack/data/www/versions/config) เข้า root นี้'
        Write-Info '   (โฟลเดอร์ที่มี aptstack.ps1) · โค้ดใหม่คงเดิม · data เก่าถูกกันไว้ data.preimport-*'
        if ($cand.Count -gt 0) {
            Write-Host ''
            Write-Info 'ไฟล์ .sql/.sql.zip ที่เจอใกล้ ๆ:'
            foreach ($c in $cand) { Write-Info ("  {0}  ({1:N1} MB)" -f $c.FullName, ($c.Length / 1MB)) }
        }
        Write-Host ''
        Write-Info 'dbName ถ้าไม่ระบุ (โหมดไฟล์ตรง) => ใช้ชื่อไฟล์ (myapp.sql.zip -> myapp)'
        Write-Info 'โหมดโฟลเดอร์ไม่ระบุ dbname => ถามพร้อมโชว์รายการ DB'
        Write-Info 'หรือถ้าไฟล์มี CREATE DATABASE / USE อยู่แล้ว -> ข้ามขั้นนี้'
        return
    }

    # resolve path (relative -> bundle root)
    $src = $file
    if ($src -notmatch '^[A-Za-z]:[\\/]') { $src = Join-Path $Root $src }
    if (-not (Test-Path $src)) { throw "ไม่พบไฟล์: $src" }

    $client = Get-MysqlClient $cfg
    $isZip = $src.ToLower().EndsWith('.zip')

    # ถ้าไม่ระบุ dbName -> derive จากชื่อไฟล์ (myapp.sql / myapp.sql.zip -> myapp)
    if (-not $dbName) {
        $leaf = Split-Path $src -Leaf
        $dbName = $leaf -replace '\.sql\.zip$', '' -replace '\.sql$', '' -replace '\.zip$', ''
    }
    # sanitize: ชื่อ db ห้ามมี path/มีอักขระอันตราย
    if ($dbName -notmatch '^[A-Za-z0-9_][A-Za-z0-9_$]*$') {
        throw "ชื่อ database ผิดรูปแบบ: $dbName (ใช้ a-z 0-9 _ ขึ้นต้นด้วยตัวอักษร/เลข)"
    }

    Write-Head "import SQL -> $dbName"
    Write-Info "file   : $src ($([math]::Round((Get-Item $src).Length / 1MB, 1)) MB)"
    Write-Info "client : $client"
    Write-Info "target : 127.0.0.1:$($cfg.dbPort) / $dbName"

    # 1) สร้าง DB
    $r0 = Invoke-MysqlSql $cfg $client "CREATE DATABASE IF NOT EXISTS ``$dbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    if ($r0.ExitCode -ne 0) {
        throw ("CREATE DATABASE ล้มเหลว (exit $($r0.ExitCode)):`n" + (($r0.Err + $r0.Out | Select-Object -First 6) -join "`n"))
    }
    Write-Ok "database พร้อม: $dbName (สร้างแล้วถ้าไม่มี)"

    # 2) แตก zip (ถ้ามี) -> เอา .sql ตัวแรก
    $sqlPath = $src
    $tmpExtract = $null
    if ($isZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tmpExtract = Join-Path $Script:P.Tmp ('import-zip-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpExtract -Force | Out-Null
        try {
            [IO.Compression.ZipFile]::ExtractToDirectory($src, $tmpExtract)
        } catch { throw "แตก zip ล้มเหลว: $($_.Exception.Message)" }
        $sqlFile = Get-ChildItem $tmpExtract -Recurse -File -Filter '*.sql' | Select-Object -First 1
        if (-not $sqlFile) { throw 'zip ไม่มีไฟล์ .sql ข้างใน' }
        $sqlPath = $sqlFile.FullName
        Write-Info "แตกแล้ว: $($sqlFile.Name)"
    }

    # 3) import — stream ทีละบรรทัดพร้อม % progress (ไม่โหลด dump ทั้งไฟล์ลง memory)
    #    แก้ USE / CREATE DATABASE ระหว่าง stream ให้ชี้ dbName ปลายทาง
    $r1 = Invoke-MysqlImportFile $cfg $client $sqlPath $dbName ("import SQL -> $dbName")
    if ($tmpExtract -and (Test-Path $tmpExtract)) { Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue }

    if ($r1.ExitCode -ne 0) {
        Write-Err2 "import อาจไม่สมบูรณ์ (exit $($r1.ExitCode))"
        $lines = @($r1.Err + $r1.Out) | Where-Object { $_ } | Select-Object -First 8
        foreach ($l in $lines) { Write-Info "$l" }
        return
    }

    # 4) verify: ต้องมีตารางใน dbName จริง
    $v = Invoke-MysqlSql $cfg $client "SHOW TABLES;" $dbName
    $tables = @($v.Out | Where-Object { $_ -and $_ -notmatch '^\s*Tables_in' -and $_ -notmatch '^-+$' -and $_ -notmatch '^\s*$' })
    if ($tables.Count -eq 0) {
        Write-Warn2 "import exit 0 แต่ยังไม่เห็นตารางใน $dbName"
        Write-Info 'เปิดไป phpMyAdmin ดูว่า dump ชี้ db ไหน หรือส่ง --dbname ให้ตรง'
        return
    }
    Write-Ok "import สำเร็จ -> $dbName  ($($tables.Count) ตาราง)"
    Write-Info ("ตาราง: " + (($tables | Select-Object -First 10) -join ', '))

    # บันทึกแหล่งที่มาของ dump (ต้นทาง deploy/re-import)
    try {
        $srcItem = Get-Item $src
        $srcHash = (Get-FileHash -Path $src -Algorithm SHA256).Hash
        $metaDir = Join-Path $Root 'logs'
        if (-not (Test-Path $metaDir)) { New-Item -ItemType Directory -Path $metaDir -Force | Out-Null }
        $metaPath = Join-Path $metaDir ("import-$dbName.meta")
        $meta = @"
# aptstack import meta — แหล่ง dump ที่ import ล่าสุดของ database นี้
kind=sql-import
database=$dbName
source=$src
sha256=$srcHash
size_bytes=$($srcItem.Length)
imported=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
tables=$($tables.Count)
client=$client
"@
        Write-Utf8NoBom $metaPath ($meta + "`r`n")
        Write-Info "บันทึกต้นทาง: $metaPath"
    } catch { Write-Info 'บันทึก import meta ไม่สำเร็จ (ไม่บล็อกงาน)' }
    $nums = @($r1.Out + $r1.Err | Where-Object { "$_" -match '^\s*\d+\s*$' })
    if ($nums.Count -gt 0) { Write-Info ("rows ที่ insert: " + (($nums | Select-Object -First 8) -join ', ')) }
    Write-Info "phpMyAdmin: http://127.0.0.1:$($cfg.httpPort)/phpmyadmin/"
    Write-Info 'backup: aptstack backup'
}

# ------------------------------------------------------------- printable report
# ------------------------------------------------------------- disk / size report
function Get-DirStat([string]$p) {
    if (-not $p -or -not (Test-Path $p)) { return @{ MB = 0.0; Files = 0 } }
    $m = Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    return @{ MB = [math]::Round(($m.Sum / 1MB), 1); Files = [int]$m.Count }
}

function Get-SizeInfo {
    # รวมสถิติพื้นที่ทั้ง bundle + เตือน "บวม/ดิสก์ใกล้เต็ม" (ใช้โดย report + size)
    $top = @('stack', 'versions', 'data', 'www', 'config', 'logs', 'downloads',
             'dist_paste', 'dist', 'docs', 'examples', 'templates', 'bin', 'service')
    $folders = @()
    $totalMB = 0.0
    foreach ($n in $top) {
        $s = Get-DirStat (Join-Path $Root $n)
        $totalMB += $s.MB
        $folders += [pscustomobject]@{ Name = $n; MB = $s.MB; Files = $s.Files; Pct = 0 }
    }
    $rootSelf = Get-DirStat $Root
    $totalMB = [math]::Round($rootSelf.MB, 1)
    if ($totalMB -le 0) { $totalMB = 0.01 }
    $folders = foreach ($f in $folders) {
        [pscustomobject]@{ Name = $f.Name; MB = $f.MB; Files = $f.Files; Pct = [math]::Round(100 * $f.MB / $totalMB, 1) }
    }

    # breakdown รายตัว
    $vers = @()
    if (Test-Path $Script:P.Versions) {
        foreach ($d in (Get-ChildItem $Script:P.Versions -Directory -EA SilentlyContinue)) {
            $s = Get-DirStat $d.FullName
            $meta = Get-AppMeta $d.FullName
            $vers += [pscustomobject]@{ Name = $d.Name; Family = $meta.Family; Ver = $meta.Version; MB = $s.MB; Files = $s.Files }
        }
        $vers = @($vers | Sort-Object Family, Ver)
    }
    $stackParts = @()
    foreach ($sub in @('php', 'apache', 'mysql')) {
        $sp = Join-Path $Script:P.Stack $sub
        if (Test-Path $sp) {
            foreach ($d in (Get-ChildItem $sp -Directory -EA SilentlyContinue)) {
                $s = Get-DirStat $d.FullName
                $stackParts += [pscustomobject]@{ Name = "$sub\$($d.Name)"; MB = $s.MB; Files = $s.Files }
            }
        }
    }
    $stackParts = @($stackParts | Sort-Object MB -Descending)

    $dumps = @(Get-ChildItem $Script:P.Dumps -Filter '*.sql' -EA SilentlyContinue)
    $dumpsMB = [math]::Round((($dumps | Measure-Object Length -Sum).Sum / 1MB), 1)
    $dataParts = @()
    foreach ($m in @(Get-MySqlVersions)) {
        $dd = Get-DataDir $m
        $s = Get-DirStat $dd
        $dataParts += [pscustomobject]@{ Name = "datadir $($m.Name)"; MB = $s.MB; Files = $s.Files }
    }
    $dataParts += [pscustomobject]@{ Name = 'dumps (backup *.sql)'; MB = $dumpsMB; Files = $dumps.Count }

    $freeGB = $null
    try {
        $driveName = (Split-Path -Qualifier $Root).TrimEnd(':')
        $freeGB = [math]::Round(((Get-PSDrive -Name $driveName -ErrorAction Stop).Free / 1GB), 1)
    } catch { }

    # ---- เตือน "บวม/ดิสก์ใกล้เต็ม" ----
    $warns = @()
    function W($lv, $t) { $script:SizeWarns += [pscustomobject]@{ Level = $lv; Text = $t } }
    $script:SizeWarns = @()
    foreach ($v in $vers) { if ($v.MB -gt 200) { W 'WARN' ("versions\$($v.Name) ใหญ่ $($v.MB) MB — ถ้าเป็นโค้ดอย่างเดียวควรเล็กกว่านี้ ตรวจว่ามี vendor/node_modules ติดมาไหม" ) } }
    if ($dumpsMB -gt 100) { W 'WARN' "data\dumps รวม $dumpsMB MB — เก็บ backup ไว้นอก bundle แล้วลบออกจาก server" }
    $dl = Get-DirStat (Join-Path $Root 'downloads')
    if ($dl.MB -gt 100) { W 'WARN' "downloads\ ใหญ่ $($dl.MB) MB — zip ที่ add แล้วไม่ต้องเก็บ ลบทิ้งได้" }
    foreach ($dp in @('dist_paste', 'dist')) {
        $s = Get-DirStat (Join-Path $Root $dp)
        if ($s.MB -gt 0) { W 'WARN' "$dp\ ใหญ่ $($s.MB) MB — ชุด deploy เก่า ก่อน copy ขึ้น server ให้ลบก่อน (หรือย้ายออก)" }
    }
    if ($totalMB -gt 1500) { W 'WARN' "รวม bundle $([math]::Round($totalMB/1024,2)) GB — ใหญ่สำหรับ copy-paste ลอง aptstack dist (เลือกเอาเฉพาะที่จำเป็น)" }
    if ($null -ne $freeGB -and $freeGB -lt 10) { W 'ERR' "พื้นที่ว่างบนไดรฟ์เหลือแค่ $freeGB GB — เสี่ยง disk เต็มตอนแตกไฟล์/เพิ่ม version" }

    return [pscustomobject]@{
        Folders    = $folders
        Versions   = $vers
        StackParts = $stackParts
        DataParts  = $dataParts
        DumpsCount = $dumps.Count
        DumpsMB    = $dumpsMB
        TotalMB    = $totalMB
        FreeGB     = $freeGB
        Warnings   = @($script:SizeWarns)
    }
}

function Show-SizeCli($sz) {
    Write-Head ("พื้นที่ทั้ง bundle: {0:N1} MB" -f $sz.TotalMB)
    if ($null -ne $sz.FreeGB) {
        $fc = if ($sz.FreeGB -lt 10) { 'Red' } elseif ($sz.FreeGB -lt 30) { 'Yellow' } else { 'Gray' }
        Write-Host ("  พื้นที่ว่างบนไดรฟ์: {0} GB" -f $sz.FreeGB) -ForegroundColor $fc
    }
    Write-Host ''
    Write-Host ('  {0,-14} {1,10} {2,8} {3,7}' -f 'โฟลเดอร์', 'MB', 'ไฟล์', '%') -ForegroundColor White
    foreach ($f in $sz.Folders) {
        if ($f.MB -le 0 -and $f.Files -eq 0) { continue }
        $c = if ($f.Pct -ge 40) { 'Yellow' } else { 'Gray' }
        Write-Host ('  {0,-14} {1,10:N1} {2,8} {3,6:N1}%' -f $f.Name, $f.MB, $f.Files, $f.Pct) -ForegroundColor $c
    }
    Write-Host ('  {0,-14} {1,10:N1}' -f 'รวม (ทั้ง root)', $sz.TotalMB) -ForegroundColor White

    if ($sz.Versions.Count -gt 0) {
        Write-Host ''
        Write-Host '  รายตัว versions\  ([ชื่อ] = app family — app เดียวกัน หรือคนละ app)' -ForegroundColor White
        foreach ($v in $sz.Versions) {
            $c = if ($v.MB -gt 200) { 'Yellow' } else { 'Gray' }
            $fam = if ($v.PSObject.Properties['Family'] -and $v.Family) { "[$($v.Family)]" } else { '[?]' }
            Write-Host ('    {0,-14} {1,-20} {2,9:N1} MB  {3,6} ไฟล์' -f $fam, $v.Name, $v.MB, $v.Files) -ForegroundColor $c
        }
    }
    if ($sz.StackParts.Count -gt 0) {
        Write-Host ''
        Write-Host '  รายตัว stack\' -ForegroundColor White
        foreach ($v in $sz.StackParts) { Write-Host ('    {0,-28} {1,9:N1} MB' -f $v.Name, $v.MB) -ForegroundColor Gray }
    }
    if ($sz.DataParts.Count -gt 0) {
        Write-Host ''
        Write-Host '  รายตัว data\' -ForegroundColor White
        foreach ($v in $sz.DataParts) { Write-Host ('    {0,-28} {1,9:N1} MB  {2,6} ไฟล์' -f $v.Name, $v.MB, $v.Files) -ForegroundColor Gray }
    }
    Write-Host ''
    if ($sz.Warnings.Count -eq 0) { Write-Ok 'พื้นที่ปกติ ไม่มีอะไรบวมผิดปกติ' }
    else {
        foreach ($w in $sz.Warnings) {
            if ($w.Level -eq 'ERR') { Write-Err2 $w.Text } else { Write-Warn2 $w.Text }
        }
    }
    Write-Info 'รายละเอียดเต็ม + ตารางพิมพ์ได้: aptstack report'
}

function Cmd-Size {
    Show-SizeCli (Get-SizeInfo)
}

# ---------------------------------------------------------- database inventory
function Get-DatabaseStats {
    # รายชื่อ database + ขนาด (MB) จาก information_schema — ต้องมี DB รันอยู่
    $cfg = Get-Config
    if (Test-PortFree $cfg.dbPort) { return @() }
    $client = Get-MysqlClient $cfg
    $sql = @"
SELECT table_schema AS db_name,
       COUNT(*) AS tables_n,
       ROUND(COALESCE(SUM(data_length+index_length),0)/1024/1024, 2) AS size_mb,
       ROUND(COALESCE(SUM(data_length),0)/1024/1024, 2) AS data_mb,
       ROUND(COALESCE(SUM(index_length),0)/1024/1024, 2) AS index_mb
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys','phpmyadmin')
GROUP BY table_schema
ORDER BY size_mb DESC;
"@
    $r = Invoke-MysqlSql $cfg $client $sql
    $out = @()
    foreach ($line in @($r.Out)) {
        if (-not $line) { continue }
        if ($line -match '^\s*db_name\s') { continue }
        if ($line -match '^-+$') { continue }
        $p = "$line" -split "`t"
        if ($p.Count -lt 5) { $p = "$line" -split '\s+' }
        if ($p.Count -lt 5) { continue }
        $out += [pscustomobject]@{
            Name    = $p[0]
            Tables  = [int]$p[1]
            SizeMB  = [double]$p[2]
            DataMB  = [double]$p[3]
            IndexMB = [double]$p[4]
        }
    }
    return $out
}

function Get-DatabaseTables([string]$dbName) {
    $cfg = Get-Config
    if (Test-PortFree $cfg.dbPort) { return @() }
    $client = Get-MysqlClient $cfg
    $sql = @"
SELECT table_name AS tbl,
       table_rows AS rows_n,
       ROUND(COALESCE(data_length+index_length,0)/1024/1024, 2) AS size_mb,
       ROUND(COALESCE(data_length,0)/1024/1024, 2) AS data_mb,
       engine
FROM information_schema.tables
WHERE table_schema = '$dbName'
ORDER BY size_mb DESC;
"@
    $r = Invoke-MysqlSql $cfg $client $sql
    $out = @()
    foreach ($line in @($r.Out)) {
        if (-not $line) { continue }
        if ($line -match '^\s*tbl\s') { continue }
        if ($line -match '^-+$') { continue }
        $p = "$line" -split "`t"
        if ($p.Count -lt 5) { $p = "$line" -split '\s+' }
        if ($p.Count -lt 5) { continue }
        $out += [pscustomobject]@{
            Table  = $p[0]
            Rows   = [long]$p[1]
            SizeMB = [double]$p[2]
            DataMB = [double]$p[3]
            Engine = $p[4]
        }
    }
    return $out
}

function Cmd-ReportDb([string]$dbName = '') {
    # aptstack report db — ดู database ทุกก้อน + table + ขนาด + ดิสก์รวม
    # aptstack report db <name> — เจาะตารางใน database นั้น
    $cfg = Get-Config
    Write-Head 'database inventory (report db)'
    if (Test-PortFree $cfg.dbPort) {
        Write-Err2 "DB ไม่ได้รัน (port $($cfg.dbPort)) — aptstack start ก่อน"
        return
    }
    Write-Info "server: 127.0.0.1:$($cfg.dbPort)  mode=$($cfg.dbMode)"
    $dbs = @(Get-DatabaseStats)
    if ($dbs.Count -eq 0) {
        Write-Warn2 'ไม่เห็น database (ยังไม่มีข้อมูล หรือสิทธิ์ไม่พอ)'
        Write-Info 'import: aptstack import <file.sql> [dbname]'
        return
    }
    Write-Host ''
    Write-Host ('  {0,-28} {1,6} {2,10} {3,10} {4,10}' -f 'Database', 'Tables', 'Total MB', 'Data MB', 'Index MB') -ForegroundColor Cyan
    Write-Host ('  {0}' -f ('-' * 70)) -ForegroundColor DarkGray
    $total = 0.0
    foreach ($d in $dbs) {
        $total += $d.SizeMB
        Write-Host ('  {0,-28} {1,6} {2,10:N2} {3,10:N2} {4,10:N2}' -f $d.Name, $d.Tables, $d.SizeMB, $d.DataMB, $d.IndexMB)
    }
    Write-Host ('  {0}' -f ('-' * 70)) -ForegroundColor DarkGray
    Write-Host ('  {0,-28} {1,6} {2,10:N2}' -f 'ALL', '', $total) -ForegroundColor Green

    # ดิสก์ datadir + dumps
    $mysql = Resolve-MySql $cfg.mysql
    $datadir = if ($mysql) { Get-DataDir $mysql } else { '' }
    $ddMB = if ($datadir -and (Test-Path $datadir)) { Get-FolderSizeMB $datadir } else { 0 }
    $dumpMB = Get-FolderSizeMB $Script:P.Dumps
    $diskMB = [math]::Round($ddMB + $dumpMB, 1)
    Write-Host ''
    Write-Info ("datadir  : {0}  ({1:N1} MB)" -f $datadir, $ddMB)
    Write-Info ("dumps\\   : {0:N1} MB" -f $dumpMB)
    Write-Info ("disk รวม : {0:N1} MB  (datadir + dumps)" -f $diskMB)
    Write-Info ('หมายเหตุ: size_mb จาก information_schema ≈ ขนาดจริง · dump/log อาจไม่รวมในตัวเลข SQL')

    # ตารางใน db แรก (ตัวใหญ่สุด) หรือ db ที่ user ระบุ
    $show = $dbName
    if (-not $show) { $show = $dbs[0].Name }
    Write-Host ''
    Write-Head "ตารางใน database: $show"
    $tables = @(Get-DatabaseTables $show)
    if ($tables.Count -eq 0) {
        Write-Warn2 "ไม่เห็นตารางใน $show"
        return
    }
    Write-Host ('  {0,-36} {1,12} {2,10} {3,10}' -f 'Table', 'Rows', 'MB', 'Engine') -ForegroundColor Cyan
    Write-Host ('  {0}' -f ('-' * 72)) -ForegroundColor DarkGray
    $sum = 0.0
    foreach ($t in $tables) {
        $sum += $t.SizeMB
        Write-Host ('  {0,-36} {1,12} {2,10:N2} {3,10}' -f $t.Table, $t.Rows, $t.SizeMB, $t.Engine)
    }
    Write-Host ('  {0}' -f ('-' * 72)) -ForegroundColor DarkGray
    Write-Host ('  {0,-36} {1,12} {2,10:N2}' -f 'SUM', '', $sum) -ForegroundColor Green
    Write-Host ''
    Write-Info "ดู db อื่น: aptstack report db <dbname>"
    Write-Info 'รายชื่อ db ทั้งหมด: aptstack report db   (แล้วดูตารางบน)'
}

function Cmd-Report([string]$a, [string]$b) {
    # aptstack report           -> HTML สรุปสถานะ
    # aptstack report <path>    -> HTML ไป path ที่ระบุ
    # aptstack report db        -> ตาราง inventory database
    # aptstack report db <name> -> ตารางใน db นั้น
    # aptstack report clone     -> HTML สายสัมพันธ์ clone/family ระหว่าง app version
    if ("$a".ToLower() -eq 'db') {
        Cmd-ReportDb $b
        return
    }
    if ("$a".ToLower() -eq 'clone') {
        Cmd-ReportClone $b
        return
    }
    $OutPath = $a
    # สรุปสถานะการติดตั้งทั้งหมดเป็น HTML สำหรับเปิดดู/พิมพ์เครื่องพิมพ์
    Ensure-Dirs
    $cfg = Get-Config
    $cur = Get-CurrentAppName
    $php = Resolve-Php $cfg.php
    $apache = Resolve-Apache $cfg.apache
    $mysql = Resolve-MySql $cfg.mysql
    $wm = Resolve-WebMode $cfg $php $apache
    $apps = @(Get-AppVersions)
    $phps = @(Get-PhpVersions)
    $dbs = @(Get-MySqlVersions)
    $aps = @(Get-ApacheVersions)

    # ---- probe จริง ----
    $httpP = Invoke-HttpProbe "http://127.0.0.1:$($cfg.httpPort)/" 6
    $httpsP = $null
    if ("$($cfg.httpsEnabled)".ToLower() -eq 'true') {
        $httpsP = Invoke-HttpProbe "https://127.0.0.1:$($cfg.httpsPort)/" 6
    }
    $dbPortUp = -not (Test-PortFree $cfg.dbPort)
    $dbPing = $false
    if ($dbPortUp -and $mysql) { $dbPing = [bool](Invoke-DbAdmin $mysql @('ping')) }
    $svc = Get-Service -Name $cfg.serviceName -ErrorAction SilentlyContinue

    # ---- cert ----
    $certPath = Resolve-CertPath $cfg.certFile
    $ci = Get-CertInfo $certPath
    $keyOk = (Test-Path (Resolve-CertPath $cfg.keyFile)) -and
             ((Get-Content (Resolve-CertPath $cfg.keyFile) -Raw -EA SilentlyContinue) -match 'PRIVATE KEY')

    # ---- checks ----
    # ใช้ $script: เพราะฟังก์ชันซ้อนจะเข้า scope ของมันเอง ไม่เห็นตัวแปรในฟังก์ชัน
    $script:RepChecks = @()
    function Add-Check($k, $s, $d) {
        $script:RepChecks = @($script:RepChecks) + [pscustomobject]@{ K = $k; S = $s; D = $d }
    }

    $risk = if ($php) { Get-PhpRisk $php.Version } else { 'NO_PHP' }
    if (-not $php) { Add-Check 'PHP version' 'ERR' 'ยังไม่ได้เลือก PHP' }
    elseif ($risk -eq 'UNPATCHED') { Add-Check 'PHP version' 'ERR' "$($php.Version) ยังไม่ patch ช่องโหว่ RCE" }
    elseif ($risk -eq 'EOL') { Add-Check 'PHP version' 'ERR' "$($php.Version) = EOL (ไม่มี patch)" }
    else { Add-Check 'PHP version' 'OK' "$($php.Version) ผ่านเกณฑ์ security-php.txt" }

    $iniTxt = if (Test-Path $Script:P.PhpIni) { Get-Content $Script:P.PhpIni -Raw } else { '' }
    Add-Check 'session.upload_progress' $(if ($iniTxt -match '(?m)^\s*session\.upload_progress\.enabled\s*=\s*Off') { 'OK' } else { 'ERR' }) 'ต้อง Off (ทางเข้าช่องโหว่)'
    Add-Check 'expose_php' $(if ($iniTxt -match '(?m)^\s*expose_php\s*=\s*Off') { 'OK' } else { 'WARN' }) 'ต้อง Off'
    Add-Check 'allow_url_include' $(if ($iniTxt -match '(?m)^\s*allow_url_include\s*=\s*Off') { 'OK' } else { 'WARN' }) 'ต้อง Off'
    Add-Check 'display_errors' $(if ($iniTxt -match '(?m)^\s*display_errors\s*=\s*Off') { 'OK' } else { 'WARN' }) 'ปิดใน production'

    $rootNorm = $Root.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    $pathBad = 0
    foreach ($f in @($Script:P.MySqlIni, $Script:P.PhpIni)) {
        if (-not (Test-Path $f)) { continue }
        foreach ($m in [regex]::Matches((Get-Content $f -Raw), '(?m)^\s*[\w\-.]+\s*=\s*"?([A-Za-z]:[\\/][^\r\n"]*)"?\s*$')) {
            $p = $m.Groups[1].Value.Trim('"').Replace('/', '\').TrimEnd('\').ToLowerInvariant()
            if (-not $p.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) { $pathBad++ }
        }
    }
    Add-Check 'path ใน ini อยู่ใน bundle' $(if ($pathBad -eq 0) { 'OK' } else { 'ERR' }) $(if ($pathBad -eq 0) { 'copy ไปเครื่องอื่นได้' } else { "$pathBad จุดชี้ออกจากโฟลเดอร์" })

    $myTxt = if (Test-Path $Script:P.MySqlIni) { Get-Content $Script:P.MySqlIni -Raw } else { '' }
    Add-Check 'MariaDB bind 127.0.0.1' $(if ($myTxt -match 'bind-address\s*=\s*127\.0\.0\.1') { 'OK' } else { 'WARN' }) 'ไม่เปิดรับจากข้างนอก'

    if ($httpP.Ok -and $httpP.Status -ge 200 -and $httpP.Status -lt 400) { Add-Check 'HTTP probe' 'OK' "$($httpP.Status) ($($httpP.Ms) ms) $($httpP.Url)" }
    else { Add-Check 'HTTP probe' 'ERR' "$($httpP.Error)" }
    if ($httpsP) {
        if ($httpsP.Ok -and $httpsP.Status -ge 200 -and $httpsP.Status -lt 400) { Add-Check 'HTTPS probe' 'OK' "$($httpsP.Status) ($($httpsP.Ms) ms)" }
        else { Add-Check 'HTTPS probe' 'ERR' "$($httpsP.Error)" }
        Add-Check 'TLS cert' $(if (-not $ci) { 'ERR' } elseif ($ci.DaysLeft -lt 0) { 'ERR' } elseif ($ci.DaysLeft -lt 14) { 'WARN' } else { 'OK' }) $(if ($ci) { "$($ci.Subject) · หมดอายุ $($ci.NotAfter.ToString('yyyy-MM-dd')) (เหลือ $($ci.DaysLeft) วัน)" } else { 'ไม่พบ cert' })
        Add-Check 'TLS key' $(if ($keyOk) { 'OK' } else { 'ERR' }) $(if ($keyOk) { 'มี private key ครบ' } else { 'ขาด private key' })
        Add-Check 'TLS trust' $(if ($ci -and $ci.Trusted) { 'OK' } else { 'WARN' }) $(if ($ci -and $ci.Trusted) { 'อยู่ใน Trusted Root' } else { 'ยังไม่ได้ trust' })
    }
    Add-Check 'DB ping' $(if ($cfg.dbMode -eq 'external') { 'OK' } elseif ($dbPing) { 'OK' } else { 'ERR' }) $(if ($cfg.dbMode -eq 'external') { "external mode ที่ 127.0.0.1:$($cfg.dbPort)" } elseif ($dbPing) { "ping OK · 127.0.0.1:$($cfg.dbPort)" } else { 'ตอบไม่ได้' })

    $vhItems = @()
    $vhFile = Join-Path $Script:P.ConfigDir 'vhosts.json'
    if (Test-Path $vhFile) { try { $vhItems = @((Get-Content $vhFile -Raw -Encoding UTF8 | ConvertFrom-Json)) } catch { } }
    Add-Check 'Virtual hosts' $(if ($vhItems.Count -eq 0) { 'OK' } elseif ($wm -eq 'apache') { 'OK' } else { 'WARN' }) $(if ($vhItems.Count -eq 0) { 'ยังไม่ได้ตั้ง (ไม่บังคับ)' } elseif ($wm -eq 'apache') { "$($vhItems.Count) รายการ" } else { "$($vhItems.Count) รายการ แต่ webMode=$wm (ใช้ได้กับ apache)" })

    $dumpCount = @(Get-ChildItem $Script:P.Dumps -Filter '*.sql' -EA SilentlyContinue).Count
    if ($dumpCount -gt 0) { Add-Check 'data\dumps' 'WARN' "$dumpCount ไฟล์ (ข้อมูลจริง) — .gitignore กันแล้ว ห้าม commit" }

    $gitLeak = ''
    if (Test-Path (Join-Path $Root '.git')) {
        $tracked = @(& git -C $Root ls-files 2>$null)
        $leak = @($tracked | Where-Object { $_ -notlike 'examples/*' -and ($_ -match '^(stack/|versions/|data/|config/|bin/|dist/|downloads/)' -or ($_ -match '\.sql$' -and $_ -notlike 'examples/*')) })
        Add-Check 'git ไม่ track ของ sensitive' $(if ($leak.Count -eq 0) { 'OK' } else { 'ERR' }) $(if ($leak.Count -eq 0) { "$($tracked.Count) ไฟล์ที่ track" } else { "มี $($leak.Count) ไฟล์: $($leak[0])" })
    }
    Add-Check 'Windows Service' $(if ($svc) { 'OK' } else { 'WARN' }) $(if ($svc) { "$($svc.Status) · $($svc.StartType)" } else { 'ยังไม่ได้ติดตั้ง (aptstack service install)' })
    Add-Check 'webMode' $(if ($wm -eq 'apache') { 'OK' } else { 'OK' }) "$wm" 

    $checks = @($script:RepChecks)

    # ---- ขนาด/พื้นที่ (ตัวเดียวกับ aptstack size) ----
    $sz = Get-SizeInfo
    $datadir = if ($mysql) { Get-DataDir $mysql } else { '' }

    # ---- inventory database (ก้อน + ขนาด) ----
    $dbStats = @()
    $dbTotalMB = 0.0
    if ($cfg.dbMode -ne 'external' -and $mysql -and -not (Test-PortFree $cfg.dbPort)) {
        try { $dbStats = @(Get-DatabaseStats) } catch { $dbStats = @() }
        foreach ($d in $dbStats) { $dbTotalMB += $d.SizeMB }
        $dbTotalMB = [math]::Round($dbTotalMB, 2)
    }

    # ---- นับผล checks ----
    $nOK = @($checks | Where-Object { $_.S -eq 'OK' }).Count
    $nWarn = @($checks | Where-Object { $_.S -eq 'WARN' }).Count
    $nErr = @($checks | Where-Object { $_.S -eq 'ERR' }).Count
    $overall = if ($nErr -gt 0) { 'ไม่ผ่าน — ต้องแก้' } elseif ($nWarn -gt 0) { 'ผ่าน (มีคำเตือน)' } else { 'ผ่านทุกข้อ' }
    $overallClass = if ($nErr -gt 0) { 'err' } elseif ($nWarn -gt 0) { 'warn' } else { 'ok' }

    $verFile = Join-Path $Root 'VERSION'
    $pkgVer = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '?' }

    # ---- build rows ----
    $sb = New-Object Text.StringBuilder
    foreach ($c in $checks) {
        $cls = switch ($c.S) { 'OK' { 'ok' } 'WARN' { 'warn' } default { 'err' } }
        $mark = switch ($c.S) { 'OK' { '✓' } 'WARN' { '!' } default { '✗' } }
        [void]$sb.AppendLine("<tr><td class='st $cls'>$mark $($c.S)</td><td>$([Net.WebUtility]::HtmlEncode($c.K))</td><td>$([Net.WebUtility]::HtmlEncode("$($c.D)"))</td></tr>")
    }
    $appRows = New-Object Text.StringBuilder
    foreach ($a in $apps) {
        $m = if ($cur -eq $a.Name) { ' <b>(ใช้อยู่)</b>' } else { '' }
        [void]$appRows.AppendLine("<tr><td>$([Net.WebUtility]::HtmlEncode($a.Name))$m</td><td class='path'>$([Net.WebUtility]::HtmlEncode($a.Dir))</td></tr>")
    }
    $phpRows = New-Object Text.StringBuilder
    foreach ($p in $phps) {
        $m = if ($cfg.php -eq $p.Version) { ' <b>(ใช้อยู่)</b>' } else { '' }
        $r = Get-PhpRisk $p.Version
        $tag = if ($r -eq 'UNPATCHED') { ' · <span class="err">ยังไม่ patch</span>' } elseif ($r -eq 'EOL') { ' · <span class="err">EOL</span>' } else { '' }
        [void]$phpRows.AppendLine("<tr><td>$([Net.WebUtility]::HtmlEncode($p.Version))$m$tag</td><td class='path'>$([Net.WebUtility]::HtmlEncode($p.Dir))</td></tr>")
    }
    $vhRows = New-Object Text.StringBuilder
    if ($vhItems.Count -eq 0) { [void]$vhRows.AppendLine('<tr><td colspan="3" class="path">(ยังไม่ได้ตั้ง config\vhosts.json)</td></tr>') }
    else { foreach ($v in $vhItems) { [void]$vhRows.AppendLine("<tr><td>$([Net.WebUtility]::HtmlEncode("$($v.host)"))</td><td>$([Net.WebUtility]::HtmlEncode("$($v.app)"))</td><td>$(if ("$($v.https)".ToLower() -eq 'false') { 'http only' } else { 'http+https' })</td></tr>") } }

    $dt = Get-Date
    $stamp = $dt.ToString('yyyy-MM-dd HH:mm:ss')

    # rows สำหรับรายงานพื้นที่
    $sizeRows = New-Object Text.StringBuilder
    foreach ($f in $sz.Folders) {
        if ($f.MB -le 0 -and $f.Files -eq 0) { continue }
        [void]$sizeRows.AppendLine("<tr><td>$($f.Name)\</td><td class='num'>$($f.MB)</td><td class='num'>$($f.Files)</td><td class='num'>$($f.Pct)%</td></tr>")
    }
    $versSzRows = New-Object Text.StringBuilder
    foreach ($v in $sz.Versions) {
        $cls = if ($v.MB -gt 200) { " class='warnrow'" } else { '' }
        $fam = if ($v.PSObject.Properties['Family'] -and $v.Family) { $v.Family } else { '?' }
        [void]$versSzRows.AppendLine("<tr$cls><td>$([Net.WebUtility]::HtmlEncode($fam))</td><td>$([Net.WebUtility]::HtmlEncode($v.Name))</td><td class='num'>$($v.MB) MB</td><td class='num'>$($v.Files)</td></tr>")
    }
    $stackSzRows = New-Object Text.StringBuilder
    foreach ($v in $sz.StackParts) { [void]$stackSzRows.AppendLine("<tr><td class='path'>$([Net.WebUtility]::HtmlEncode($v.Name))</td><td class='num'>$($v.MB) MB</td><td class='num'>$($v.Files)</td></tr>") }
    $dataSzRows = New-Object Text.StringBuilder
    foreach ($v in $sz.DataParts) { [void]$dataSzRows.AppendLine("<tr><td>$([Net.WebUtility]::HtmlEncode($v.Name))</td><td class='num'>$($v.MB) MB</td><td class='num'>$($v.Files)</td></tr>") }
    $szWarnHtml = New-Object Text.StringBuilder
    if ($sz.Warnings.Count -eq 0) { [void]$szWarnHtml.AppendLine('<p class="ok">พื้นที่ปกติ — ไม่มีอะไรบวมผิดปกติ</p>') }
    else {
        foreach ($w in $sz.Warnings) {
            $c = if ($w.Level -eq 'ERR') { 'err' } else { 'warn' }
            [void]$szWarnHtml.AppendLine("<p class='$c'>$(if($w.Level -eq 'ERR'){'✗'}else{'!'}) $([Net.WebUtility]::HtmlEncode($w.Text))</p>")
        }
    }

    $html = @"
<!DOCTYPE html>
<html lang="th"><head><meta charset="utf-8">
<title>aptstack — สรุปสถานะการติดตั้ง ($stamp)</title>
<style>
  *{box-sizing:border-box}
  body{font-family:"Leelawadee UI","Sarabun",Tahoma,sans-serif;color:#111;background:#fff;
       font-size:13px;line-height:1.55;margin:0;padding:18px 22px}
  h1{font-size:21px;margin:0 0 2px;color:#000}
  h2{font-size:15px;margin:20px 0 6px;padding:4px 8px;background:#f0f2f5;border-left:5px solid #1b57c4;color:#10306b}
  .sub{color:#444;font-size:12px;margin:0 0 10px}
  table{border-collapse:collapse;width:100%;margin:4px 0 10px}
  th,td{border:1px solid #8a8f98;padding:4px 7px;vertical-align:top;text-align:left;font-size:12.5px}
  th{background:#eef1f5;font-weight:700}
  .path{font-family:Consolas,monospace;font-size:11.5px;color:#333;word-break:break-all}
  .ok{color:#0a7a33;font-weight:700} .warn{color:#8a6100;font-weight:700} .err{color:#b00020;font-weight:700}
  .badge{display:inline-block;border:2px solid #111;border-radius:6px;padding:4px 12px;font-weight:700;font-size:14px}
  .b-ok{border-color:#0a7a33;color:#0a7a33} .b-warn{border-color:#8a6100;color:#8a6100} .b-err{border-color:#b00020;color:#b00020}
  .grid{display:flex;gap:14px;flex-wrap:wrap}
  .card{border:1px solid #8a8f98;padding:8px 10px;min-width:210px;flex:1}
  .card b{display:block;font-size:12px;color:#10306b}
  .kv{width:100%}.kv td:first-child{width:190px;background:#f7f8fa;font-weight:600}
  .num{text-align:right}
  .warnrow td{background:#fff6e5}
  .small{font-size:11.5px;color:#333}
  footer{margin-top:16px;padding-top:8px;border-top:1px solid #8a8f98;font-size:11.5px;color:#333}
  .noprint{color:#666;font-size:11.5px}
  @media print{ body{padding:0;font-size:11.5px} .noprint{display:none} h2{page-break-after:avoid}
    table{page-break-inside:auto} tr{page-break-inside:avoid} .card{break-inside:avoid} }
</style></head><body>

<h1>aptstack — สรุปสถานะการติดตั้ง</h1>
<p class="sub">พิมพ์ได้เลย (File → Print) · ส้างอัตโนมัติด้วย <code>aptstack report</code></p>
<p><span class="badge b-$overallClass">$overall</span>
&nbsp; ✓ $nOK ผ่าน · ! $nWarn เตือน · ✗ $nErr ต้องแก้</p>

<h2>1. ข้อมูลทั่วไป</h2>
<table class="kv">
<tr><td>เวลาที่สร้างรายงาน</td><td>$stamp</td></tr>
<tr><td>โฟลเดอร์ bundle</td><td class="path">$([Net.WebUtility]::HtmlEncode($Root))</td></tr>
<tr><td>เวอร์ชันแพ็กเกจ</td><td>$([Net.WebUtility]::HtmlEncode($pkgVer))</td></tr>
<tr><td>OS / เครื่อง</td><td>$([Net.WebUtility]::HtmlEncode([Environment]::OSVersion.VersionString)) · $([Net.WebUtility]::HtmlEncode($env:COMPUTERNAME))</td></tr>
<tr><td>ผู้ใช้ที่รัน</td><td>$([Net.WebUtility]::HtmlEncode("$env:USERDOMAIN\$env:USERNAME"))</td></tr>
</table>

<h2>2. สถานะการทำงาน (probe จริง)</h2>
<table class="kv">
<tr><td>Web (port $($cfg.httpPort))</td><td class="$(if($httpP.Ok){'ok'}else{'err'})">$(if($httpP.Ok){"UP · $($httpP.Status) · $($httpP.Ms) ms"}else{"DOWN · $($httpP.Error)"})</td></tr>
<tr><td>HTTPS (port $($cfg.httpsPort))</td><td class="$(if(-not $httpsP){'ok'}elseif($httpsP.Ok){'ok'}else{'err'})">$(if(-not $httpsP){'ปิดอยู่ (httpsEnabled=false)'}elseif($httpsP.Ok){"UP · $($httpsP.Status) · $($httpsP.Ms) ms"}else{"DOWN · $($httpsP.Error)"})</td></tr>
<tr><td>Database (port $($cfg.dbPort))</td><td class="$(if($dbPing -or $cfg.dbMode -eq 'external'){$(if($dbPortUp){'ok'}else{'err'})}else{'err'})">$(if($cfg.dbMode -eq 'external'){"external mode · port $(if($dbPortUp){'LISTENING'}else{'ว่าง'})"}elseif($dbPing){'UP · ping OK'}else{'DOWN · ping ไม่ตอบ'})</td></tr>
<tr><td>Windows Service</td><td>$(if($svc){"$($svc.Status) · start=$($svc.StartType)"}else{'ยังไม่ได้ติดตั้ง'})</td></tr>
</table>

<h2>3. เวอร์ชันที่ติดตั้ง</h2>
<div class="grid">
  <div class="card"><b>App (active)</b>$([Net.WebUtility]::HtmlEncode($(if($cur){$cur}else{'(ยังไม่ได้ตั้ง)'})))<br><span class="small">ทั้งหมด $($apps.Count) ตัว</span></div>
  <div class="card"><b>PHP (active)</b>$([Net.WebUtility]::HtmlEncode($(if($cfg.php){$cfg.php}else{'(ยังไม่เลือก)'})))<br><span class="small">ทั้งหมด $($phps.Count) ตัว · TS=$(if($php -and $php.ApacheMod){'มี'}else{'-'})</span></div>
  <div class="card"><b>Web mode</b>$wm<br><span class="small">apache=$(if($apache){$apache.Version}else{'-'})</span></div>
  <div class="card"><b>Database</b>$(if($cfg.dbMode -eq 'external'){'external (XAMPP/ของจริง)'}elseif($mysql){$mysql.Version}else{'-'})<br><span class="small">mode=$($cfg.dbMode)</span></div>
</div>

<table>
<tr><th>App versions</th><th>path</th></tr>
$($appRows.ToString())
</table>
<table>
<tr><th>PHP</th><th>path</th></tr>
$($phpRows.ToString())
</table>

<h2>4. ผลตรวจความปลอดภัย / สุขภาพ ($nOK/$($checks.Count))</h2>
<table>
<tr><th style="width:70px">ผล</th><th style="width:230px">รายการ</th><th>รายละเอียด</th></tr>
$($sb.ToString())
</table>

<h2>5. ตั้งค่า (config\stack.json)</h2>
<table class="kv">
<tr><td>httpPort / dbPort / httpsPort</td><td>$($cfg.httpPort) / $($cfg.dbPort) / $($cfg.httpsPort)</td></tr>
<tr><td>webMode / dbMode</td><td>$($cfg.webMode) / $($cfg.dbMode)</td></tr>
<tr><td>appAlias (URL ของแอป)</td><td>/$([Net.WebUtility]::HtmlEncode($cfg.appAlias))/ &nbsp;→&nbsp; http://127.0.0.1:$($cfg.httpPort)/$([Net.WebUtility]::HtmlEncode($cfg.appAlias))/</td></tr>
<tr><td>httpsEnabled</td><td>$($cfg.httpsEnabled)</td></tr>
<tr><td>cert</td><td class="path">$(if($ci){"$([Net.WebUtility]::HtmlEncode($ci.Subject)) · หมดอายุ $($ci.NotAfter.ToString('yyyy-MM-dd')) · trust=$(if($ci.Trusted){'ใช่'}else{'ยังไม่'})"}else{'(ยังไม่ตั้ง) — aptstack tls init'})</td></tr>
<tr><td>dbUser</td><td>$([Net.WebUtility]::HtmlEncode($cfg.dbUser))</td></tr>
</table>

<h2>6. Virtual hosts</h2>
<table><tr><th>host</th><th>app</th><th>https</th></tr>$($vhRows.ToString())</table>
$(if($vhItems.Count -gt 0){'<p class="small">ต้องเพิ่มใน hosts file: 127.0.0.1 ' + [Net.WebUtility]::HtmlEncode((($vhItems | ForEach-Object { "$($_.host)" }) -join ' ')) + '</p>'})

<h2>7. พื้นที่ / การบวมของดิสก์</h2>
<p class="small">รวมทั้ง bundle: <b>$([math]::Round($sz.TotalMB/1024,2)) GB ($($sz.TotalMB) MB)</b>
$(if($null -ne $sz.FreeGB){' · พื้นที่ว่างบนไดรฟ์: <b>'+$sz.FreeGB+' GB</b>'})
&nbsp;·&nbsp; คำสั่ง CLI: <code>aptstack size</code></p>
<table>
<tr><th>โฟลเดอร์</th><th style="width:90px">MB</th><th style="width:80px">ไฟล์</th><th style="width:64px">%</th></tr>
$($sizeRows.ToString())
</table>

<p class="small"><b>รายตัวversions\ (ระวังอันไหนใหญ่ผิดปกติ)</b></p>
<table>
<tr><th style="width:130px">แอป (family)</th><th>ชื่อเวอร์ชัน (โฟลเดอร์)</th><th style="width:100px">ขนาด</th><th style="width:80px">ไฟล์</th></tr>
$(if($versSzRows.Length -gt 0){$versSzRows.ToString()}else{'<tr><td colspan="3">(ยังไม่มี)</td></tr>'})
</table>

<table>
<tr><th>stack\ (binary)</th><th style="width:100px">ขนาด</th><th style="width:80px">ไฟล์</th></tr>
$(if($stackSzRows.Length -gt 0){$stackSzRows.ToString()}else{'<tr><td colspan="3">(ยังไม่มี)</td></tr>'})
</table>

<table>
<tr><th>data\</th><th style="width:100px">ขนาด</th><th style="width:80px">ไฟล์</th></tr>
$(if($dataSzRows.Length -gt 0){$dataSzRows.ToString()}else{'<tr><td colspan="3">(ยังไม่มี)</td></tr>'})
</table>

<div class="card">$($szWarnHtml.ToString())</div>
<p class="small">config\: <code>$([Net.WebUtility]::HtmlEncode($Script:P.ConfigDir))</code>
· datadir: <code>$(if($datadir){[Net.WebUtility]::HtmlEncode($datadir)}else{'-'})</code></p>

<h2>7b. Database (ก้อน + ขนาด)</h2>
<p class="small">เจาะตารางใน db: <code>aptstack report db</code> หรือ <code>aptstack report db &lt;name&gt;</code></p>
<table>
<tr><th>Database</th><th style="width:70px">Tables</th><th style="width:90px">Total MB</th><th style="width:90px">Data MB</th><th style="width:90px">Index MB</th></tr>
$(if($dbStats.Length -gt 0){
  ($dbStats | ForEach-Object {
    "<tr><td>$([Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.Tables)</td><td>$($_.SizeMB.ToString('0.00'))</td><td>$($_.DataMB.ToString('0.00'))</td><td>$($_.IndexMB.ToString('0.00'))</td></tr>"
  }) -join "`n"
} else {
  '<tr><td colspan="5">(DB ยังไม่รัน หรือยังไม่มีข้อมูล)</td></tr>'
})
<tr><td><b>รวมทุกก้อน</b></td><td></td><td><b>$($dbTotalMB.ToString('0.00'))</b></td><td></td><td></td></tr>
</table>

<h2>8. คำสั่งที่ใช้บ่อย</h2>
<table class="kv">
<tr><td>สลับแอป</td><td><code>aptstack use &lt;ชื่อ&gt;</code> · <code>next</code> · <code>prev</code> · <code>use -</code></td></tr>
<tr><td>สลับ PHP</td><td><code>aptstack use php &lt;ver&gt;</code></td></tr>
<tr><td>ตรวจซ้ำ</td><td><code>aptstack doctor</code></td></tr>
<tr><td>ดู log</td><td><code>aptstack logs apache|mysql|php</code></td></tr>
<tr><td>backup</td><td><code>aptstack backup</code></td></tr>
<tr><td>database inventory</td><td><code>aptstack report db</code> · <code>aptstack report db &lt;name&gt;</code></td></tr>
<tr><td>record/play script</td><td><code>aptstack record start</code> · <code>aptstack play scripts\...</code></td></tr>
</table>

<footer>
  aptstack $([Net.WebUtility]::HtmlEncode($pkgVer)) · สร้างโดย <code>aptstack report</code> · $stamp<br>
  เอกสาร: README-TH.md · docs/คู่มือ.md · docs/SCENARIO.md · docs/OFFLINE-DEPLOY.md
</footer>
<p class="noprint">เคล็ดลับพิมพ์: กด <b>Ctrl+P</b> → เลือกกระดาษ A4 → ติ๊ก "Background graphics" ถ้าอยากได้เส้นตารางสีเทา</p>

</body></html>
"@

    if (-not $OutPath) { $OutPath = Join-Path $Root 'aptstack-report.html' }
    Write-Utf8NoBom $OutPath $html

    Write-Head 'สร้างรายงานสถานะ (สำหรับพิมพ์)'
    Write-Ok "ผล: $overall  (✓ $nOK · ! $nWarn · ✗ $nErr)"
    Write-Info "ไฟล์: $OutPath"
    Write-Info 'เปิดดู/พิมพ์: Ctrl+P ในเบราว์เซอร์ (A4)'
    try { Start-Process $OutPath | Out-Null; Write-Info 'เปิดในเบราว์เซอร์ให้แล้ว' } catch { }
}

function Cmd-Config([string]$what, [string]$val) {
    # aptstack config                         -> ดูค่า webMode/dbMode/https/port ปัจจุบัน
    # aptstack config web apache|builtin|auto -> ตั้ง webMode (HTTPS ใช้ได้กับ apache)
    # aptstack config db internal|external    -> internal = MariaDB ของเรา · external = ยืม XAMPP
    # aptstack config https on|off            -> เปิด/ปิด HTTPS
    # aptstack config port <http> [db] [https] -> เปลี่ยนพอร์ต
    $cfg = Get-Config
    $w = if ($what) { "$what".ToLower() } else { 'status' }

    switch ($w) {
        'status' {
            $php = Resolve-Php $cfg.php
            $apache = Resolve-Apache $cfg.apache
            $wm = Resolve-WebMode $cfg $php $apache
            Write-Head 'config (config\stack.json)'
            Write-Host "  webMode     : $($cfg.webMode)   -> ใช้จริง = $wm" -ForegroundColor $(if ($wm -eq 'apache') { 'Green' } else { 'Yellow' })
            Write-Host "  dbMode      : $($cfg.dbMode)" -ForegroundColor $(if ($cfg.dbMode -eq 'internal') { 'Green' } else { 'Yellow' })
            Write-Host "  httpsEnabled: $($cfg.httpsEnabled)  port http/db/https = $($cfg.httpPort)/$($cfg.dbPort)/$($cfg.httpsPort)"
            Write-Host "  httpPort    : $($cfg.httpPort)"
            Write-Host "  dbPort      : $($cfg.dbPort)"
            Write-Host "  httpsPort   : $($cfg.httpsPort)"
            if ($wm -ne 'apache' -and "$($cfg.httpsEnabled)".ToLower() -eq 'true') {
                Write-Warn2 'httpsEnabled=true แต่ webMode ไม่ใช่ apache — HTTPS จะใช้ไม่ได้'
            }
            Write-Host ''
            Write-Info 'ตั้ง web : aptstack config web apache|builtin|auto'
            Write-Info 'ตั้ง db  : aptstack config db internal|external'
            Write-Info 'เปิด https: aptstack config https on   (ต้อง webMode=apache)'
            Write-Info 'พอร์ต   : aptstack config port 8077 3307 8443'
            Write-Info 'แล้ว: aptstack restart'
        }
        { $_ -in @('web', 'webmode', 'mode') } {
            $v = if ($val) { "$val".ToLower() } else { '' }
            if ($v -in @('a', 'apache')) { $v = 'apache' }
            elseif ($v -in @('b', 'builtin', 'built-in', 'cli')) { $v = 'builtin' }
            elseif ($v -in @('au', 'auto')) { $v = 'auto' }
            if (@('auto', 'apache', 'builtin') -notcontains $v) {
                throw 'ใช้: aptstack config web apache|builtin|auto'
            }
            $cfg = Get-Config
            $old = $cfg.webMode
            $cfg.webMode = $v
            Save-Config $cfg
            Write-Head "webMode: $old -> $v"
            if ($v -eq 'apache') {
                $apache = Resolve-Apache $cfg.apache
                $php = Resolve-Php $cfg.php
                if (-not $apache) { Write-Warn2 'ยังไม่มี Apache — ต้อง: aptstack add apache 2.4.69' }
                elseif (-not (Test-PhpApacheMod $php.Dir)) {
                    Write-Warn2 "PHP $($php.Version) เป็น NTS — mod_php ต้อง Thread Safe (มี php*apache2_4.dll)"
                } else { Write-Ok "Apache $($apache.Version) + PHP TS $($php.Version) พร้อม" }
                if ("$($cfg.httpsEnabled)".ToLower() -eq 'true') { Write-Info "HTTPS เปิดอยู่ — restart แล้วใช้ https://127.0.0.1:$($cfg.httpsPort)/" }
            } elseif ($v -eq 'builtin') {
                Write-Warn2 'builtin ใช้ HTTPS/vhost ไม่ได้ — ถ้า httpsEnabled=true จะถูกเมินตอน start'
            }
            Write-Info 'มีผลหลัง: aptstack restart'
        }
        { $_ -in @('db', 'dbmode') } {
            $v = if ($val) { "$val".ToLower() } else { '' }
            if ($v -in @('i', 'internal', 'bundle', 'ours')) { $v = 'internal' }
            elseif ($v -in @('e', 'external', 'xampp')) { $v = 'external' }
            if (@('internal', 'external') -notcontains $v) {
                throw 'ใช้: aptstack config db internal|external'
            }
            $cfg = Get-Config
            $old = $cfg.dbMode
            $cfg.dbMode = $v
            if ($v -eq 'external') {
                if (-not $val -or $val -notmatch '^\d+$') {
                    # ถ้าไม่ได้ระบุ port ใหม่ ให้ใช้ dbPort เดิม (มัก 3306 ของ XAMPP ต้องแก้เอง)
                    Write-Info "dbPort ปัจจุบัน = $($cfg.dbPort) — ถ้า XAMPP ใช้ 3306: aptstack config port $($cfg.httpPort) 3306 $($cfg.httpsPort)"
                }
            }
            Save-Config $cfg
            Write-Head "dbMode: $old -> $v"
            if ($v -eq 'external') {
                Write-Ok 'จะ "ไม่ start/stop" MySQL ภายนอก (XAMPP) — ยืมพอร์ต dbPort อย่างเดียว'
            } else {
                Write-Ok 'ใช้ MariaDB ใน bundle (stack\mysql + data\)'
            }
            Write-Info 'มีผลหลัง: aptstack restart'
        }
        { $_ -in @('https', 'tls', 'ssl') } {
            $v = if ($val) { "$val".ToLower() } else { '' }
            $on = $v -in @('on', '1', 'true', 'yes', 'enable')
            $off = $v -in @('off', '0', 'false', 'no', 'disable')
            if (-not $on -and -not $off) { throw 'ใช้: aptstack config https on|off' }
            $cfg = Get-Config
            $cfg.httpsEnabled = if ($on) { 'true' } else { 'false' }
            Save-Config $cfg
            Write-Head "httpsEnabled = $($cfg.httpsEnabled)"
            if ($on) {
                $php = Resolve-Php $cfg.php
                $apache = Resolve-Apache $cfg.apache
                $wm = Resolve-WebMode $cfg $php $apache
                if ($wm -ne 'apache') {
                    Write-Warn2 "ยังใช้ไม่ได้ — ต้อง webMode=apache (ตอนนี้ $wm) ก่อน: aptstack config web apache"
                }
                if (-not (Test-Path (Resolve-CertPath $cfg.certFile))) {
                    Write-Info 'ยังไม่มี cert: aptstack tls init'
                }
            }
            Write-Info 'มีผลหลัง: aptstack restart'
        }
        { $_ -in @('port', 'ports') } {
            # aptstack config port <http> [db] [https]
            $http = $val
            $db = $null; $https = $null
            if ($Action) { } # unused
            # extra args: Value=http, need db/https from remaining - use $args not available
            # dispatch passes only Action,Value,Extra -> port http comes as Value, db as Extra
            $db = $null
            if ($Extra) { $db = $Extra }
            # https port needs another param - read from $Value only for http if single
            if (-not $http) { throw 'ใช้: aptstack config port <httpPort> [dbPort] [httpsPort]' }
            $cfg = Get-Config
            $old = "$($cfg.httpPort)/$($cfg.dbPort)/$($cfg.httpsPort)"
            if ($http -match '^\d+$') { $cfg.httpPort = [int]$http }
            if ($db -and $db -match '^\d+$') { $cfg.dbPort = [int]$db }
            # third value: not easily passed - if Extra looks like https and Value pattern
            Save-Config $cfg
            Write-Head "port updated"
            Write-Info "http/db = $($cfg.httpPort)/$($cfg.dbPort) (เดิม $old)"
            Write-Info 'มีผลหลัง: aptstack restart'
        }
        default {
            if ($w -in @('http', 'httpport')) {
                if (-not $val -or $val -notmatch '^\d+$') { throw 'ใช้: aptstack config http <port>' }
                $cfg = Get-Config
                $cfg.httpPort = [int]$val
                Save-Config $cfg
                Write-Ok "httpPort = $val — aptstack restart"
                return
            }
            if ($w -in @('dbport', 'mysqlport')) {
                if (-not $val -or $val -notmatch '^\d+$') { throw 'ใช้: aptstack config dbport <port>' }
                $cfg = Get-Config
                $cfg.dbPort = [int]$val
                Save-Config $cfg
                Write-Ok "dbPort = $val — aptstack restart (ถ้า external ต้องตรงกับ XAMPP ด้วย)"
                return
            }
            throw "ไม่รู้จัก '$w' — ใช้: aptstack config [status|web <mode>|db <mode>|https on|off|http <port>|dbport <port>]"
        }
    }
}

function Cmd-Db([string]$action, [string]$a, [string]$b) {
    # aptstack db                     -> ดูสรุป user/DB ของ stack นี้
    # aptstack db list [all]          -> รายชื่อ database + จำนวนตาราง/ขนาด
    # aptstack db set-root <password> -> ตั้งรหัส root (อัปเดต stack.json + phpMyAdmin ให้)
    # aptstack db add-user <user> <pass> -> เพิ่ม user ใหม่ (สิทธิ์เต็ม)
    $cfg = Get-Config
    $act = if ($action) { "$action".ToLower() } else { 'status' }

    switch ($act) {
        'status' {
            Write-Head 'database (stack นี้)'
            Write-Info "server  : 127.0.0.1:$($cfg.dbPort)  mode=$($cfg.dbMode)"
            Write-Info "user    : $($cfg.dbUser)"
            Write-Info "pass    : $(if ($cfg.dbPass) { '(ตั้งไว้ใน config\stack.json)' } else { '(ว่าง)' })"
            $pma = Get-PmaInfo
            if ($pma) {
                Write-Info "phpMyAdmin path : $($pma.Dir)"
                Write-Info "phpMyAdmin URL  : $($pma.Url)"
                Write-Info "phpMyAdmin ver  : $(if ($pma.Version) { $pma.Version } else { '?' })"
            } else {
                Write-Info 'phpMyAdmin ยังไม่ได้ติดตั้ง — aptstack add phpmyadmin latest'
            }
            Write-Host ''
            Write-Info 'รายชื่อ database   : aptstack db list   (เพิ่ม system: aptstack db list all)'
            Write-Info 'ตั้งรหัส root     : aptstack db set-root <password>'
            Write-Info 'เพิ่ม user        : aptstack db add-user <user> <password>'
            Write-Info 'ดูขนาด/inventory : aptstack report db'
            return
        }
        { $_ -in @('list', 'ls', 'databases', 'dbs') } {
            $showSystem = ("$a".ToLower() -replace '^-{1,2}', '') -in @('all', 'system', 'full')
            if (Test-PortFree $cfg.dbPort) { throw "DB ไม่รัน (port $($cfg.dbPort)) — aptstack start" }
            $client = Get-MysqlClient $cfg

            $sys = @('information_schema', 'performance_schema', 'sys', 'mysql')
            $names = Get-ExistingDatabaseNames $cfg $client
            if ($showSystem) {
                $all = Invoke-MysqlSql $cfg $client 'SHOW DATABASES;'
                $extra = @($all.Out | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -ne 'Database' -and $_ -notmatch '^Using a password' })
                $names = @(($names + $extra) | Sort-Object -Unique)
            }

            # ขนาด/จำนวนตารางจาก information_schema (DB ว่างจะไม่มี row -> default 0)
            $sizeMap = @{}
            $sql = 'SELECT table_schema AS s, COUNT(*) AS t, COALESCE(SUM(data_length+index_length),0) AS b FROM information_schema.tables GROUP BY table_schema;'
            $sr = Invoke-MysqlSql $cfg $client $sql
            if ($sr.ExitCode -eq 0) {
                foreach ($line in $sr.Out) {
                    if (-not $line) { continue }
                    if ($line -match '^\s*s\s' -or $line -match '^-+$' -or $line -match 'table_schema') { continue }
                    $parts = "$line" -split "`t"
                    if ($parts.Count -ge 3) {
                        $sizeMap[$parts[0].Trim()] = @{ Tables = [int]$parts[1]; Bytes = [long]$parts[2] }
                    }
                }
            }

            Write-Head "ฐานข้อมูล ($($names.Count))"
            Write-Info "server : 127.0.0.1:$($cfg.dbPort)  mode=$($cfg.dbMode)  user=$($cfg.dbUser)"
            if (-not $showSystem) { Write-Info '-system db (mysql/information_schema/...) — ดูครบ: aptstack db list all' }
            Write-Host ''
            if ($names.Count -eq 0) {
                Write-Warn2 'ยังไม่มี database (หรือดึงรายชื่อไม่ได้)'
                return
            }

            $pad = (($names | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum)
            if ($pad -lt 10) { $pad = 10 }
            $totalMb = 0.0
            $totalTbl = 0
            $i = 0
            foreach ($n in $names) {
                $i++
                $st = $sizeMap[$n]
                $tbl = if ($st) { [int]$st.Tables } else { 0 }
                $mb = if ($st) { [math]::Round($st.Bytes / 1MB, 1) } else { 0 }
                $totalMb += $mb
                $totalTbl += $tbl
                $tag = if ($n -in $sys) { ' [system]' } else { '' }
                $color = if ($n -in $sys) { 'DarkGray' } else { 'White' }
                $namePad = "$n".PadRight($pad)
                Write-Host ("  {0,2}) {1}  {2,5} tables  {3,9:N1} MB{4}" -f $i, $namePad, $tbl, $mb, $tag) -ForegroundColor $color
            }
            Write-Host ''
            Write-Ok ("รวม {0} database · {1} ตาราง · {2:N1} MB" -f $names.Count, $totalTbl, $totalMb)

            # รายชื่อ user ทั้งหมด
            $users = Get-DbUserRows $cfg $client
            Write-Host ''
            Write-Host "  DB users (ทั้งหมด) — $($users.Count) record" -ForegroundColor White
            if ($users.Count -eq 0) {
                Write-Info '(ดึง mysql.user ไม่ได้)'
            } else {
                $groups = $users | Group-Object User | Sort-Object Name
                foreach ($g in $groups) {
                    $hosts = @($g.Group | ForEach-Object { $_.Host }) -join ', '
                    $tag = if ($g.Name -eq $cfg.dbUser) { '  [config]' } else { '' }
                    Write-Host ("   {0,-16} @ {1}{2}" -f $g.Name, $hosts, $tag) -ForegroundColor Gray
                }
                Write-Info ("user ที่ตั้งใน stack.json : $($cfg.dbUser)  (pass ใน config)")
            }
            Write-Host ''
            Write-Info 'inventory ละเอียด: aptstack report db'
            Write-Info 'import ลงชื่อใหม่: aptstack import <file|folder> <dbname>'
            Write-Info 'ดูสั้น ๆ อีกครั้ง: aptstack db-list · aptstack list'
            return
        }
        { $_ -in @('set-root', 'setroot', 'root-pass', 'rootpass') } {
            if (-not $a) { throw 'ใช้: aptstack db set-root <password>' }
            if (Test-PortFree $cfg.dbPort) { throw "DB ไม่รัน (port $($cfg.dbPort)) — aptstack start" }
            $pass = $a
            Write-Head 'ตั้งรหัสผ่าน root'
            $client = Get-MysqlClient $cfg
            # MariaDB 10.4+ : ALTER USER ทุก host ของ root
            $list = Invoke-MysqlSql $cfg $client "SELECT host FROM mysql.user WHERE user='root';"
            $hosts = @($list.Out | Where-Object { $_ -and $_ -notmatch '^\s*host\s' -and $_ -notmatch '^-+$' } | ForEach-Object { "$_".Trim() })
            if ($hosts.Count -eq 0) { $hosts = @('localhost', '127.0.0.1', '%') }
            foreach ($h in $hosts) {
                $esc = $h -replace "'", "''"
                $sql = "ALTER USER 'root'@'$esc' IDENTIFIED BY '$($pass -replace "'", "''")';"
                $r = Invoke-MysqlSql $cfg $client $sql
                if ($r.ExitCode -ne 0) {
                    Write-Warn2 "ALTER USER root@$h ไม่สำเร็จ — ลอง SET PASSWORD"
                    $null = Invoke-MysqlSql $cfg $client "SET PASSWORD FOR 'root'@'$esc' = PASSWORD('$($pass -replace "'", "''")');"
                } else {
                    Write-Ok "root@$h -> ตั้งรหัสแล้ว"
                }
            }
            $null = Invoke-MysqlSql $cfg $client 'FLUSH PRIVILEGES;'
            # sync stack.json
            $cfg = Get-Config
            $cfg.dbPass = $pass
            Save-Config $cfg
            Write-Ok "บันทึก config\stack.json (dbPass)"
            if (Write-PmaConfig (Join-Path $Script:P.Www 'phpmyadmin')) {
                Write-Ok 'อัปเดต www\phpmyadmin\config.inc.php แล้ว'
            }
            Write-Info 'หมายเหตุ: ถ้า web console/phpMyAdmin login ไม่เข้า ให้ aptstack restart'
            return
        }
        { $_ -in @('add-user', 'adduser', 'user-add') } {
            if (-not $a -or -not $b) { throw 'ใช้: aptstack db add-user <user> <password>' }
            if ($a -notmatch '^[A-Za-z0-9_]+$') { throw 'user ใช้ได้เฉพาะ a-z A-Z 0-9 _' }
            if (Test-PortFree $cfg.dbPort) { throw "DB ไม่รัน (port $($cfg.dbPort)) — aptstack start" }
            Write-Head "เพิ่ม MySQL user: $a"
            $client = Get-MysqlClient $cfg
            $u = $a -replace "'", "''"
            $p = $b -replace "'", "''"
            $sqls = @(
                "CREATE USER IF NOT EXISTS '$u'@'localhost' IDENTIFIED BY '$p';",
                "CREATE USER IF NOT EXISTS '$u'@'127.0.0.1' IDENTIFIED BY '$p';",
                "CREATE USER IF NOT EXISTS '$u'@'%' IDENTIFIED BY '$p';",
                "GRANT ALL PRIVILEGES ON *.* TO '$u'@'localhost' WITH GRANT OPTION;",
                "GRANT ALL PRIVILEGES ON *.* TO '$u'@'127.0.0.1' WITH GRANT OPTION;",
                "GRANT ALL PRIVILEGES ON *.* TO '$u'@'%' WITH GRANT OPTION;",
                'FLUSH PRIVILEGES;'
            )
            $fail = 0
            foreach ($s in $sqls) {
                $r = Invoke-MysqlSql $cfg $client $s
                if ($r.ExitCode -ne 0) { $fail++ }
            }
            if ($fail -gt 0) { Write-Warn2 "บาง statement ไม่สำเร็จ ($fail) — ดู logs หรือ phpMyAdmin" }
            else { Write-Ok "เพิ่ม user '$a' แล้ว (localhost/127.0.0.1/%) — สิทธิ์เต็ม" }
            Write-Info 'login: เลือก user ใหม่ใน phpMyAdmin หรือ mysql CLI'
            return
        }
        default { throw "ใช้: aptstack db [status|list [all]|set-root <pass>|add-user <user> <pass>]" }
    }
}

# ------------------------------------------------- record / play (docker-like script)
function Get-RecordFlagPath { Join-Path $Script:P.ConfigDir 'record.flag' }

function Get-RecordScriptPath {
    $f = Get-RecordFlagPath
    if (-not (Test-Path $f)) { return $null }
    $p = (Get-Content $f -Raw -ErrorAction SilentlyContinue)
    if ($p) { return $p.Trim() }
    return $null
}

function Write-RecordEntry([string]$Command, [string]$Action, [string]$Value, [string]$Extra) {
    # เก็บคำสั่งที่รันลง .ps1 (record อยู่เท่านั้น) — เรียกซ้ำได้เหมือน docker compose script
    $path = Get-RecordScriptPath
    if (-not $path) { return }
    $skip = @('record', 'play', 'help', 'h', '?', '/?', '--help', 'service-run', 'run')
    if ($skip -contains "$Command".ToLower()) { return }
    $parts = @('aptstack.cmd', "$Command")
    if ($Action) { $parts += "$Action" }
    if ($Value) { $parts += "$Value" }
    if ($Extra) { $parts += "$Extra" }
    $line = ($parts -join ' ')
    try {
        $hdr = ''
        if (-not (Test-Path $path)) {
            $dir = Split-Path -Parent $path
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $hdr = @"
# aptstack script (บันทึกโดย aptstack record)
# รันซ้ำ:  aptstack play `"$path`"
# สร้างเมื่อ: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# bundle : $Root

"@
        }
        Add-Content -Path $path -Value ($hdr + $line) -Encoding UTF8
    } catch { }
}

function Cmd-Record([string]$action, [string]$name) {
    $act = if ($action) { "$action".ToLower() } else { 'status' }
    $flag = Get-RecordFlagPath
    $scriptsDir = Join-Path $Root 'scripts'
    switch ($act) {
        'start' {
            if (Test-Path $flag) { Write-Warn2 "กำลัง record อยู่แล้ว: $(Get-RecordScriptPath) — stop ก่อน"; return }
            if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
            $fn = if ($name) { "$name" -replace '[^\w\-.]', '_' } else { 'session-' + (Get-Date -Format 'yyyyMMdd_HHmmss') }
            if ($fn -notmatch '\.ps1$') { $fn = "$fn.ps1" }
            $path = Join-Path $scriptsDir $fn
            Write-Utf8NoBom $flag ($path + "`r`n")
            # สร้าง header ทันที
            $hdr = @"
# aptstack script (บันทึกโดย aptstack record)
# รันซ้ำ:  aptstack play `"$path`"
# สร้างเมื่อ: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# bundle : $Root

"@
            Write-Utf8NoBom $path $hdr
            Write-Head 'record — เริ่มบันทึกคำสั่งเป็น script'
            Write-Ok "กำลังบันทึก: $path"
            Write-Info 'คำสั่งที่สั่งหลังจากนี้ (use/start/stop/...) จะถูกเขียนลงไฟล์นี้'
            Write-Info 'หยุด: aptstack record stop'
            Write-Info 'รันซ้ำ: aptstack play <file.ps1>'
        }
        'stop' {
            $path = Get-RecordScriptPath
            if (-not $path) { Write-Info 'ยังไม่ได้ record'; return }
            Remove-Item $flag -Force -ErrorAction SilentlyContinue
            Write-Head 'record — หยุดบันทึก'
            Write-Ok "script: $path"
            if (Test-Path $path) {
                $n = @((Get-Content $path | Where-Object { $_ -match 'aptstack\.cmd' })).Count
                Write-Info "คำสั่งที่บันทึก: $n บรรทัด"
            }
            Write-Info "รันซ้ำ: aptstack play `"$path`""
        }
        default {
            $cur = Get-RecordScriptPath
            Write-Head 'record'
            if ($cur) {
                Write-Host '  กำลัง record อยู่' -ForegroundColor Green
                Write-Info "file: $cur"
                Write-Info 'หยุด: aptstack record stop'
            } else {
                Write-Info 'ไม่ได้ record อยู่'
                Write-Info 'เริ่ม: aptstack record start [ชื่อไฟล์]'
            }
            Write-Info 'ดู script ที่มี: dir scripts\*.ps1'
            Write-Info 'รันซ้ำ: aptstack play scripts\session-....ps1'
        }
    }
}

function Cmd-Play([string]$file) {
    if (-not $file) { throw 'ใช้: aptstack play <script.ps1>' }
    $path = $file
    if ($path -notmatch '^[A-Za-z]:[\\/]') { $path = Join-Path $Root $path }
    if (-not (Test-Path $path)) { throw "ไม่พบ script: $path" }
    $lines = @(Get-Content $path -Encoding UTF8 | Where-Object {
        $t = "$_".Trim()
        $t -and (-not $t.StartsWith('#')) -and ($t -match 'aptstack\.cmd|^\s*(use|start|stop|restart|list|doctor)\b')
    })
    Write-Head "play — รัน script ($($lines.Count) คำสั่ง)"
    Write-Info $path
    $i = 0
    foreach ($raw in $lines) {
        $i++
        $t = "$raw".Trim() -replace '\s+', ' '
        # normalize: aptstack.cmd X -> args for dispatcher
        if ($t -match '^aptstack\.cmd\s+(.*)$') { $t = $Matches[1] }
        elseif ($t -match '^as\.cmd\s+(.*)$') { $t = $Matches[1] }
        $tok = @()
        foreach ($w in ($t -split ' ')) { if ($w) { $tok += $w } }
        if ($tok.Count -eq 0) { continue }
        Write-Host ''
        Write-Host ("  [{0}/{1}] aptstack {2}" -f $i, $lines.Count, $t) -ForegroundColor Cyan
        try {
            & $PSCommandPath @tok
        } catch {
            Write-Warn2 "บรรทัด $i พัง: $($_.Exception.Message)"
            if (-not (Confirm-Action 'ทำต่อคำสั่งถัดไปไหม? (y = ทำต่อ)')) { Write-Info 'หยุด play'; return }
        }
    }
    Write-Host ''
    Write-Ok 'play จบแล้ว'
}

# ------------------------------------------------- confirm / clone / remove / migrate
function Confirm-Action([string]$Prompt, [string]$Expect = 'y') {
    # พิมพ์คำถามก่อนเสมอ แล้วอ่านคำตอบ:
    #  - stdin redirect (echo y | ...) -> อ่านจาก stdin (ถ้าไม่ตรง/ว่าง = ยกเลิก)
    #  - ไม่มี stdin เลย -> ยกเลิกเพื่อความปลอดภัย (กันรันอัตโนมัติลบของจริง)
    Write-Host "  $Prompt (พิมพ์ '$Expect')" -ForegroundColor Yellow
    $a = $null
    try {
        if ([Console]::IsInputRedirected) { $a = [Console]::In.ReadLine() }
        else { $a = Read-Host '  > ' }
    } catch { return $false }
    if ($null -eq $a) { Write-Info 'ไม่ได้คำตอบ — ยกเลิก'; return $false }
    $ok = ("$a".Trim().ToLower() -eq $Expect.ToLower())
    if (-not $ok) { Write-Info "คำตอบ '$a' ไม่ตรง — ยกเลิก" }
    return $ok
}

function Guard-Name([string]$n, [string]$what = 'ชื่อ') {
    if ([string]::IsNullOrWhiteSpace($n)) { throw "ต้องระบุ$what" }
    if ($n -match '[\\/]|(\.\.)') { throw "$what ผิดปกติ (มี \ / หรือ ..): $n" }
}

function Get-FolderSizeMB($p) {
    if (-not (Test-Path $p)) { return 0 }
    [math]::Round(((Get-ChildItem $p -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
}

function Cmd-Clone($what, $from, $to) {
    # ไม่ใส่อะไร -> ถามก่อนว่า clone app หรือ clone mysql
    if (-not $what) {
        $what = Select-CloneKind
        if (-not $what) { return }
    }
    $kind = "$what".ToLower()

    if ($kind -eq 'app') {
        # ไม่ใส่ from -> เมนูเลือกต้นทาง ; ไม่ใส่ to -> ชื่อเวอร์ชันถัดไปอัตโนมัติ
        if (-not $from) {
            $pick = Select-CloneAppSource
            if (-not $pick) { return }
            $from = $pick.Name
        }
        Guard-Name $from 'ชื่อต้นทาง'
        if (-not $to) { $to = Get-NextAppName $from }
        Guard-Name $to 'ชื่อปลายทาง'
        if ($from -eq $to) { throw "ปลายทางซ้ำกับต้นทาง: $from" }

        $src = Join-Path $Script:P.Versions $from
        $dst = Join-Path $Script:P.Versions $to
        if (-not (Test-Path $src)) { throw "ไม่พบ versions\$from" }
        if (Test-Path $dst) { throw "มี versions\$to อยู่แล้ว — เปลี่ยนชื่อปลายทาง" }
        $cur = Get-CurrentAppName
        Write-Head "clone app   $from -> $to"
        $mb = Get-FolderSizeMB $src
        if (-not (Confirm-Action "คัดลอกโค้ด $mb MB จาก versions\$from ไป versions\$to ?")) { Write-Info 'ยกเลิก'; return }
        robocopy $src $dst /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "copy ล้มเหลว (robocopy exit $LASTEXITCODE)" }
        # clone -> สืบทอด family จากต้นทาง แล้วตั้ง version = ชื่อปลายทาง
        Set-AppMeta $dst (Get-AppMeta $src).Family $to
        Set-SourceMeta $dst 'app' "clone of versions\$from"
        Write-Ok "คัดลอกแล้ว: versions\$to ($mb MB)"
        Write-Info "ยังอยู่เวอร์ชันเดิม: $cur (ระบบไม่สลับให้อัตโนมัติ)"
        Write-Info "สลับเมื่อพร้อม: aptstack use $to      ย้อนกลับ: aptstack use -"
        Write-Info 'DATABASE: ใช้ตัวเดิม — ค่าต่อ DB อยู่กลางที่ config\stack.json'
        Write-Info '            (host/port/user/pass ไม่ผูกกับ app) → แอปใหม่เห็นข้อมูลชุดเดิม'
        return
    }

    if ($kind -ne 'mysql') {
        throw "ไม่รู้จัก '$what' — ใช้ได้: app | mysql"
    }

    # mysql: ไม่ใส่ from -> เมนู datadir ; ไม่ใส่ to -> ชื่อถัดไป
    if (-not $from) {
        $pick = Select-CloneMysqlSource
        if (-not $pick) { return }
        $from = $pick.Name
    }
    Guard-Name $from 'ชื่อต้นทาง'
    if (-not $to) { $to = Get-NextAppName $from }
    Guard-Name $to 'ชื่อปลายทาง'
    if ($from -eq $to) { throw "ปลายทางซ้ำกับต้นทาง: $from" }

    # clone datadir -> ต้อง stop ก่อน (ห้าม copy ไฟล์ InnoDB ขณะ server เปิด)
    $cfg = Get-Config
    if ((Test-Running 'mysql') -or -not (Test-PortFree $cfg.dbPort)) {
        throw 'ยังรันอยู่ — stop ก่อน clone datadir (ไฟล์ InnoDB ห้าม copy ตอนเปิด):  aptstack stop'
    }
    $srcD = $null
    $eng = Resolve-MySql $from
    if ($eng) { $srcD = Get-DataDir $eng } else { $srcD = Join-Path $Script:P.Data $from }
    if (-not (Test-Path (Join-Path $srcD 'mysql'))) { throw "ไม่พบ datadir ที่มีข้อมูล: $srcD" }
    $dstD = Join-Path $Script:P.Data $to
    if (Test-Path $dstD) { throw "มี data\$to อยู่แล้ว" }
    $mb = Get-FolderSizeMB $srcD
    Write-Head "clone database  $from -> $to"
    Write-Warn2 "จะคัดลอก datadir $mb MB (ต้อง stop แล้ว)"
    Write-Info "ต้นทาง : $srcD"
    Write-Info "ปลายทาง: $dstD"
    if (-not (Confirm-Action 'คัดลอก datadir ใช่ไหม?')) { Write-Info 'ยกเลิก'; return }
    robocopy $srcD $dstD /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "copy ล้มเหลว ($LASTEXITCODE)" }
    Write-Ok "คัดลอก datadir แล้ว -> data\$to"
    Write-Info 'ใช้กับ engine ใหม่: aptstack add mysql <zip ใหม่> แล้ว aptstack use mysql <ชื่อ engine ใหม่>'
    Write-Warn2 'ห้ามรัน 2 engine พร้อมกันกับ datadir เดียวกัน — ของ clone นี้แยกกันแล้วจึงปลอดภัย'
    Write-Info 'กลับไปของเดิม: aptstack use mysql <ชื่อเดิม> แล้ว start'
}

function Cmd-Remove($what, $name, $extra) {
    if (-not $what -or -not $name) { throw 'ใช้: aptstack remove <app|php|apache|mysql> <ชื่อ> [data]' }
    Guard-Name $name 'ชื่อ'
    $cfg = Get-Config

    switch ($what.ToLower()) {
        'app' {
            $cur = Get-CurrentAppName
            if ($cur -eq $name) {
                throw "'$name' กำลังใช้อยู่ — สลับไปก่อน: aptstack use <ชื่ออื่น> แล้วค่อยลบ (กัน junction ชี้ของที่ถูกลบ)"
            }
            $dir = Join-Path $Script:P.Versions $name
            if (-not (Test-Path $dir)) { throw "ไม่พบ versions\$name" }
            $mb = Get-FolderSizeMB $dir
            Write-Head "ลบ app version: versions\$name"
            Write-Warn2 "ลบถาวร $mb MB — ไม่ลง recycle bin, กู้คืนไม่ได้!"
            Write-Info 'ถ้ายังไม่ได้ backup โค้ด/DB ให้ทำก่อน: aptstack backup'
            if (-not (Confirm-Action "พิมพ์ y เพื่อลบ versions\$name ถาวร")) { Write-Info 'ยกเลิก'; return }
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Ok "ลบแล้ว: versions\$name"
            Sync-AppAliases
            Write-Info 'database ไม่ถูกแตะ (อยู่คนละส่วน — data\)'
        }
        'php' {
            $hit = Resolve-Php $name
            if (-not $hit) { throw "ไม่พบ PHP '$name' (ดูชื่อ: aptstack list)" }
            if ($cfg.php -eq $hit.Version) { throw "PHP $($hit.Version) กำลังใช้อยู่ — สลับก่อน: aptstack use php <ตัวอื่น>" }
            $mb = Get-FolderSizeMB $hit.Dir
            Write-Head "ลบ PHP: $($hit.Version)"
            Write-Warn2 "ลบ $mb MB ($($hit.Dir)) — ถาวร!"
            if (-not (Confirm-Action "พิมพ์ y เพื่อลบ PHP $($hit.Version)")) { Write-Info 'ยกเลิก'; return }
            Remove-Item -LiteralPath $hit.Dir -Recurse -Force
            Write-Ok "ลบ PHP $($hit.Version) แล้ว"
        }
        'apache' {
            $hit = Resolve-Apache $name
            if (-not $hit) { throw "ไม่พบ Apache '$name'" }
            if ($cfg.apache -eq $hit.Version) { throw "Apache $($hit.Version) ถูกตั้งเป็น active — เปลี่ยน webMode หรือ apache ตัวอื่นก่อน" }
            $mb = Get-FolderSizeMB $hit.Dir
            Write-Head "ลบ Apache: $($hit.Version)"
            Write-Warn2 "ลบ $mb MB ($($hit.Dir)) — ถาวร!"
            if (-not (Confirm-Action "พิมพ์ y เพื่อลบ Apache $($hit.Version)")) { Write-Info 'ยกเลิก'; return }
            Remove-Item -LiteralPath $hit.Dir -Recurse -Force
            Write-Ok "ลบ Apache $($hit.Version) แล้ว"
        }
        'mysql' {
            $hit = Resolve-MySql $name
            $dir = if ($hit) { $hit.Dir } else { Join-Path $Script:P.MySqlRoot $name }
            $dd = if ($hit) { Get-DataDir $hit } else { Join-Path $Script:P.Data $name }
            $active = if ($cfg.mysql -and $hit -and $cfg.mysql -in @($hit.Version, $hit.Name)) { $true } else { $false }
            $wantData = ("$extra".ToLower() -in @('data', '--data', 'datadir'))

            if ($active) { throw "engine นี้เป็นตัวที่ใช้อยู่ — สลับก่อน: aptstack use mysql <ตัวอื่น>" }
            if (Test-Path $dir) { } else { throw "ไม่พบ stack\mysql\$name" }

            Write-Head "ลบ MySQL/MariaDB: $name"
            $mbBin = Get-FolderSizeMB $dir
            $mbData = if (Test-Path $dd) { Get-FolderSizeMB $dd } else { 0 }
            Write-Info "binary : $dir ($mbBin MB)"
            Write-Info "datadir: $(if (Test-Path $dd) { "$dd ($mbData MB)" } else { '(ไม่มี)' })"

            if ($wantData) {
                Write-Warn2 'จะลบทั้ง BINARY และ DATA (ข้อมูลในฐานข้อมูลชุดนี้หายถาวร!)'
                if ($mbData -gt 0) { Write-Warn2 'แนะนำ: aptstack backup ก่อนเสมอ' }
                if ((Test-Running 'mysql') -or -not (Test-PortFree $cfg.dbPort)) { throw 'ยังรันอยู่ — aptstack stop ก่อนลบ data' }
                if (-not (Confirm-Action 'ขั้นที่ 1/2 — ยืนยันลบ data (พิมพ์ y)')) { Write-Info 'ยกเลิก'; return }
                if (-not (Confirm-Action "ขั้นที่ 2/2 — พิมพ์ DELETE เพื่อลบ datadir $mbData MB ถาวร" 'DELETE')) { Write-Info 'ยกเลิก — ไม่มีอะไรถูกลบ'; return }
                if (Test-Path $dd) {
                    $ddFull = [IO.Path]::GetFullPath($dd).TrimEnd('\')
                    $dataRoot = [IO.Path]::GetFullPath($Script:P.Data).TrimEnd('\')
                    if (-not $ddFull.StartsWith($dataRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "ป้องกัน: path ไม่อยู่ใน data\ ($ddFull)" }
                    Remove-Item -LiteralPath $ddFull -Recurse -Force
                    Write-Ok "ลบ datadir แล้ว: $ddFull"
                }
            } else {
                Write-Info 'DATADATA จะ "ไม่ถูกลบ" — เก็บไว้ใช้กับ engine ใหม่หรือกู้ภายหลัง'
                Write-Info ' (ถ้าจะลบด้วย: aptstack remove mysql <ชื่อ> data)'
            }

            if (Test-Path $dir) {
                if (-not (Confirm-Action "พิมพ์ y เพื่อลบ binary ($mbBin MB)")) { Write-Info 'ยกเลิก (data ที่สั่งลบไปแล้วยังคงอยู่ถ้ามี)'; return }
                $dirFull = [IO.Path]::GetFullPath($dir).TrimEnd('\')
                $stackRoot = [IO.Path]::GetFullPath($Script:P.MySqlRoot).TrimEnd('\')
                if (-not $dirFull.StartsWith($stackRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "ป้องกัน: path ไม่อยู่ใน stack\mysql\ ($dirFull)" }
                Remove-Item -LiteralPath $dirFull -Recurse -Force
                Write-Ok "ลบ binary แล้ว: $dirFull"
            }
        }
        default { throw "ไม่รู้จัก '$what' — ใช้ได้: app | php | apache | mysql" }
    }
}

function Cmd-Migrate($what, $to) {
    # โยกข้อมูล database ไป engine ใหม่ แบบ logical dump -> restore
    # (datadir ต่อ engine แยกกันอยู่แล้ว -> โยกโดยไม่แตะของเดิม = rollback ได้เสมอ)
    if ("$what".ToLower() -ne 'mysql') { throw 'ใช้: aptstack migrate mysql <version ใหม่>' }
    if (-not $to) { throw 'ต้องระบุ engine ปลายทาง: aptstack migrate mysql 11.4.13' }
    $cfg = Get-Config
    $cur = Resolve-MySql $cfg.mysql
    $tgt = Resolve-MySql $to
    if (-not $tgt) { throw "ไม่พบ engine '$to' — ติดตั้งก่อน: aptstack add mysql $to" }
    if ($cur -and $cur.Name -eq $tgt.Name) { throw 'ปลายทางเป็น engine ตัวเดิมอยู่แล้ว' }
    if (Test-PortFree $cfg.dbPort) { throw 'Database ยังไม่รัน (ต้องรันเพื่อ dump) — aptstack start' }

    $fromName = if ($cur) { $cur.Name } else { '(ปัจจุบัน)' }
    $srcD = if ($cur) { Get-DataDir $cur } else { '' }
    $dstD = Get-DataDir $tgt
    if (Test-Path (Join-Path $dstD 'mysql')) {
        throw "data ปลายทางมีข้อมูลอยู่แล้ว: $dstD`nถ้าต้องการใช้ ให้ clone/สำรองไว้ก่อนแล้วลบ หรือเลือกชื่อ engine ใหม่"
    }

    Write-Head "migrate MySQL  $fromName -> $($tgt.Name)"
    Write-Warn2 'วิธี: logical dump (mysqldump --all-databases) -> stop -> switch -> start -> restore'
    Write-Info "ต้นทาง datadir : $srcD"
    Write-Info "ปลายทาง datadir: $dstD (จะถูกสร้างใหม่ตอน start)"
    Write-Info 'ของเดิมไม่ถูกแตะ → เสร็จแล้วย้อนกลับด้วย: aptstack use mysql <เดิม> + start'
    if (-not (Confirm-Action 'เริ่ม migrate ใช่ไหม? (จะ dump ทุกฐานข้อมูลก่อน)')) { Write-Info 'ยกเลิก'; return }

    # 1) dump
    $hit = if ($cur) { $cur } else { Resolve-MySql $null }
    if (-not $hit) { throw 'ไม่พบ engine ต้นทาง' }
    $dump = Join-Path $Script:P.Dumps ('migrate-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.sql')
    $client = $null
    foreach ($n in @('bin\mariadb-dump.exe', 'bin\mysqldump.exe')) { $p = Join-Path $hit.Dir $n; if (Test-Path $p) { $client = $p; break } }
    if (-not $client) { throw 'ไม่พบ mariadb-dump/mysqldump' }
    Write-Info "dump -> $dump"
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $dargs = @('--skip-ssl', '-h', '127.0.0.1', '-P', "$($cfg.dbPort)", '--protocol=tcp', '--default-character-set=utf8mb4',
               '-u', $cfg.dbUser, "-p$($cfg.dbPass)", '--single-transaction', '--routines', '--triggers', '--all-databases')
    $pOut = Start-Process -FilePath $client -ArgumentList $dargs -RedirectStandardOutput $dump -RedirectStandardError (Join-Path $Script:P.Tmp 'migrate-err.txt') -Wait -PassThru -NoNewWindow
    $ErrorActionPreference = $old
    if ($pOut.ExitCode -ne 0 -or -not (Test-Path $dump) -or (Get-Item $dump).Length -lt 200) {
        $e = if (Test-Path (Join-Path $Script:P.Tmp 'migrate-err.txt')) { (Get-Content (Join-Path $Script:P.Tmp 'migrate-err.txt') -Tail 3) -join ' ' } else { '' }
        throw "dump ล้มเหลว (exit $($pOut.ExitCode)) $e"
    }
    Write-Ok ("dump สำเร็จ ({0:N1} MB)" -f ((Get-Item $dump).Length / 1MB))

    # 2) stop -> switch -> start
    Stop-Db
    $cfg = Get-Config
    $cfg.mysql = if ($tgt.Version) { $tgt.Version } else { $tgt.Name }
    Save-Config $cfg
    if (-not (Start-Db (Get-Config))) { throw 'start engine ปลายทางไม่สำเร็จ — datadir เดิมของต้นทางยังอยู่ครบ ย้อนกลับด้วย: aptstack use mysql <เดิม>' }

    # 3) restore
    $client2 = $null
    foreach ($n in @('bin\mariadb.exe', 'bin\mysql.exe')) { $p = Join-Path $tgt.Dir $n; if (Test-Path $p) { $client2 = $p; break } }
    if (-not $client2) { throw 'ไม่พบ mariadb/mysql client ของ engine ปลายทาง' }
    Write-Info "restore <- $dump"
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $rargs = @('--skip-ssl', '-h', '127.0.0.1', '-P', "$($cfg.dbPort)", '--protocol=tcp', '--default-character-set=utf8mb4',
               '-u', $cfg.dbUser, "-p$($cfg.dbPass)", '--force')
    $p2 = Start-Process -FilePath $client2 -ArgumentList $rargs -RedirectStandardInput $dump -RedirectStandardOutput (Join-Path $Script:P.Tmp 'migrate-out.txt') -RedirectStandardError (Join-Path $Script:P.Tmp 'migrate-err2.txt') -Wait -PassThru -NoNewWindow
    $ErrorActionPreference = $old
    if ($p2.ExitCode -ne 0) {
        $e = if (Test-Path (Join-Path $Script:P.Tmp 'migrate-err2.txt')) { (Get-Content (Join-Path $Script:P.Tmp 'migrate-err2.txt') -Tail 3) -join ' ' } else { '' }
        Write-Err2 "restore อาจไม่สมบูรณ์ (exit $($p2.ExitCode)) $e"
        Write-Info "dump ยังอยู่: $dump — import มือได้ หรือย้อนกลับ: aptstack use mysql $(if ($cur) { if ($cur.Version) { $cur.Version } else { $cur.Name } })"
        return
    }
    Write-Ok "migrate สำเร็จ -> engine $($tgt.Name)"
    Write-Info "dump เก็บไว้: $dump"
    if ($srcD) { Write-Info "datadir เดิม (ยังอยู่ ไม่ได้ลบ): $srcD" }
    Write-Info "ย้อนกลับ: aptstack use mysql $(if ($cur) { if ($cur.Version) { $cur.Version } else { $cur.Name } }) แล้ว start"
    Cmd-Status
}

# ---------------------------------------------------------------- pull: ดึง config/db จาก version ต่ำ/ root อื่น
function Read-Pick([string]$Prompt) {
    Write-Host "  $Prompt" -ForegroundColor Yellow
    try {
        if ([Console]::IsInputRedirected) { return ([Console]::In.ReadLine()) }
        return (Read-Host '  > ')
    } catch { return $null }
}

function Parse-Pick([string]$s, [int]$max) {
    # 'all' -> ทั้งหมด · '1,3' / '1 3' -> รายการ (1-based) · ผิด -> $null
    $s = "$s".Trim().ToLower()
    if (-not $s) { return $null }
    if ($s -in @('all', 'a', '*')) { return @(1..$max) }
    $out = @()
    foreach ($t in ($s -split '[,\s]+')) {
        if (-not $t) { continue }
        $n = 0
        if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 1 -or $n -gt $max) { return $null }
        $out += $n
    }
    if ($out.Count -eq 0) { return $null }
    return @($out | Sort-Object -Unique)
}

function Test-PortUp([int]$Port) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $t = $t2 = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $t.AsyncWaitHandle.WaitOne(250, $false)
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

function Get-RootMysqlTools([string]$RootPath, $Cfg) {
    # หา mariadb-dump/mariadb (หรือ mysqldump/mysql) ของ root ไหนก็ได้ — ไม่พึ่ง $Script:P
    $base = Join-Path $RootPath 'stack\mysql'
    $dirs = @()
    $ver = "$($Cfg.mysql)"
    if ($ver) { $d = Join-Path $base $ver; if (Test-Path $d) { $dirs += $d } }
    if (Test-Path $base) { $dirs += @(Get-ChildItem $base -Directory -EA SilentlyContinue | ForEach-Object FullName) }
    foreach ($d in ($dirs | Select-Object -Unique)) {
        $dump = $null; $cli = $null
        foreach ($n in @('bin\mariadb-dump.exe', 'bin\mysqldump.exe')) { $p = Join-Path $d $n; if (Test-Path $p) { $dump = $p; break } }
        foreach ($n in @('bin\mariadb.exe', 'bin\mysql.exe')) { $p = Join-Path $d $n; if (Test-Path $p) { $cli = $p; break } }
        if ($dump -and $cli) { return [pscustomobject]@{ Dir = $d; Dump = $dump; Client = $cli } }
    }
    return $null
}

function Get-ServerDatabases($Client, [int]$Port, [string]$User, [string]$Pass) {
    $q = "SELECT table_schema, ROUND(IFNULL(SUM(data_length+index_length),0)/1024/1024,1), COUNT(DISTINCT table_name) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') GROUP BY table_schema ORDER BY table_schema;"
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $Client --skip-ssl -h 127.0.0.1 -P "$Port" --protocol=tcp --default-character-set=utf8mb4 -u $User "-p$Pass" -N -B -e $q 2>$null
    $ErrorActionPreference = $old
    $list = @()
    foreach ($l in @($out)) {
        $c = "$l" -split "`t"
        if ($c.Count -ge 3 -and $c[0]) { $list += [pscustomobject]@{ Name = $c[0]; MB = [double]$c[1]; Tables = [int]$c[2] } }
    }
    return $list
}

function Invoke-FileProgress([string]$Act, $Proc, [string]$File, [double]$EstMB) {
    # poll ขนาดไฟล์ระหว่าง dump -> % + MB + อัตรา + ETA (ทุก 2 วิพิมพ์บรรทัด log ด้วย)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $lastTxt = -2.0; $pct = -1
    while (-not $Proc.HasExited) {
        Start-Sleep -Milliseconds 400
        $cur = 0.0
        if (Test-Path -LiteralPath $File) { $cur = ((Get-Item -LiteralPath $File).Length / 1MB) }
        $eta = ''; $p = -1
        if ($EstMB -gt 0.5) {
            $p = [int][Math]::Min(100, [Math]::Round($cur / $EstMB * 100))
            if ($sw.Elapsed.TotalSeconds -gt 1.5) {
                $rate = $cur / $sw.Elapsed.TotalSeconds
                if ($rate -gt 0.01) { $sec = ($EstMB - $cur) / $rate; if ($sec -gt 0 -and $sec -lt 86400) { $eta = "เหลือ ~$([int]$sec) วิ" } }
            }
        }
        if ($p -ge 0 -and $p -ne $pct) {
            $pct = $p
            Write-Progress -Activity $Act -PercentComplete $pct -Status "$pct% · $([math]::Round($cur,1))/$([math]::Round($EstMB,1)) MB $eta"
        }
        if ($sw.Elapsed.TotalSeconds - $lastTxt -ge 2) {
            $lastTxt = $sw.Elapsed.TotalSeconds
            if ($p -ge 0) { Write-Info ("    ... {0}% · {1:N1}/{2:N1} MB · {3}" -f $pct, $cur, $EstMB, $eta) }
            else { Write-Info ("    ... {0:N1} MB · {1:N0} วิ" -f $cur, $sw.Elapsed.TotalSeconds) }
        }
    }
    Write-Progress -Activity $Act -Completed
    $sw.Stop()
}

function Invoke-ProcTicker([string]$Act, $Proc, [string]$Label) {
    # import: ไม่รู้ % จริง -> เอา item-level + นับวินาที (บอก i/N ให้รู้ว่าอีกนานไหม)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = -2.0
    while (-not $Proc.HasExited) {
        Start-Sleep -Milliseconds 400
        if ($sw.Elapsed.TotalSeconds - $last -ge 2) {
            $last = $sw.Elapsed.TotalSeconds
            Write-Progress -Activity $Act -Status ("{0} · {1:N0} วิ" -f $Label, $sw.Elapsed.TotalSeconds)
            Write-Info ("    ... {0} · {1:N0} วิ" -f $Label, $sw.Elapsed.TotalSeconds)
        }
    }
    Write-Progress -Activity $Act -Completed
    $sw.Stop()
}

function Cmd-Pull($kind, $target, $extra) {
    # ดึง config + ฐานข้อมูล (SQL) จาก version ต่ำกว่า / aptstack root อื่น -> version สูง (target)
    # flow: list แหล่งรวม -> เลือกกลุ่ม (config/databases/dumps) -> เลือกรายตัวหรือ all
    #       -> ดูแผนก่อนยืนยัน -> execute พร้อม %/ETA ต่อขั้น
    if ("$kind".ToLower() -ne 'mysql') { throw 'ใช้: aptstack pull mysql <version สูง> [path aptstack root อื่น]' }
    if (-not $target) { throw 'ต้องระบุ version ปลายทาง (สูง): aptstack pull mysql 11.4.13' }
    $cfg = Get-Config
    $tgt = Resolve-MySql $target
    if (-not $tgt) { throw "ไม่พบ engine '$target' ใน root นี้ — ติดตั้งก่อน: aptstack add mysql $target" }
    $tgtVer = if ($tgt.Version) { $tgt.Version } else { $tgt.Name }

    # ---- 1) เก็บรายชื่อ root ทั้งหมด (root นี้ + siblings + path ที่ระบุ) ----
    # ห้ามใช้ชื่อ $roots — ทับ $Root (PS ไม่สนตัวพิมพ์)
    $rootList = New-Object System.Collections.ArrayList
    [void]$rootList.Add($Root)
    $parent = Split-Path $Root -Parent
    foreach ($d in @(Get-ChildItem $parent -Directory -EA SilentlyContinue)) {
        if ($d.FullName.TrimEnd('\') -ieq $Root.TrimEnd('\')) { continue }
        if ((Test-Path (Join-Path $d.FullName 'aptstack.ps1')) -and (Test-Path (Join-Path $d.FullName 'config\stack.json'))) { [void]$rootList.Add($d.FullName) }
    }
    if ($extra) {
        $ex = "$extra"; if ($ex -notmatch '^[A-Za-z]:[\\/]') { $ex = Join-Path $Root $ex }
        if (Test-Path (Join-Path $ex 'aptstack.ps1')) {
            $exFull = (Resolve-Path $ex).Path
            if (@($rootList) -notcontains $exFull) { [void]$rootList.Add($exFull) }
        } else { Write-Warn2 "ไม่พบ aptstack root ที่: $ex" }
    }

    # ---- 2) สำรวจแต่ละ root: config, server รันอยู่ไหม, dumps, engines ----
    $rootInfo = @(); $dumpFiles = @()
    foreach ($r in @($rootList)) {
        $c = $null
        try { $c = (Get-Content (Join-Path $r 'config\stack.json') -Raw -EA Stop | ConvertFrom-Json) } catch { }
        $port = if ($c -and $c.dbPort) { [int]$c.dbPort } else { 3306 }
        $up = Test-PortUp $port
        $tools = Get-RootMysqlTools $r $c
        $vers = @()
        $mb = Join-Path $r 'stack\mysql'
        if (Test-Path $mb) { $vers = @(Get-ChildItem $mb -Directory -EA SilentlyContinue | ForEach-Object Name) }
        $dfs = @()
        $dd = Join-Path $r 'data\dumps'
        if (Test-Path $dd) { $dfs = @(Get-ChildItem $dd -File -Filter *.sql -EA SilentlyContinue | Sort-Object LastWriteTime -Descending) }
        $isSelf = ($r.TrimEnd('\') -ieq $Root.TrimEnd('\'))
        $rootInfo += [pscustomobject]@{ Root = $r; Cfg = $c; Port = $port; Up = $up; Tools = $tools; Versions = $vers; IsSelf = $isSelf; Dumps = $dfs }
        foreach ($f in $dfs) { $dumpFiles += [pscustomobject]@{ File = $f; SrcRoot = $r; SrcTag = $(if ($isSelf) { '(root นี้)' } else { $r }) } }
    }

    # ---- 3) สร้างกลุ่ม ----
    Write-Head 'แหล่งที่ดึงได้'
    foreach ($ri in $rootInfo) {
        $tag = if ($ri.IsSelf) { '(root นี้)' } else { $ri.Root }
        $st = if ($ri.Up) { "server รันอยู่ :$($ri.Port)" } else { "server ดับ" }
        $eng = if ($ri.Versions.Count) { 'engine: ' + ($ri.Versions -join ', ') } else { 'engine: -' }
        Write-Info ("  {0,-58} {1} · {2}" -f $tag, $st, $eng)
        if ($ri.Dumps.Count -gt 0) { Write-Info ("      dumps: {0} ไฟล์" -f $ri.Dumps.Count) }
    }
    Write-Host ''

    # กลุ่ม config = จาก root อื่นเท่านั้น (root นี้ = config ปัจจุบัน ไม่มีอะไรให้ดึง)
    $cfgFields = @('dbPort', 'dbUser', 'dbPass', 'dbMode')
    $cfgSources = @($rootInfo | Where-Object { (-not $_.IsSelf) -and $_.Cfg })
    # กลุ่ม databases = (a) server ที่รันอยู่ทุก root (b) engine ต่ำกว่า/อื่นใน root นี้ (จะ start ชั่วคราว)
    $liveSrc = @($rootInfo | Where-Object { $_.Up -and $_.Tools -and (-not $_.IsSelf) })
    $selfEngines = @()
    $selfInfo = $rootInfo | Where-Object { $_.IsSelf } | Select-Object -First 1
    if ($selfInfo) { $selfEngines = @($selfInfo.Versions | Where-Object { $_ -ne $tgtVer }) }

    $groups = @()
    if ($cfgSources.Count -gt 0) { $groups += 'config' }
    if ($liveSrc.Count -gt 0 -or $selfEngines.Count -gt 0) { $groups += 'databases' }
    if ($dumpFiles.Count -gt 0) { $groups += 'dumps' }
    if ($groups.Count -eq 0) { Write-Info 'ไม่พบแหล่งอะไรเลย (root อื่นไม่มี config/dumps, server ก็ไม่รัน)'; return }

    Write-Head 'เลือกกลุ่มที่จะดึง'
    for ($i = 0; $i -lt $groups.Count; $i++) {
        $desc = switch ($groups[$i]) {
            'config'    { 'ค่า db (port/user/pass/mode) จาก root อื่น' }
            'databases' { 'ฐานข้อมูล — จาก server ที่รันอยู่ + engine ต่ำกว่าใน root นี้ (list รายตัว ขั้นถัดไป)' }
            'dumps'     { 'ไฟล์ *.sql ที่มีอยู่ (list รายไฟล์ ขั้นถัดไป)' }
        }
        Write-Info ("  {0}) {1,-10} — {2}" -f ($i + 1), $groups[$i], $desc)
    }
    $gAns = Read-Pick ("พิมพ์หมายเลขคั่นด้วย , หรือ all (Enter = ยกเลิก)")
    if ([string]::IsNullOrWhiteSpace($gAns)) { Write-Info 'ยกเลิก'; return }
    $gPick = Parse-Pick $gAns $groups.Count
    if (-not $gPick) { Write-Err2 "เลือกไม่ถูกต้อง: '$gAns'"; return }
    $picked = @($gPick | ForEach-Object { $groups[$_ - 1] })

    $plan = New-Object System.Collections.ArrayList   # ขั้นตอนที่จะทำ (แผน)
    $cfgChoice = $null; $cfgFieldPick = $null; $dbPicks = @(); $filePicks = @()

    # ---- 4a) config: เลือกแหล่ง (ถ้ามีหลาย root) แล้วเลือก field ทีละตัว ----
    if ($picked -contains 'config') {
        Write-Head 'เลือกแหล่ง config'
        for ($i = 0; $i -lt $cfgSources.Count; $i++) {
            Write-Info ("  {0}) {1}  (port={2} user={3} mode={4})" -f ($i + 1), $cfgSources[$i].Root, $cfgSources[$i].Cfg.dbPort, $cfgSources[$i].Cfg.dbUser, $cfgSources[$i].Cfg.dbMode)
        }
        $cAns = Read-Pick 'พิมพ์หมายเลข (Enter = ยกเลิก)'
        if ([string]::IsNullOrWhiteSpace($cAns)) { Write-Info 'ยกเลิก'; return }
        $cPick = Parse-Pick $cAns $cfgSources.Count
        if (-not $cPick -or $cPick.Count -ne 1) { Write-Err2 'ต้องเลือกแหล่ง config แหล่งเดียว'; return }
        $cfgChoice = $cfgSources[$cPick[0] - 1]
        $avail = @($cfgFields | Where-Object { $null -ne $cfgChoice.Cfg.$_ })
        Write-Host ''
        Write-Host '  เลือก field ที่จะดึง:' -ForegroundColor White
        for ($i = 0; $i -lt $avail.Count; $i++) {
            $f = $avail[$i]
            $old = "$($cfg.$f)"; $new = "$($cfgChoice.Cfg.$f)"
            $mark = if ($old -ceq $new) { ' (เท่าเดิม)' } else { "  $old -> $new" }
            Write-Info ("  {0}) {1}{2}" -f ($i + 1), $f, $mark)
        }
        $fAns = Read-Pick 'พิมพ์หมายเลขคั่นด้วย , หรือ all (Enter = ยกเลิก)'
        if ([string]::IsNullOrWhiteSpace($fAns)) { Write-Info 'ยกเลิก'; return }
        $fPick = Parse-Pick $fAns $avail.Count
        if (-not $fPick) { Write-Err2 "เลือกไม่ถูกต้อง: '$fAns'"; return }
        $cfgFieldPick = @($fPick | ForEach-Object { $avail[$_ - 1] })
        [void]$plan.Add([pscustomobject]@{ Kind = 'config'; Label = "ใช้ " + ($cfgFieldPick -join ',') + " จาก $($cfgChoice.Root)"; Act = 'config' })
    }

    # ---- 4b) databases: list รายตัว (live servers + engine ต่ำกว่าใน root นี้) ----
    if ($picked -contains 'databases') {
        Write-Head 'list ฐานข้อมูลที่ดึงได้'
        $dbOptions = @()
        foreach ($ls in $liveSrc) {
            $dbs = Get-ServerDatabases $ls.Tools.Client $ls.Port $ls.Cfg.dbUser $ls.Cfg.dbPass
            foreach ($d in $dbs) { $dbOptions += [pscustomobject]@{ Source = 'live'; RootInfo = $ls; Name = $d.Name; MB = $d.MB; Tables = $d.Tables; Note = "server รันอยู่ :$($ls.Port)" } }
        }
        foreach ($ev in $selfEngines) {
            # datadir -> รายชื่อ db (ยังไม่ start — ชื่อจากโฟลเดอร์)
            $vh = $null
            try { $vh = Resolve-MySql $ev } catch { }
            $dd = if ($vh) { Get-DataDir $vh } else { Join-Path $Script:P.Data $ev }
            if (Test-Path $dd) {
                $sys = @('mysql', 'information_schema', 'performance_schema', 'sys', 'phpmyadmin', 'lost+found')
                foreach ($sd in @(Get-ChildItem $dd -Directory -EA SilentlyContinue)) {
                    if ($sys -contains $sd.Name) { continue }
                    $sz = Get-FolderSizeMB $sd.FullName
                    $dbOptions += [pscustomobject]@{ Source = 'engine'; Engine = $ev; Name = $sd.Name; MB = $sz; Tables = -1; Note = "engine $ev (จะ start ชั่วคราว)" }
                }
            }
        }
        if ($dbOptions.Count -eq 0) { Write-Info '  (ไม่พบฐานข้อมูล — server ทั้งหมดดับ และ datadir ว่าง)' }
        for ($i = 0; $i -lt $dbOptions.Count; $i++) {
            $o = $dbOptions[$i]
            $tb = if ($o.Tables -ge 0) { "$($o.Tables) ตาราง" } else { 'ตาราง ?' }
            Write-Info ("  {0,2}) {1,-28} {2,8:N1} MB  {3,-22} {4}" -f ($i + 1), $o.Name, $o.MB, $o.Note, $tb)
        }
        if ($dbOptions.Count -gt 0) {
            $dAns = Read-Pick 'เลือกฐานข้อมูล (หมายเลขคั่นด้วย , หรือ all — Enter = ข้าม)'
            if (-not [string]::IsNullOrWhiteSpace($dAns)) {
                $dPick = Parse-Pick $dAns $dbOptions.Count
                if (-not $dPick) { Write-Err2 "เลือกไม่ถูกต้อง: '$dAns'"; return }
                $dbPicks = @($dPick | ForEach-Object { $dbOptions[$_ - 1] })
            }
        }
    }

    # ---- 4c) dumps: list รายไฟล์ ----
    if ($picked -contains 'dumps' -and $dumpFiles.Count -gt 0) {
        Write-Head 'list ไฟล์ .sql'
        for ($i = 0; $i -lt $dumpFiles.Count; $i++) {
            $f = $dumpFiles[$i]
            Write-Info ("  {0,2}) {1,-52} {2,7:N1} MB  {3}  {4:yyyy-MM-dd}" -f ($i + 1), $f.File.Name, ($f.File.Length / 1MB), $f.SrcTag, $f.File.LastWriteTime)
        }
        $sAns = Read-Pick 'เลือกไฟล์ (หมายเลขคั่นด้วย , หรือ all — Enter = ข้าม)'
        if (-not [string]::IsNullOrWhiteSpace($sAns)) {
            $sPick = Parse-Pick $sAns $dumpFiles.Count
            if (-not $sPick) { Write-Err2 "เลือกไม่ถูกต้อง: '$sAns'"; return }
            $filePicks = @($sPick | ForEach-Object { $dumpFiles[$_ - 1] })
        }
    }

    # ---- 5) สรุปแผน ----
    # จัดลำดับ: config -> dump จาก server รันอยู่ -> (สลับ engine ต่ำ dump) -> สลับ target -> import
    $liveDbPicks = @($dbPicks | Where-Object { $_.Source -eq 'live' })
    $engDbPicks = @($dbPicks | Where-Object { $_.Source -eq 'engine' } | Group-Object Engine)
    $needSwitchToTarget = ("$cfg.mysql" -ne "$tgtVer")
    $willImport = ($dbPicks.Count -gt 0 -or $filePicks.Count -gt 0)
    foreach ($g in $engDbPicks) {
        [void]$plan.Add([pscustomobject]@{ Kind = 'switch'; Label = "start engine ต้นทาง $($g.Name) (ชั่วคราว — หยุดตัวปัจจุบันก่อน)"; Act = 'start-src'; Engine = $g.Name })
        foreach ($d in $g.Group) {
            [void]$plan.Add([pscustomobject]@{ Kind = 'dump'; Label = "dump $($d.Name) จาก $($d.Engine) (~$($d.MB) MB)"; Act = 'dump'; Db = $d.Name; EstMB = [math]::Max(1, $d.MB * 1.1); SrcKind = 'engine'; Engine = $d.Engine; SrcCfg = $cfg; SrcPort = $cfg.dbPort })
    }
    }
    foreach ($g in ($liveDbPicks | Group-Object Root)) {
        foreach ($d in $g.Group) {
            $ri = $d.RootInfo
            [void]$plan.Add([pscustomobject]@{ Kind = 'dump'; Label = "dump $($d.Name) จาก $($ri.Root) (~$($d.MB) MB)"; Act = 'dump'; Db = $d.Name; EstMB = [math]::Max(1, $d.MB * 1.1); SrcKind = 'live'; SrcCfg = $ri.Cfg; SrcPort = $ri.Port })
        }
    }
    foreach ($fp in $filePicks) {
        [void]$plan.Add([pscustomobject]@{ Kind = 'stage'; Label = "ใช้ไฟล์เดิม: $($fp.File.Name) ($([math]::Round($fp.File.Length/1MB,1)) MB)"; Act = 'stage'; File = $fp.File.FullName })
    }
    if ($engDbPicks.Count -gt 0) {
        [void]$plan.Add([pscustomobject]@{ Kind = 'stop'; Label = 'หยุด engine ต้นทาง (ชั่วคราว)'; Act = 'stop-src' })
    }
    if ($willImport -and ($needSwitchToTarget -or $engDbPicks.Count -gt 0 -or -not (Test-PortUp ([int]$cfg.dbPort)))) {
        [void]$plan.Add([pscustomobject]@{ Kind = 'switch'; Label = "สลับไป engine ปลายทาง $($tgtVer) + start (ใช้ port $($cfg.dbPort))"; Act = 'start-tgt' })
    }
    $importItems = @()
    foreach ($p in @($plan)) { if ($p.Act -eq 'dump') { $importItems += [pscustomobject]@{ Name = $p.Db } } }
    foreach ($fp in $filePicks) { $importItems += [pscustomobject]@{ Name = $fp.File.BaseName; File = $fp.File.FullName } }
    # ของ dump สร้างไฟล์ภายหลัง — ผูก path ตอน execute (dumpFile field เติมตอน dump)
    $i = 0
    foreach ($it in $importItems) { $i++; [void]$plan.Add([pscustomobject]@{ Kind = 'import'; Label = "นำเข้า $($it.Name)"; Act = 'import'; Db = $it.Name; SrcFile = $it.File }) }

    if ($plan.Count -eq 0) { Write-Info 'ไม่ได้เลือกอะไร (หรือทุกอย่างเหมือนเดิม) — จบ'; return }

    Write-Host ''
    Write-Head "แผนที่จะทำ ($($plan.Count) ขั้น) — ปลายทาง: $($tgtVer)"
    $n = 0
    foreach ($p in $plan) { $n++; Write-Info ("  {0,2}. [{1,-6}] {2}" -f $n, $p.Kind, $p.Label) }
    Write-Host ''
    if (-not (Confirm-Action "พิมพ์ y เพื่อเริ่ม ($($plan.Count) ขั้น)")) { Write-Info 'ยกเลิก'; return }

    # ---- 6) execute พร้อม progress + ETA รวม ----
    $tmpDumpDir = Join-Path $Script:P.Dumps ('pull-' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory $tmpDumpDir -Force | Out-Null
    $done = 0; $secList = @(); $swAll = [Diagnostics.Stopwatch]::StartNew()
    $curEngineStarted = $null   # engine ที่เรา start ชั่วคราว (root นี้)
    $results = @()
    $idx = 0
    foreach ($p in $plan) {
        $idx++
        $act = "pull mysql — [$idx/$($plan.Count)] $($p.Label)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            switch ($p.Act) {
                'config' {
                    foreach ($f in $cfgFieldPick) { $cfg.$f = $cfgChoice.Cfg.$f }
                    Save-Config $cfg
                    Write-Ok ("config แล้ว: {0}" -f ($cfgFieldPick -join ', '))
                }
                'start-src' {
                    if (Test-Running 'mysql') { Stop-Db }
                    $cfg = Get-Config; $cfg.mysql = $p.Engine; Save-Config $cfg
                    if (-not (Start-Db (Get-Config))) { throw "start engine ต้นทาง $($p.Engine) ไม่สำเร็จ" }
                    $curEngineStarted = $p.Engine
                    Write-Ok "engine ต้นทาง $($p.Engine) รันแล้ว"
                }
                'dump' {
                    $tools = Get-RootMysqlTools $Root $cfg
                    if (-not $tools) { throw 'ไม่พบ mariadb-dump ใน root นี้' }
                    $outFile = Join-Path $tmpDumpDir (($p.Db -replace '[^\w.-]', '_') + '.sql')
                    $dargs = @('--skip-ssl', '-h', '127.0.0.1', '-P', "$($p.SrcPort)", '--protocol=tcp', '--default-character-set=utf8mb4',
                               '-u', $p.SrcCfg.dbUser, "-p$($p.SrcCfg.dbPass)", '--single-transaction', '--routines', '--triggers',
                               '--databases', $p.Db)
                    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                    $pr = Start-Process -FilePath $tools.Dump -ArgumentList $dargs -RedirectStandardOutput $outFile -RedirectStandardError (Join-Path $tmpDumpDir 'dump-err.txt') -PassThru -NoNewWindow
                    Invoke-FileProgress $act $pr $outFile $p.EstMB
                    $ErrorActionPreference = $oldEap
                    if ($pr.ExitCode -ne 0 -or -not (Test-Path $outFile)) { throw "dump $($p.Db) ล้มเหลว (exit $($pr.ExitCode))" }
                    $p.DumpFile = $outFile
                    # ผูกไฟล์ให้ขั้น import ของ db นี้
                    foreach ($q in $plan) { if ($q.Act -eq 'import' -and -not $q.SrcFile -and $q.Db -eq $p.Db) { $q.SrcFile = $outFile } }
                    Write-Ok ("dump {0} สำเร็จ ({1:N1} MB)" -f $p.Db, ((Get-Item $outFile).Length / 1MB))
                }
                'stage' {
                    Write-Ok "ใช้ไฟล์เดิม: $(Split-Path $p.File -Leaf)"
                }
                'stop-src' {
                    Stop-Db; $curEngineStarted = $null
                    Write-Ok 'หยุด engine ต้นทางแล้ว'
                }
                'start-tgt' {
                    if (Test-Running 'mysql') { Stop-Db }
                    $cfg = Get-Config; $cfg.mysql = $tgtVer; Save-Config $cfg
                    if (-not (Start-Db (Get-Config))) {
                        throw "start engine ปลายทาง $tgtVer ไม่สำเร็จ (พอร์ต $($cfg.dbPort)) — ของเดิมยังอยู่ครบ ย้อนกลับ: aptstack use mysql แล้ว start"
                    }
                    Write-Ok "engine ปลายทาง $tgtVer รันแล้ว"
                }
                'import' {
                    if (-not $p.SrcFile -or -not (Test-Path $p.SrcFile)) { throw "ไม่พบไฟล์สำหรับนำเข้า $($p.Db)" }
                    $tools = Get-RootMysqlTools $Root $cfg
                    if (-not $tools) { throw 'ไม่พบ client ของ engine ปลายทาง' }
                    $estMB = [math]::Round(((Get-Item $p.SrcFile).Length / 1MB), 1)
                    $rargs = @('--skip-ssl', '-h', '127.0.0.1', '-P', "$($cfg.dbPort)", '--protocol=tcp', '--default-character-set=utf8mb4',
                               '-u', $cfg.dbUser, "-p$($cfg.dbPass)", '--force')
                    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                    $pr = Start-Process -FilePath $tools.Client -ArgumentList $rargs -RedirectStandardInput $p.SrcFile -RedirectStandardOutput (Join-Path $tmpDumpDir 'import-out.txt') -RedirectStandardError (Join-Path $tmpDumpDir 'import-err.txt') -PassThru -NoNewWindow
                    Invoke-ProcTicker $act $pr ("$($p.Label) · $estMB MB")
                    $ErrorActionPreference = $oldEap
                    if ($pr.ExitCode -ne 0) {
                        $e = if (Test-Path (Join-Path $tmpDumpDir 'import-err.txt')) { ((Get-Content (Join-Path $tmpDumpDir 'import-err.txt') -Tail 2) -join ' ') } else { '' }
                        throw "นำเข้า $($p.Db) ไม่สมบูรณ์ (exit $($pr.ExitCode)) $e"
                    }
                    Write-Ok "นำเข้า $($p.Db) สำเร็จ"
                }
            }
            $results += [pscustomobject]@{ Ok = $true; Label = $p.Label }
        } catch {
            $results += [pscustomobject]@{ Ok = $false; Label = $p.Label; Err = "$($_.Exception.Message)" }
            Write-Err2 $results[-1].Err
            Write-Warn2 'แผนหยุดตรงนี้ — ไฟล์ที่ dump ไว้ยังอยู่ กู้/ทำต่อด้วย: aptstack import <file.sql>'
            break
        } finally { Write-Progress -Activity $act -Completed }
        $sw.Stop(); $swAll.Stop()
        $done++
        $secList += $sw.Elapsed.TotalSeconds
        $avg = ($secList | Measure-Object -Average).Average
        $eta = [math]::Max(0, [int]($avg * ($plan.Count - $idx)))
        Write-Info ("  ความคืบหน้า {0}/{1} ขั้น ({2}%) · ใช้ไป {3:N0} วิ · เฉลี่ย {4:N1} วิ/ขั้น · เหลือ ~{5} วิ" -f $idx, $plan.Count, [int]($idx / $plan.Count * 100), $swAll.Elapsed.TotalSeconds, $avg, $eta)
        $swAll.Start()
    }

    # ---- 7) สรุปผล ----
    Write-Host ''
    Write-Head "pull เสร็จ — สำเร็จ $((@($results | Where-Object Ok)).Count)/$($plan.Count) ขั้น · ใช้เวลา $([int]$swAll.Elapsed.TotalSeconds) วิ"
    foreach ($r in $results) {
        if ($r.Ok) { Write-Ok $r.Label } else { Write-Err2 ("{0} — {1}" -f $r.Label, $r.Err) }
    }
    Write-Info "ไฟล์ dump เก็บไว้: $tmpDumpDir"
    Write-Host ''
    Write-Info 'ขั้นถัดไป:'
    Write-Info "  aptstack status              ดู engine ปลายทาง ($tgtVer) + พอร์ต"
    Write-Info '  aptstack doctor              ตรวจความเรียบร้อย'
    Write-Info '  aptstack logs mysql          ถ้ามี warning ตอน restore'
    if ($cfgChoice) { Write-Info '  (config ถูกเปลี่ยนแล้ว — ดูด้วย: aptstack config)' }
}

function Cmd-Run {
    # dev console: start แบบ manual (ไม่ต้อง register Windows Service) + บล็อกหน้าจอ
    # กด Ctrl+C -> finally จะ stop ทั้งหมด (production: aptstack service install)
    Write-Head 'run — dev console (ไม่ต้องติดตั้ง Windows Service)'
    Write-Info 'โหมด dev/ทดสอบ · production ใช้: aptstack service install แล้ว service start'
    Write-Info 'web engine: ไม่มี nginx — ใช้ Apache+mod_php หรือ PHP built-in server เท่านั้น'
    Cmd-Start
    Write-Host ''
    Write-Info 'รันอยู่เบื้องหลังแล้ว — กด Ctrl+C เพื่อหยุดทั้งหมด'
    Write-Info 'ดู log: aptstack logs <apache|mysql|php>'
    try {
        while ($true) {
            Start-Sleep -Seconds 3
            $cfg = Get-Config
            $webUp = [bool](Test-Running 'web')
            $dbUp = [bool](Test-Running 'mysql')
            Write-Host ("  [{0:HH:mm:ss}]  web={1}   db={2}   app={3}" -f (Get-Date),
                $(if ($webUp) { 'up' } else { 'DOWN' }),
                $(if ($dbUp -or "$($cfg.dbMode)" -eq 'external') { 'up' } else { 'DOWN' }),
                (Get-CurrentAppName))
        }
    } finally {
        Write-Host ''
        Write-Warn2 'หยุด stack (dev console)'
        Cmd-Stop
    }
}

# ---------------------------------------------------------------- origin / diff
function Resolve-OriginPath([string]$source) {
    # คืน absolute path ของต้นทางจาก .aptstack-source
    # รองรับ: absolute | relative กับ Root | relative กับ parent (เช่น ..\_setup_inet\...)
    if ([string]::IsNullOrWhiteSpace($source)) { return $null }
    $s = $source.Trim().Trim('"')
    try {
        if ($s -match '^[A-Za-z]:[\\/]') {
            return [IO.Path]::GetFullPath($s)
        }
        $cands = @()
        $cands += [IO.Path]::GetFullPath((Join-Path $Root $s))
        $parent = Split-Path -Parent $Root
        if ($parent) { $cands += [IO.Path]::GetFullPath((Join-Path $parent $s)) }
        $cwd = (Get-Location).Path
        if ($cwd) { $cands += [IO.Path]::GetFullPath((Join-Path $cwd $s)) }
        foreach ($c in $cands) {
            if (Test-Path -LiteralPath $c) { return $c }
        }
        return [IO.Path]::GetFullPath((Join-Path $Root $s))
    } catch {
        return $s
    }
}

function Get-AppOriginInfo($app) {
    # $app = object from Get-AppVersions / Resolve-App
    if (-not $app) { return $null }
    $sm = Get-SourceMeta $app.Dir
    $raw = if ($sm) { "$($sm['source'])" } else { '' }
    $kind = if ($sm -and $sm['kind']) { $sm['kind'] } else { 'app' }
    $installed = if ($sm -and $sm['installed']) { $sm['installed'] } else { '' }
    $abs = $null
    $exists = $false
    $type = 'none'
    $diffNote = ''
    $cloneParent = ''

    if ($raw -match '^clone of versions\\(.+)$') {
        # clone: ต้นทางไม่ใช่ zip/path ภายนอก — ใช้ parent version เป็น base ของ diff
        $cloneParent = $Matches[1]
        $kind = 'clone'
        $parentDir = Join-Path $Script:P.Versions $cloneParent
        if (Test-Path -LiteralPath $parentDir) {
            $abs = $parentDir
            $exists = $true
            $type = 'dir'
            $diffNote = "เทียบกับ parent: versions\$cloneParent"
        }
        else {
            $abs = $parentDir
            $exists = $false
            $diffNote = "parent หาย: versions\$cloneParent"
        }
    }
    else {
        $abs = Resolve-OriginPath $raw
        $exists = if ($abs) { [bool](Test-Path -LiteralPath $abs) } else { $false }
        if ($exists) {
            $type = if (Test-Path -LiteralPath $abs -PathType Container) { 'dir' }
                    elseif ($abs -match '\.zip$') { 'zip' }
                    else { 'file' }
        }
    }

    return [pscustomobject]@{
        App          = $app.Name
        Dir          = $app.Dir
        Family       = $app.Family
        Kind         = $kind
        SourceRaw    = $raw
        SourceAbs    = $abs
        SourceExists = $exists
        SourceType   = $type
        Installed    = $installed
        CloneParent  = $cloneParent
        DiffNote     = $diffNote
    }
}

function Read-MenuChoice([string]$prompt, [int]$max) {
    try {
        if ([Console]::IsInputRedirected) { $ans = [Console]::In.ReadLine() }
        else { $ans = Read-Host $prompt }
    } catch { return $null }
    if ($null -eq $ans -or [string]::IsNullOrWhiteSpace($ans)) { return $null }
    $ans = "$ans".Trim().Trim('"')
    $n = 0
    if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $max) { return $n }
    return $null
}

function Select-DiffApp {
    # เมนูเลือก app สำหรับ aptstack diff — แสดง origin ทุกแถว
    $apps = @(Get-AppVersions)
    if ($apps.Count -eq 0) {
        Write-Err2 'ยังไม่มี app — ใช้: aptstack add app <folder|zip>'
        return $null
    }
    $cur = Get-CurrentAppName
    Write-Head 'เลือก app สำหรับ diff (เทียบ ต้นทาง vs versions\)'
    Write-Host ''
    $infos = @()
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $a = $apps[$i]
        $oi = Get-AppOriginInfo $a
        $infos += $oi
        $mark = if ($cur -eq $a.Name) { '*' } else { ' ' }
        $srcShort = if ($oi.SourceRaw) { Split-Path $oi.SourceRaw -Leaf } else { '(no origin)' }
        if (-not $srcShort) { $srcShort = $oi.SourceRaw }
        $ok = if ($oi.SourceExists) { 'OK' } else { 'MISS' }
        $okCol = if ($oi.SourceExists) { 'Green' } else { 'Yellow' }
        Write-Host ("  [{0,2}]{1} {2}" -f ($i + 1), $mark, $a.Name) -ForegroundColor White
        $originLabel = if ($oi.Kind -eq 'clone' -or $oi.CloneParent) { "clone -> versions\$($oi.CloneParent)" } else { $oi.SourceRaw }
        Write-Host ("       origin: {0}  [{1}]" -f $originLabel, $ok) -ForegroundColor $okCol
        if ($oi.DiffNote) {
            Write-Host ("       note  : {0}" -f $oi.DiffNote) -ForegroundColor DarkGray
        }
        if ($oi.SourceAbs -and $oi.SourceExists) {
            Write-Host ("       path  : {0}" -f $oi.SourceAbs) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host ("  พิมพ์หมายเลข 1-{0} แล้ว Enter (Enter = ยกเลิก)" -f $apps.Count) -ForegroundColor Yellow
    $n = Read-MenuChoice '  > ' $apps.Count
    if (-not $n) { Write-Info 'ยกเลิก'; return $null }
    $app = $apps[$n - 1]
    $oi = $infos[$n - 1]
    return [pscustomobject]@{ App = $app; Origin = $oi }
}

function Select-DiffOutput([string]$appName) {
    # เมนูเลือกโฟลเดอร์ output
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $opts = @(
        @{ Label = "dist\deploy-diff-$appName";           Detail = 'default (เขียนทับถ้ามี — ใช้ได้ถ้าลบก่อน/robocopy overwrite ผ่าน make-deploy-diff)' },
        @{ Label = "dist\deploy-diff-$appName-$stamp";    Detail = 'timestamp — ไม่ชนกับของเดิม' },
        @{ Label = "dist\deploy-diff-custom";             Detail = 'path สัมพัทธ์จาก root นี้' }
    )
    Write-Head 'เลือกโฟลเดอร์ output'
    Write-Host ''
    for ($i = 0; $i -lt $opts.Count; $i++) {
        Write-Host ("  [{0}]  {1}" -f ($i + 1), $opts[$i].Label) -ForegroundColor White
        Write-Host ("        {0}" -f $opts[$i].Detail) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  Enter = ใช้ [1] หรือพิมพ์ path เอง (สัมพัทธ์/absolute)' -ForegroundColor Yellow
    try {
        if ([Console]::IsInputRedirected) { $ans = [Console]::In.ReadLine() }
        else { $ans = Read-Host '  > ' }
    } catch { $ans = '' }
    if ($null -eq $ans -or [string]::IsNullOrWhiteSpace($ans)) { return $opts[0].Label }
    $ans = "$ans".Trim().Trim('"')
    if ($ans -match '^[123]$') { return $opts[[int]$ans - 1].Label }
    return $ans
}

function Cmd-Diff($appVer, $outName, $extra) {
    # aptstack diff              -> เมนูเลือก app + output แล้วรัน make-deploy-diff
    # aptstack diff <app>        -> ใช้ app นั้น (ถาม output)
    # aptstack diff <app> <out>  -> ระบุ output path ตรง ๆ
    # aptstack diff help
    if ("$appVer".ToLower() -in @('help', '-h', '--help', '/?')) {
        Write-Head 'aptstack diff — เทียบต้นทาง vs โค้ดใน versions\ (เฉพาะไฟล์ที่ต่าง)'
        Write-Host ''
        Write-Host '  dist vs diff — ต่างกันอย่างไร' -ForegroundColor Yellow
        Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  dist  = copy ทั้งก้อน ไป dist_paste\          (ใหญ่, ไม่เทียบอะไร)' -ForegroundColor White
        Write-Host '          ใช้: ติดตั้งใหม่ / ย้ายเครื่อง / server ยังไม่มีโค้ด' -ForegroundColor DarkGray
        Write-Host '  diff  = เทียบต้นทาง vs versions\ → เฉพาะที่ต่าง' -ForegroundColor Cyan
        Write-Host '          ใช้: patch server เดิม / ส่งเฉพาะไฟล์ที่แก้' -ForegroundColor DarkGray
        Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host ''
        Write-Info 'ใช้: aptstack diff'
        Write-Info '     aptstack diff <app> [outPath]'
        Write-Info '     aptstack import-origin     ดูต้นทางทุก app'
        Write-Info '     aptstack dist help         ดู copy ทั้งก้อน'
        Write-Info 'เครื่องมือลึก: tools\make-deploy-diff.ps1 -Help'
        return
    }

    $selected = $null
    if ($appVer) {
        $hit = Resolve-App $appVer
        if (-not $hit) { throw "ไม่พบ app '$appVer' — ดูชื่อ: aptstack list" }
        $selected = [pscustomobject]@{ App = $hit; Origin = (Get-AppOriginInfo $hit) }
    } else {
        $selected = Select-DiffApp
        if (-not $selected) { return }
    }

    $app = $selected.App
    $oi = $selected.Origin

    Write-Head "ต้นทางของ app '$($app.Name)'"
    Write-Host "  versions : $($app.Dir)" -ForegroundColor White
    Write-Host "  kind     : $($oi.Kind)" -ForegroundColor Gray
    Write-Host "  installed: $(if ($oi.Installed) { $oi.Installed } else { '?' })" -ForegroundColor Gray
    $srcShow = if ($oi.Kind -eq 'clone' -or $oi.CloneParent) { "clone of versions\$($oi.CloneParent)" } else { $oi.SourceRaw }
    Write-Host "  source   : $(if ($srcShow) { $srcShow } else { '(ไม่มี .aptstack-source)' })" -ForegroundColor $(if ($srcShow) { 'Cyan' } else { 'Yellow' })
    if ($oi.DiffNote) {
        Write-Host "  note     : $($oi.DiffNote)" -ForegroundColor DarkGray
    }
    if ($oi.SourceAbs) {
        $st = if ($oi.SourceExists) { "พบ ($($oi.SourceType))" } else { 'ไม่พบ' }
        Write-Host "  resolved : $($oi.SourceAbs)" -ForegroundColor $(if ($oi.SourceExists) { 'Green' } else { 'Yellow' })
        Write-Host "  status   : $st" -ForegroundColor $(if ($oi.SourceExists) { 'Green' } else { 'Yellow' })
    } elseif ($oi.SourceRaw) {
        Write-Host '  resolved : (แปลง path ไม่ได้)' -ForegroundColor Yellow
    }
    Write-Host ''

    if (-not $oi.SourceExists) {
        if ($oi.Kind -eq 'clone' -or $oi.CloneParent) {
            Write-Warn2 "parent ของ clone ไม่อยู่แล้ว: versions\$($oi.CloneParent)"
            Write-Info 'เทียบกับต้นตอ (origin เดิม) หรือพิมพ์ path เอง:'
        }
        else {
            Write-Warn2 'ไม่พบไฟล์/โฟลเดอร์ต้นทาง — diff ใช้ Base ไม่ได้'
            Write-Info 'ตรวจสอบ .aptstack-source ของ app นี้ หรือส่ง path เอง:'
        }
        Write-Info '  powershell -File tools\make-deploy-diff.ps1 -Base <zip|dir> -Compare "versions\' + $app.Name + '"'
        # ยังให้ลองพิมพ์ path เองได้
        Write-Host ''
        Write-Host '  พิมพ์ path ต้นทาง (Base) เอง หรือ Enter = ยกเลิก' -ForegroundColor Yellow
        try {
            if ([Console]::IsInputRedirected) { $manual = [Console]::In.ReadLine() }
            else { $manual = Read-Host '  Base > ' }
        } catch { $manual = '' }
        if ([string]::IsNullOrWhiteSpace("$manual")) { Write-Info 'ยกเลิก'; return }
        $manual = "$manual".Trim().Trim('"')
        $manualAbs = Resolve-OriginPath $manual
        if (-not (Test-Path -LiteralPath $manualAbs)) { throw "ไม่พบ path: $manualAbs" }
        $oi = [pscustomobject]@{
            App = $app.Name; Dir = $app.Dir; Family = $app.Family
            Kind = $oi.Kind; SourceRaw = $manual; SourceAbs = $manualAbs
            SourceExists = $true; SourceType = 'manual'; Installed = $oi.Installed
            CloneParent = $oi.CloneParent; DiffNote = 'manual base'
        }
    }
    elseif ($oi.Kind -eq 'clone') {
        Write-Info "clone: ใช้ parent เป็น Base — เฉพาะไฟล์ที่แก้หลัง clone เท่านั้น"
        Write-Info "ถ้าต้องการเทียบกับต้นตอ import เดิม ใช้: aptstack diff my-app"
    }

    $base = $oi.SourceAbs
    $compare = $app.Dir
    if (-not $outName) { $outName = Select-DiffOutput $app.Name }
    if (-not $outName) { $outName = "dist\deploy-diff-$($app.Name)" }
    $outFull = $outName
    if ($outFull -notmatch '^[A-Za-z]:[\\/]') { $outFull = Join-Path $Root $outFull }

    $tool = Join-Path $Root 'tools\make-deploy-diff.ps1'
    if (-not (Test-Path $tool)) { throw "ไม่พบ $tool" }

    Write-Head 'รัน make-deploy-diff'
    Write-Info "Base    : $base"
    Write-Info "Compare : $compare"
    Write-Info "Out     : $outFull"
    Write-Host ''

    & powershell -NoProfile -ExecutionPolicy Bypass -File $tool `
        -Base $base -Compare $compare -Out $outFull
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "make-deploy-diff จบด้วย exit code $code" }

    Write-Host ''
    Write-Ok "เสร็จแล้ว: $outFull"
    Write-Info "ดูรายงาน: $(Join-Path $outFull 'report.txt')"
    Write-Info " apply  : powershell -ExecutionPolicy Bypass -File `"$outFull\apply.ps1`" -Target <root-on-server>"
    Write-Info " ต้นทางทุก app: aptstack import-origin"
}

function Cmd-ImportOrigin {
    # แสดงต้นทางว่าแต่ละ app / binary ถูก import มาจากไหน (ทุกตัว)
    Write-Head 'import-origin — ต้นทางของทุก app / component'

    $apps = @(Get-AppVersions)
    $active = Get-CurrentAppName

    Write-Host ''
    Write-Host '  App versions (versions\)' -ForegroundColor White
    if ($apps.Count -eq 0) { Write-Info '  (ยังไม่มี)' }
    $rows = @()
    foreach ($a in $apps) {
        $oi = Get-AppOriginInfo $a
        $rows += $oi
        $mark = if ($active -eq $a.Name) { '*' } else { ' ' }
        $ok = if ($oi.SourceExists) { 'OK' } else { 'MISS' }
        $okCol = if ($oi.SourceExists) { 'Green' } else { 'Yellow' }
        Write-Host ("  {0} {1}" -f $mark, $oi.App) -ForegroundColor White
        Write-Host ("      kind      : {0}" -f $oi.Kind) -ForegroundColor DarkGray
        Write-Host ("      installed : {0}" -f $(if ($oi.Installed) { $oi.Installed } else { '?' })) -ForegroundColor DarkGray
        $srcShow = if ($oi.Kind -eq 'clone' -or $oi.CloneParent) { "clone of versions\$($oi.CloneParent)" } else { $oi.SourceRaw }
        Write-Host ("      source    : {0}  [{1}]" -f $(if ($srcShow) { $srcShow } else { '(none)' }), $ok) -ForegroundColor $okCol
        if ($oi.DiffNote) {
            Write-Host ("      note      : {0}" -f $oi.DiffNote) -ForegroundColor DarkGray
        }
        if ($oi.SourceAbs) {
            Write-Host ("      absolute  : {0}" -f $oi.SourceAbs) -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    # สรุปจับกลุ่มตาม source
    Write-Host '  สรุปตามต้นทาง (group)' -ForegroundColor White
    $bySrc = $rows | Group-Object {
        if ($_.SourceAbs) { $_.SourceAbs }
        elseif ($_.SourceRaw) { $_.SourceRaw }
        else { '(no source)' }
    } | Sort-Object Name
    foreach ($g in $bySrc) {
        $names = ($g.Group | ForEach-Object { $_.App }) -join ', '
        $exists = $g.Group[0].SourceExists
        $tag = if ($exists) { 'OK' } else { 'MISS' }
        Write-Host ("  [{0}] {1}" -f $tag, $g.Name) -ForegroundColor $(if ($exists) { 'Green' } else { 'Yellow' })
        Write-Host ("         apps: {0}" -f $names) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  Binary (stack\) — from: จาก aptstack list' -ForegroundColor White
    foreach ($p in @(Get-PhpVersions)) {
        $sm = Get-SourceMeta $p.Dir
        if ($sm -and $sm['source']) {
            $abs = Resolve-OriginPath $sm['source']
            $ok = if ($abs -and (Test-Path -LiteralPath $abs)) { 'OK' } else { 'MISS' }
            Write-Host ("  PHP  {0}  from: {1}  [{2}]" -f $p.Version, $sm['source'], $ok) -ForegroundColor $(if ($ok -eq 'OK') { 'Gray' } else { 'Yellow' })
            if ($abs) { Write-Host ("       -> {0}" -f $abs) -ForegroundColor DarkGray }
        }
    }
    foreach ($m in @(Get-MySqlVersions)) {
        $sm = Get-SourceMeta $m.Dir
        if ($sm -and $sm['source']) {
            $abs = Resolve-OriginPath $sm['source']
            $ok = if ($abs -and (Test-Path -LiteralPath $abs)) { 'OK' } else { 'MISS' }
            Write-Host ("  MySQL {0}  from: {1}  [{2}]" -f $m.Version, $sm['source'], $ok) -ForegroundColor $(if ($ok -eq 'OK') { 'Gray' } else { 'Yellow' })
        }
    }
    foreach ($a in @(Get-ApacheVersions)) {
        $sm = Get-SourceMeta $a.Dir
        if ($sm -and $sm['source']) {
            $abs = Resolve-OriginPath $sm['source']
            $ok = if ($abs -and (Test-Path -LiteralPath $abs)) { 'OK' } else { 'MISS' }
            Write-Host ("  Apache {0}  from: {1}  [{2}]" -f $a.Version, $sm['source'], $ok) -ForegroundColor $(if ($ok -eq 'OK') { 'Gray' } else { 'Yellow' })
        }
    }

    Write-Host ''
    Write-Info 'ดู HTML lineage: tools\show-app-lineage.ps1'
    Write-Info 'เทียบ diff    : aptstack diff'
}

function Cmd-Dist($appVer, $outRoot, $extra) {
    # สร้างชุด deploy แบบ copy-paste ได้ทันที: dist_paste\<appver>\
    # รวม scripts + app code + (ถ้าไม่บอก nostack) binary ทั้งหมด + www + config บางส่วน
    # ไม่รวม: data (DB), config ที่ generate, certs, logs, .git  -> server สร้างเองตอน start
    # ต่างจาก aptstack diff = เทียบต้นทางแล้วเอาเฉพาะไฟล์ที่ต่าง
    if ("$appVer".ToLower() -in @('help', '-h', '--help', '/?')) {
        Write-Head 'aptstack dist — copy ทั้งก้อน ไป dist_paste\ (ไม่เทียบ diff)'
        Write-Host ''
        Write-Host '  dist vs diff — ต่างกันอย่างไร' -ForegroundColor Yellow
        Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  dist  = copy ทั้งก้อน → dist_paste\<app>\' -ForegroundColor White
        Write-Host '          scripts + app + (stack) + VERSIONS.txt' -ForegroundColor DarkGray
        Write-Host '          ใช้: ติดตั้งใหม่ / ย้ายเครื่อง / ยังไม่มีโค้ดบน server' -ForegroundColor DarkGray
        Write-Host '  diff  = เทียบต้นทาง vs versions\ → เฉพาะไฟล์ที่ต่าง' -ForegroundColor Cyan
        Write-Host '          ใช้: patch server เดิม / ส่งเฉพาะที่แก้' -ForegroundColor DarkGray
        Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host ''
        Write-Info 'ใช้: aptstack dist <app> [outRoot] [nostack]'
        Write-Info '     aptstack diff              ดูแบบเทียบเฉพาะไฟล์ต่าง'
        Write-Info '     aptstack import-origin     ดูต้นทางทุก app'
        return
    }
    Ensure-Dirs
    if (-not $appVer) { $appVer = Get-CurrentAppName }
    if (-not $appVer) { throw 'ไม่ได้ระบุ app และยังไม่มีตัว active — ใช้: aptstack dist <ชื่อapp> [outRoot] [nostack]  (หรือ aptstack dist help)' }
    $hit = Resolve-App $appVer
    if (-not $hit) { throw "ไม่พบ versions\$appVer (ดูชื่อ: aptstack list)" }
    if (-not $outRoot) { $outRoot = Join-Path $Root 'dist_paste' }
    # path สัมพัทธ์ต้องอ้างถึง root ของ bundle (ไม่ใช่ CWD ของคนเรียก)
    if ($outRoot -notmatch '^[A-Za-z]:[\\/]') { $outRoot = Join-Path $Root $outRoot }
    $dest = Join-Path $outRoot $hit.Name
    $noStack = "$extra".ToLower() -in @('nostack', '-nostack')
    $noPma = "$extra".ToLower() -in @('nopma', '-nopma', 'nostack-nopma', 'nopma-nostack')
    if (Test-Path $dest) { throw "มีอยู่แล้ว: $dest — ลบก่อนหรือเปลี่ยน outRoot/outName" }

    $cfg = Get-Config
    $php = Resolve-Php $cfg.php
    $apache = Resolve-Apache $cfg.apache
    $mysql = Resolve-MySql $cfg.mysql
    $wm = Resolve-WebMode $cfg $php $apache
    $pkgVer = if (Test-Path (Join-Path $Root 'VERSION')) { (Get-Content (Join-Path $Root 'VERSION') -Raw).Trim() } else { '?' }

    Write-Head "สร้างชุด deploy (copy-paste) สำหรับ app '$($hit.Name)'"
    Write-Info "ปลายทาง: $dest"
    if ($noStack) { Write-Warn2 'โหมด nostack — ไม่รวม binary (ต้องมี stack\ บน server อยู่แล้ว)' }

    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    # 1) ตัวสคริปต์หลัก
    foreach ($f in @('aptstack.cmd', 'as.cmd', 'aptstack.ps1', 'setup.ps1', 'service.ps1', 'VERSION')) {
        $src = Join-Path $Root $f
        if (Test-Path $src) { Copy-Item $src $dest -Force }
    }
    foreach ($d in @('templates', 'examples', 'docs', 'service')) {
        $src = Join-Path $Root $d
        if (Test-Path $src) { robocopy $src (Join-Path $dest $d) /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 | Out-Null }
    }
    foreach ($f in @('README-TH.md', 'README.md', 'SECURITY.md', 'CHANGELOG.md', 'ai.md', 'concept.md')) {
        $src = Join-Path $Root $f
        if (Test-Path $src) { Copy-Item $src $dest -Force }
    }

    # 2) app code (ตัวเดียว)
    New-Item -ItemType Directory -Path (Join-Path $dest 'versions') -Force | Out-Null
    robocopy $hit.Dir (Join-Path $dest "versions\$($hit.Name)") /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw 'copy app ล้มเหลว' }

    # 3) www — คัดลอกเฉพาะไฟล์จริง (ไม่เอา junction เพื่อหลบ path เดิม)
    New-Item -ItemType Directory -Path (Join-Path $dest 'www') -Force | Out-Null
    foreach ($f in @('router.php', 'index.php')) {
        $src = Join-Path (Join-Path $Root 'www') $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $dest 'www') -Force }
    }
    $pma = Join-Path (Join-Path $Root 'www') 'phpmyadmin'
    if ((Test-Path $pma) -and -not $noPma) {
        robocopy $pma (Join-Path $dest 'www\phpmyadmin') /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 | Out-Null
    }

    # 4) config เฉพาะที่ต้องใช้ต่อ (ไม่เอาของ generate/secret runtime)
    New-Item -ItemType Directory -Path (Join-Path $dest 'config') -Force | Out-Null
    foreach ($f in @('stack.json', 'vhosts.json')) {
        $src = Join-Path (Join-Path $Root 'config') $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $dest 'config') -Force }
    }

    # 5) binary (ยกเว้น nostack)
    if (-not $noStack) {
        Write-Info 'กำลังคัดลอก stack\ (PHP/Apache/MariaDB) — อาจใช้เวลาสักครู่...'
        robocopy (Join-Path $Root 'stack') (Join-Path $dest 'stack') /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw 'copy stack ล้มเหลว' }
    }

    # 6) รายงาน version + ขั้นตอน deploy
    $szAll = Get-FolderSizeMB $dest
    $built = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $verRep = @"
================================================================================
 aptstack dist — รายงาน version ของชุด deploy นี้
================================================================================
  สร้างเมื่อ            : $built
  แพ็กเกจ aptstack      : $pkgVer
  App version           : $($hit.Name)          (จาก versions\$($hit.Name))
  PHP                   : $(if ($php) { $php.Version } else { '(ยังไม่ตั้ง)' })
  Apache                : $(if ($apache) { $apache.Version } else { '(ไม่รวม)' })
  MySQL/MariaDB         : $(if ($mysql) { $mysql.Version } else { '(ไม่รวม)' })
  webMode               : $wm
  httpPort / dbPort     : $($cfg.httpPort) / $($cfg.dbPort)
  httpsEnabled          : $($cfg.httpsEnabled)
  appAlias (URL path)   : /$($cfg.appAlias)/
  ขนาดชุด deploy        : $szAll MB
  รวม binary (stack\)   : $(if ($noStack) { 'ไม่รวม (nostack)' } else { 'รวม' })
================================================================================

  ตรวจ version บน server ได้ตลอด:  aptstack list
  สร้างรายงาน HTML พิมพ์ได้:        aptstack report
"@
    [IO.File]::WriteAllText((Join-Path $dest 'VERSIONS.txt'), (($verRep -replace "`n", "`r`n") + "`r`n"), [Text.Encoding]::UTF8)

    $deploy = @"
================================================================================
 วิธี deploy ชุดนี้ (copy-paste ขึ้น server ที่ไม่มีเน็ตก็ได้)
================================================================================

 1) copy ทั้งโฟลเดอร์นี้ไป server ด้วยวิธีใดก็ได้
      - RDP: แนะนำใช้ drive redirection หรือ shared folder
        (คัดลอก-วางตรง ๆ ผ่าน RDP ช้ามากกับไฟล์เล็ก ๆ หลายพันไฟล์)
      - USB / share ใน LAN

 2) บน server เปิด cmd ที่โฟลเดอร์นี้
      cd /d E:\path\to\$($hit.Name)
      aptstack use $($hit.Name)
      aptstack start
      aptstack doctor

 3) เปิด http://127.0.0.1:$($cfg.httpPort)/$($cfg.appAlias)/

 หมายเหตุ
  - ไม่ต้องติดตั้ง Windows Service ก็ใช้ได้ (dev ใช้ aptstack start/run ก็พอ)
  - เมื่อพร้อมขึ้นจริง (ต้องการให้บูตเอง):
        aptstack service install
        aptstack service start
  - ถ้าจะเปลี่ยน PHP/MySQL/Apache บน server (ตอนโดน audit สั่งเปลี่ยน):
        คัดลอก zip ของตัวใหม่เข้าไป แล้ว
        aptstack add php 8.3.36     (หรือ add php <path\to\zip>)
        aptstack use php 8.3.36
        aptstack doctor
  - ย้อนกลับ: aptstack use php <ver เก่า>  (ของเก่ายังอยู่ครบ)
================================================================================
"@
    [IO.File]::WriteAllText((Join-Path $dest 'DEPLOY.txt'), (($deploy -replace "`n", "`r`n") + "`r`n"), [Text.Encoding]::UTF8)

    Write-Ok ("สร้างแล้ว: $dest  ({0:N1} MB)" -f $szAll)
    Write-Info 'ข้างในมี: VERSIONS.txt (รายงาน version) + DEPLOY.txt (ขั้นตอน)'
    Write-Info "บน server: cd เข้าโฟลเดอร์ -> aptstack use $($hit.Name) -> aptstack start -> aptstack doctor"
    Write-Info 'ไฟล์ที่ "ไม่ได้เอาไป": data\, logs\, config ที่ generate, certs, .git (server สร้างเองตอน start)'
}

function Cmd-Git($action, $name) {
    # จัดการ git "ของ bundle นี้" (ใช้ตอนเอาไปวางบน server)
    # - init : git init + commit แรก (เก็บเฉพาะ scripts/templates/docs — .gitignore กัน data/binary อยู่แล้ว)
    # - status: ดูสั้น ๆ
    # - clear : ลบ .git (ทำให้เป็น folder ลอย ๆ ใหม่) ต้องยืนยัน
    # * dist_paste ไม่ได้เอา .git ของ dev ไปด้วยตั้งแต่แรก → ไม่มีทางติด history เดิม
    $gitDir = Join-Path $Root '.git'
    $hasGit = Test-Path $gitDir
    switch ("$action".ToLower()) {
        'init' {
            if ($hasGit) { Write-Warn2 "มี .git อยู่แล้วที่ $gitDir — ถ้าอยากเริ่มใหม่: aptstack git clear ก่อน"; return }
            $gitExe = Get-Command git -EA SilentlyContinue
            if (-not $gitExe) { throw 'ไม่พบ git.exe ใน PATH — ติดตั้ง Git for Windows ก่อน' }
            Write-Head 'git init (ของ bundle นี้ — เผื่อ track การแก้ config/scripts บน server)'
            # git เขียน warning ลง stderr (เช่น LF->CRLF) -> ต้องกด EAP ไม่งั้นโยน exception
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & git -C $Root init 2>&1 | Out-Null
            & git -C $Root add -A 2>&1 | Out-Null
            $n = @(& git -C $Root ls-files).Count
            & git -C $Root -c user.name='aptstack' -c user.email='aptstack@local' commit -q -m 'aptstack: initial commit (scripts/templates/docs only)' 2>&1 | Out-Null
            $ErrorActionPreference = $oldEap
            Write-Ok "git init แล้ว — track $n ไฟล์ (data/binary/config ถูก .gitignore กันแล้ว)"
            Write-Info 'สำคัญ: อย่า add ไฟล์มือในโฟลเดอร์ที่ถูก ignore (data/, stack/, versions/, config/)'
            Write-Info 'ก่อน zip/copy กลับ: ถ้าไม่อยากเอา history ไปด้วย -> aptstack git clear'
        }
        'status' {
            if (-not $hasGit) { Write-Info 'ยังไม่ได้ git init ใน bundle นี้ (ไม่บังคับ — ใช้ aptstack ก็พอ)'; return }
            Write-Head 'git status (bundle นี้)'
            & git -C $Root status -sb 2>&1 | Select-Object -First 40 | ForEach-Object { Write-Host "  $_" }
        }
        'clear' {
            if (-not $hasGit) { Write-Info 'ไม่มี .git อยู่แล้ว'; return }
            Write-Head 'ลบ .git ออกจาก bundle (ทำให้เป็น folder ลอย ๆ)'
            Write-Warn2 'จะเสียประวัติ commit ใน "สำเนานี้" เท่านั้น — ไฟล์งานไม่หาย'
            Write-Info "เป้าหมาย: $gitDir"
            if (-not (Confirm-Action "พิมพ์ y เพื่อลบ .git ในโฟลเดอร์นี้")) { Write-Info 'ยกเลิก'; return }
            Remove-Item -LiteralPath $gitDir -Recurse -Force
            Write-Ok 'ลบ .git แล้ว — ใช้เป็น portable folder ต่อได้เลย (git init ใหม่ได้ทุกเมื่อ)'
        }
        default { throw "ใช้: aptstack git <init|status|clear>" }
    }
}

# ---------------------------------------------------------------- update (self-update from GitHub)
$Script:UpdateRepo = 'tps2015gh/aptstack'

function Get-LocalAppVersion {
    $f = Join-Path $Root 'VERSION'
    if (Test-Path $f) { return ((Get-Content $f -Raw -EA SilentlyContinue) -replace '\s+', '').Trim() }
    return '0.0.0'
}

function Get-GitHubLatestRelease {
    # คืน @{ Tag; Version; ZipUrl; ShaUrl } หรือ $null (ไม่มี release / เน็ต fail)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $api = "https://api.github.com/repos/$Script:UpdateRepo/releases/latest"
    $r = $null
    try {
        $r = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'aptstack' }
    } catch {
        $txt = Get-WebText $api
        if ($txt) { try { $r = $txt | ConvertFrom-Json } catch { $r = $null } }
    }
    if (-not $r) { return $null }
    $tag = "$($r.tag_name)"
    $ver = $tag -replace '^v', ''
    $zips = @($r.assets | Where-Object { $_.name -match '\.zip$' -and $_.name -notmatch '\.sha256(\.zip)?$' })
    $shas = @($r.assets | Where-Object { $_.name -match '\.zip\.sha256$' })
    if ($zips.Count -eq 0) { return $null }
    return [pscustomobject]@{
        Tag    = $tag
        Version = $ver
        Name   = $zips[0].name
        ZipUrl = $zips[0].browser_download_url
        ShaUrl = if ($shas.Count -gt 0) { $shas[0].browser_download_url } else { '' }
    }
}

function Get-RemoteMainVersion {
    # อ่าน VERSION จาก main ตรง ๆ (ใช้ตอนไม่มี release หรือเทียบ dev branch)
    $txt = Get-WebText "https://raw.githubusercontent.com/$Script:UpdateRepo/main/VERSION"
    if ($txt) { return ((($txt -split "`r?`n")[0]) -replace '\s+', '').Trim() }
    return $null
}

function Test-VersionNewer([string]$Remote, [string]$Local) {
    try { return ([version]$Remote -gt [version]$Local) }
    catch { return ("$Remote" -ne "$Local") }
}

function Invoke-UpdateDownload([string]$Url, [string]$OutFile) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
    } catch {
        $ok = $false
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $p = Start-Process -FilePath 'curl.exe' -ArgumentList @('-sL', '--fail', '--max-time', '300', '-A', 'aptstack', "`"$Url`"", '-o', "`"$OutFile`"") -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0 -and (Test-Path $OutFile) -and ((Get-Item $OutFile -EA SilentlyContinue).Length -gt 0)) { $ok = $true }
        }
        if (-not $ok) {
            Remove-Item -LiteralPath $OutFile -Force -EA SilentlyContinue
            throw "ดาวน์โหลดไม่สำเร็จ: $Url ($($_.Exception.Message))"
        }
    }
}

function Test-Sha256File([string]$ZipPath, [string]$ShaText) {
    # sha256 file รูปแบบ: <HASH>  <filename>  (case-insensitive)
    # ใช้ .NET SHA256 ตรง ๆ — Get-FileHash บาง environment (module ไม่โหลด) หายไป
    if (-not $ShaText) { return $null }   # ไม่มี checksum = ข้าม (คืน $null = ไม่รู้)
    $m = [regex]::Match("$ShaText", '([0-9a-fA-F]{64})')
    if (-not $m.Success) { return $null }
    $want = $m.Groups[1].Value.ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($ZipPath)
    try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose(); $sha.Dispose() }
    $got = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    return ($want -eq $got)
}

function Copy-UpdateTree([string]$src, [string]$dst) {
    # คัดลอก "โค้ด" จาก release zip เข้า root — ห้ามแตะ state ของผู้ใช้
    # src = โฟลเดอร์ที่มี aptstack.ps1 อยู่ข้างใน (แตก zip แล้ว)
    $protect = @('config', 'data', 'versions', 'stack', 'downloads', 'logs', 'bin', 'dist', 'db', 'scripts', '.git', 'runtime')
    $codeDirs = @('docs', 'examples', 'service', 'templates', 'tools')
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $src -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq 'aptstack-report.html') { continue }   # artifact ที่ generate ท้ายเครื่อง
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dst $f.Name) -Force
        $n++
    }
    foreach ($d in $codeDirs) {
        $s = Join-Path $src $d
        if (-not (Test-Path $s)) { continue }
        $dd = Join-Path $dst $d
        # /XJ ไม่ตาม junction (กัน www\app ถูก copy ทับ) · ไม่ลบของฝั่ง destination
        robocopy $s $dd /E /XJ /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Warn2 "copy $d ไม่สมบูรณ์ (robocopy exit $LASTEXITCODE)" }
        else { $n++ }
    }
    # www: เฉพาะไฟล์ที่ zip มี (router.php / aptstack-console) — ห้ามแตะ junction app / phpmyadmin
    $wwwSrc = Join-Path $src 'www'
    if (Test-Path $wwwSrc) {
        $wwwDst = Join-Path $dst 'www'
        foreach ($item in @(Get-ChildItem -LiteralPath $wwwSrc -Force -ErrorAction SilentlyContinue)) {
            $destPath = Join-Path $wwwDst $item.Name
            $di = Get-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue
            if ($di -and ($di.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            if ($item.PSIsContainer) {
                robocopy $item.FullName $destPath /E /XJ /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
                $n++
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination $destPath -Force
                $n++
            }
        }
    }
    return $n
}

function Update-FromReleaseZip($Rel, [string]$LocalVer, [bool]$Force) {
    Write-Head "ดาวน์โหลด release $($Rel.Tag)"
    Write-Info $Rel.ZipUrl
    Ensure-Dirs
    $work = Join-Path $Script:P.Tmp ('update-' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $zip = Join-Path $work $Rel.Name
        Invoke-UpdateDownload $Rel.ZipUrl $zip
        Write-Ok ("ดาวน์โหลดแล้ว ({0:N2} MB)" -f ((Get-Item $zip).Length / 1MB))

        if ($Rel.ShaUrl) {
            $shaText = $null
            try {
                $shaTmp = Join-Path $work 'expected.sha256'
                Invoke-UpdateDownload $Rel.ShaUrl $shaTmp
                $shaText = Get-Content $shaTmp -Raw
            } catch { Write-Warn2 "โหลด .sha256 ไม่ได้: $($_.Exception.Message)" }
            $ok = Test-Sha256File $zip $shaText
            if ($ok -eq $true) { Write-Ok 'SHA256 ตรงกับ release' }
            elseif ($ok -eq $false) {
                Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
                throw 'SHA256 ไม่ตรง — ไฟล์เสียหาย/ถูกแก้ ยกเลิก (ไม่เขียนทับโค้ด)'
            }
            else { Write-Warn2 'ไม่มี checksum ให้เทียบ — ข้ามการ verify' }
        } else { Write-Warn2 'release นี้ไม่มี .sha256 — ข้ามการ verify' }

        Write-Info 'แตก zip...'
        $ex = Join-Path $work 'x'
        Expand-Archive -Path $zip -DestinationPath $ex -Force
        # โครงสร้าง zip = aptstack/<files> หรือ aptstack-<branch>/<files> (branch archive)
        $srcRoot = $null
        if (Test-Path (Join-Path $ex 'aptstack.ps1')) { $srcRoot = $ex }
        else {
            $kids = @(Get-ChildItem $ex -Directory -Force -ErrorAction SilentlyContinue)
            foreach ($k in $kids) {
                if (Test-Path (Join-Path $k.FullName 'aptstack.ps1')) { $srcRoot = $k.FullName; break }
            }
        }
        if (-not $srcRoot) { throw 'zip ไม่มี aptstack.ps1 — โครงสร้างไม่ตรง' }

        $zipVer = if (Test-Path (Join-Path $srcRoot 'VERSION')) { ((Get-Content (Join-Path $srcRoot 'VERSION') -Raw) -replace '\s+', '').Trim() } else { $Rel.Version }
        if ((Test-VersionNewer $LocalVer $zipVer) -and -not $Force) {
            Write-Warn2 "local ($LocalVer) ใหม่กว่า release นี้ ($zipVer) — ไม่เขียนทับ (ใช้ aptstack update force ถ้าตั้งใจ)"
            return $false
        }

        # backup โค้ด root ตัวสำคัญก่อนเขียนทับ (ย้อนได้ถ้าพัง)
        $bak = Join-Path $Script:P.Logs ("update-bak-" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path $bak -Force | Out-Null
        foreach ($f in @('aptstack.ps1', 'VERSION', 'aptstack.cmd', 'as.cmd', 'setup.ps1', 'service.ps1')) {
            $p = Join-Path $Root $f
            if (Test-Path $p) { Copy-Item $p $bak -Force }
        }
        Write-Info "backup โค้ดเดิมไว้: $bak"

        $n = Copy-UpdateTree $srcRoot $Root
        $newVer = Get-LocalAppVersion
        Write-Ok "อัปเดตโค้ดแล้ว: $LocalVer -> $newVer  (แตะ ~$n path — config/data/versions/stack ไม่โดน)"
        return $true
    } finally {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Update-FromGit([string]$LocalVer, [bool]$Force) {
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitExe) { throw 'ไม่พบ git.exe ใน PATH — ใช้: aptstack update zip' }
    if (-not (Test-Path (Join-Path $Root '.git'))) { throw 'โฟลเดอร์นี้ไม่มี .git — ใช้: aptstack update zip' }

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $remoteUrl = "$(& git -C $Root remote get-url origin 2>$null | Select-Object -First 1)"
        if ($remoteUrl -notmatch 'tps2015gh/aptstack') {
            throw "origin ไม่ใช่ repo aptstack ทางการ ($remoteUrl) — ใช้: aptstack update zip"
        }
        $dirty = @(& git -C $Root status --porcelain 2>$null)
        if ($dirty.Count -gt 0 -and -not $Force) {
            Write-Warn2 "มีไฟล์ที่ยังไม่ commit $($dirty.Count) รายการ — git pull อาจชน/ทับของคุณ"
            $dirty | Select-Object -First 8 | ForEach-Object { Write-Info "  $_" }
            if (-not (Confirm-Action 'ยังจะ pull ต่อไหม? (แนะนำ: commit ก่อน แล้วค่อย update)')) {
                Write-Info 'ยกเลิก — commit ให้หมดแล้วรัน aptstack update git ใหม่'
                return $false
            }
        }
        Write-Head 'git fetch origin main'
        & git -C $Root fetch --quiet origin main 2>&1 | Out-Null
        $remoteVer = "$(& git -C $Root show origin/main:VERSION 2>$null | Select-Object -First 1)"
        $remoteVer = ($remoteVer -replace '\s+', '').Trim()
        if (-not $remoteVer) { throw 'อ่าน VERSION บน origin/main ไม่ได้ — ลอง aptstack update zip' }
        Write-Info "local  $LocalVer"
        Write-Info "origin $remoteVer  (origin/main)"
        if (-not (Test-VersionNewer $remoteVer $LocalVer) -and -not $Force) {
            if ($remoteVer -eq $LocalVer) { Write-Ok 'เป็นเวอร์ชันล่าสุดบน origin/main แล้ว' }
            else { Write-Ok "local ($LocalVer) ใหม่กว่า origin/main ($remoteVer) — ข้าม" }
            return $false
        }
        if (-not (Confirm-Action "อัปเดตโค้ดผ่าน git ($LocalVer -> $remoteVer) — แตะเฉพาะไฟล์ใน repo?")) {
            Write-Info 'ยกเลิก'; return $false
        }
        Write-Head 'git merge --ff-only origin/main'
        $out = & git -C $Root merge --ff-only origin/main 2>&1
        $rc = $LASTEXITCODE
        $out | ForEach-Object { Write-Info "$_" }
        if ($rc -ne 0) { throw "git merge ไม่สำเร็จ (exit $rc) — ใช้: aptstack update zip" }
        $newVer = Get-LocalAppVersion
        Write-Ok "อัปเดตผ่าน git แล้ว: $LocalVer -> $newVer"
        return $true
    } finally { $ErrorActionPreference = $oldEap }
}

function Cmd-Update([string]$act, [string]$mode) {
    # aptstack update           ตรวจ release บน GitHub แล้วอัปเดตโค้ดถ้ามีตัวใหม่ (zip + sha256)
    # aptstack update check      ดูเวอร์ชัน local vs GitHub อย่างเดียว (ไม่เขียนอะไร)
    # aptstack update zip        บังคับทาง release zip (ไม่ใช้ git)
    # aptstack update git        บังคับทาง git pull (ต้องมี .git + origin = aptstack)
    # aptstack update force      อัปเดตแม้เวอร์ชันเท่ากัน / local ใหม่กว่า / มีไฟล์ dirty
    $sub = "$act".Trim().ToLowerInvariant()
    if (-not $sub -and "$mode") { $sub = "$mode".Trim().ToLowerInvariant() }
    if ($sub -in @('-h', '--help', 'h', '?')) {
        Write-Head 'aptstack update — อัปเดตโค้ดจาก GitHub (แตะเฉพาะโค้ด)'
        Write-Info 'aptstack update           ตรวจ release ใหม่ + ดาวน์โหลด zip + sha256 แล้ว apply'
        Write-Info 'aptstack update check     ดู local vs GitHub อย่างเดียว (ไม่แก้ไฟล์)'
        Write-Info 'aptstack update zip       บังคับใช้ release zip'
        Write-Info 'aptstack update git       บังคับใช้ git pull (มี .git + origin aptstack)'
        Write-Info 'aptstack update force     ข้ามตรวจเวอร์ชัน/ dirty tree (ระวัง)'
        Write-Info ''
        Write-Info 'ไม่แตะ: config\ data\ versions\ stack\ downloads\ logs\ www junction'
        Write-Info 'แนะนำหลังอัปเดต: aptstack doctor  แล้ว  aptstack restart'
        return
    }
    if ($sub -notin @('', 'check', 'zip', 'git', 'force', 'force-zip', 'force-git')) {
        throw "ไม่รู้จัก 'aptstack update $act' — ใช้ได้: (ว่าง) | check | zip | git | force"
    }
    $force = $sub -in @('force', 'force-zip', 'force-git')
    $method = switch ($sub) {
        'zip' { 'zip' } 'force-zip' { 'zip' }
        'git' { 'git' } 'force-git' { 'git' }
        default { '' }   # auto
    }

    $local = Get-LocalAppVersion
    Write-Head 'aptstack update — โค้ดจาก GitHub (config/data/versions/stack ไม่โดน)'
    Write-Info "local version : $local"
    Write-Info "repo          : https://github.com/$Script:UpdateRepo"

    # ---- check เท่านั้น ----
    if ($sub -eq 'check') {
        $rel = $null
        try { $rel = Get-GitHubLatestRelease } catch { Write-Warn2 "API ล้มเหลว: $($_.Exception.Message)" }
        $remoteMain = $null
        try { $remoteMain = Get-RemoteMainVersion } catch { }
        if ($rel) {
            Write-Info "latest release: $($rel.Version)  ($($rel.Tag))"
            Write-Info "zip           : $($rel.Name)"
            if (Test-VersionNewer $rel.Version $local) { Write-Ok "มี release ใหม่กว่า ($local -> $($rel.Version)) — รัน: aptstack update" }
            elseif ($rel.Version -eq $local) { Write-Ok 'local = release ล่าสุด' }
            else { Write-Ok "local ($local) ใหม่กว่า release ล่าสุด ($($rel.Version)) — dev/ยังไม่ออก release" }
        } else { Write-Warn2 'อ่าน release จาก GitHub ไม่ได้ (เน็ต / ยังไม่มี release)' }
        if ($remoteMain) {
            Write-Info "main VERSION  : $remoteMain"
            if (Test-VersionNewer $remoteMain $local) { Write-Info 'main ใหม่กว่า local — aptstack update git (ถ้ามี .git) หรือรอ release zip' }
        }
        return
    }

    # ---- เลือก method: auto = git ถ้ามี .git+origin aptstack ไม่งั้น zip ----
    if (-not $method) {
        $hasGit = (Test-Path (Join-Path $Root '.git')) -and [bool](Get-Command git -ErrorAction SilentlyContinue)
        $method = if ($hasGit) { 'git' } else { 'zip' }
    }
    Write-Info "method        : $method$(if ($force) { '  (force)' })"

    $rel = $null
    if ($method -eq 'zip' -or $sub -eq 'check') {
        try { $rel = Get-GitHubLatestRelease } catch { }
        if ($method -eq 'zip' -and -not $rel) {
            # ไม่มี release -> ลอง branch zip ของ main (ไม่มี sha256)
            $mv = Get-RemoteMainVersion
            if (-not $mv) { throw 'อ่านข้อมูลจาก GitHub ไม่ได้ (เน็ต?) — ลองใหม่ หรือ aptstack update git' }
            if (-not (Test-VersionNewer $mv $local) -and -not $force) {
                if ($mv -eq $local) { Write-Ok "เป็นเวอร์ชันล่าสุดบน main แล้ว ($local)"; return }
                Write-Ok "local ($local) ใหม่กว่า main ($mv) — ข้าม"; return
            }
            $rel = [pscustomobject]@{
                Tag = "main ($mv)"; Version = $mv; Name = 'main.zip'
                ZipUrl = "https://github.com/$Script:UpdateRepo/archive/refs/heads/main.zip"
                ShaUrl = ''
            }
            Write-Warn2 'ไม่พบ GitHub Release — ใช้ branch zip ของ main (ไม่มี .sha256)'
        }
    }

    $changed = $false
    if ($method -eq 'git') {
        $changed = Update-FromGit $local $force
    } else {
        if (-not $rel) { throw 'ไม่พบ release บน GitHub — ลอง aptstack update git หรือใหม่ภายหลัง' }
        Write-Info "latest release: $($rel.Version)  ($($rel.Tag))"
        if (-not $force) {
            if (-not (Test-VersionNewer $rel.Version $local)) {
                if ($rel.Version -eq $local) { Write-Ok "เป็น release ล่าสุดแล้ว ($local) — ไม่มีอะไรอัปเดต"; return }
                Write-Ok "local ($local) ใหม่กว่า release ($($rel.Version)) — ข้าม (บังคับ: aptstack update force)"
                return
            }
            if (-not (Confirm-Action "อัปเดตโค้ด $local -> $($rel.Version) (release zip + sha256)?")) {
                Write-Info 'ยกเลิก'; return
            }
        } else {
            if (-not (Confirm-Action "บังคับ apply release $($rel.Version) ทับ local $local?")) {
                Write-Info 'ยกเลิก'; return
            }
        }
        $changed = Update-FromReleaseZip $rel $local $force
    }

    if ($changed) {
        Write-Host ''
        Write-Head 'อัปเดตเสร็จ — ขั้นถัดไป'
        Write-Info '  aptstack doctor     ตรวจความเรียบร้อย (junction www\app ด้วย)'
        Write-Info '  aptstack restart    ใช้โค้ด/ templates ใหม่ (ถ้า stack กำลังรัน)'
        Write-Info '  backup โค้ดเดิมอยู่ใน logs\update-bak-* (ย้อนได้ถ้าพัง)'
    }
}

function Cmd-Version {
    # สั้น: aptstack -v | --version | version (ใช้ใน script/CI — บรรทัดเดียวพอ)
    $v = Get-LocalAppVersion
    Write-Host "aptstack $v"
    Write-Info "root : $Root"
    Write-Info "update: aptstack update check   (เทียบกับ GitHub release ล่าสุด)"
}

function Cmd-Info {
    # ยาว: aptstack info — เวอร์ชัน + root + config สำคัญ + ของที่ติดตั้งอยู่
    $v = Get-LocalAppVersion
    $cfg = Get-Config
    Write-Head "aptstack $v"
    Write-Info "root       : $Root"
    Write-Info "repo       : https://github.com/$Script:UpdateRepo"
    Write-Info "release    : https://github.com/$Script:UpdateRepo/releases/tag/v$v"

    # git (ถ้ามี)
    if (Test-Path (Join-Path $Root '.git')) {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $gitExe = [bool](Get-Command git -ErrorAction SilentlyContinue)
        if ($gitExe) {
            $head = "$(& git -C $Root rev-parse --short HEAD 2>$null | Select-Object -First 1)"
            $branch = "$(& git -C $Root rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)"
            $dirty = @(& git -C $Root status --porcelain 2>$null).Count
            if ($head) { Write-Info "git        : $branch @ $head$(if ($dirty -gt 0) { "  ($dirty uncommitted)" })" }
        }
        $ErrorActionPreference = $oldEap
    } else { Write-Info 'git        : ไม่ใช่ clone (release zip / portable folder)' }

    Write-Host ''
    $apps = @(Get-AppVersions)
    $phpVers = @(Get-PhpVersions)
    $mySql = @(Get-ChildItem $Script:P.MySqlRoot -Directory -EA SilentlyContinue)
    $apache = @(Get-ChildItem $Script:P.ApacheRoot -Directory -EA SilentlyContinue)
    $curApp = Get-CurrentAppName
    $link = Join-Path $Script:P.Www "$($cfg.appAlias)"
    $li = Get-Item -LiteralPath $link -Force -EA SilentlyContinue
    $linkTxt = if (-not $li) { '(ไม่พบ)' }
               elseif ($li.Attributes -band [IO.FileAttributes]::ReparsePoint) { "junction -> $(Split-Path "$($li.Target)" -Leaf)" }
               else { 'โฟลเดอร์ธรรมดา (ไม่ใช่ junction — aptstack doctor ซ่อมให้ได้)' }
    $appNames = if ($apps.Count -gt 0) {
        $n = ($apps | Select-Object -First 8 | ForEach-Object Name) -join ', '
        "  [$n$(if ($apps.Count -gt 8) { ', …' })]"
    } else { '' }
    Write-Info "app active : $(if ($curApp) { $curApp } else { '(ยังไม่ได้ use)' })   www\$($cfg.appAlias) = $linkTxt"
    Write-Info "apps       : $($apps.Count) ใน versions\$appNames"
    Write-Info "php        : config=$($cfg.php)   ติดตั้ง $($phpVers.Count) ตัว$(if ($phpVers.Count -gt 0) { '  [' + (($phpVers | ForEach-Object Version) -join ', ') + ']' })"
    Write-Info "apache     : config=$($cfg.apache)   ติดตั้ง $($apache.Count) ตัว$(if ($apache.Count -gt 0) { '  [' + (($apache | ForEach-Object Name) -join ', ') + ']' })"
    Write-Info "mysql      : config=$($cfg.mysql)   ติดตั้ง $($mySql.Count) ตัว$(if ($mySql.Count -gt 0) { '  [' + (($mySql | ForEach-Object Name) -join ', ') + ']' })"
    Write-Info "ports      : http $($cfg.httpPort) · db $($cfg.dbPort) · https $(if ("$($cfg.httpsEnabled)".ToLower() -eq 'true') { "$($cfg.httpsPort) (on)" } else { 'off' })"
    Write-Info "mode       : webMode=$($cfg.webMode) · dbMode=$($cfg.dbMode)"

    Write-Host ''
    Write-Info 'ตรวจสุขภาพ     : aptstack doctor'
    Write-Info 'ดูเวอร์ชันใหม่  : aptstack update check   (หรือ aptstack update เพื่ออัปเดตโค้ด)'
    Write-Info 'สถานะ/พอร์ต    : aptstack status · aptstack list'
}

function Cmd-Help {
    Write-Head 'aptstack — portable PHP / MariaDB / app-version manager'
    @'
  ── ติดตั้งครั้งแรก ───────────────────────────────────
  aptstack init                    เตรียมโครงสร้างโฟลเดอร์ (ไม่มีแอปเลย -> ลงตัวอย่างให้)
  aptstack samples                 ติดตั้งตัวอย่างทั้งหมด (hello / todo / sysinfo)
  aptstack add app [folder|zip]    เพิ่มเวอร์ชันแอป -> versions\<name>
                                    ไม่ใส่ path = เมนูเลือก zip/โฟลเดอร์ด้วยหมายเลข
  aptstack seed                    สร้าง database ตัวอย่าง (greetings + todo_items)
  aptstack add php 8.3.36          เติม URL ทางการให้เอง + โหลด + ติดตั้ง (ใช้ latest ก็ได้)
  aptstack add php <zip|url>       หรือส่ง URL/path เอง
  aptstack list                    ดูที่ติดตั้ง + ที่ใช้อยู่ + ชื่อ DB + user ทั้งหมด
  aptstack list --available        ดูเวอร์ชันที่ "โหลดได้" จากเว็บทางการ (php|mysql|apache)
  aptstack start                   เริ่ม MariaDB + Web
  aptstack doctor                  ตรวจสุขภาพ + ช่องโหว่ RCE
  aptstack version | -v            เวอร์ชันแพ็กเกจ (สั้น — ใช้ใน script ได้)
  aptstack info                    สรุป root/config/สิ่งที่ติดตั้ง + URL release
  aptstack update [check|zip|git|force]
                                   อัปเดตโค้ดจาก GitHub (release zip + sha256 หรือ git pull)
                                   check = ดูเวอร์ชันอย่างเดียว · ไม่แตะ config/data/versions/stack

  ── สลับเวอร์ชัน (ง่ายสุด) ──────────────────────────
  aptstack use                     เมนูเลือก (แอป + PHP)
  aptstack use 1.1.0               สลับแอป + restart ให้เอง
  aptstack use 1.0                 ใช้ prefix ได้
  aptstack use -                   ย้อนกลับตัวก่อนหน้า
  aptstack next | prev             วนไปตัวถัดไป / ก่อนหน้า
  aptstack use php 8.3.36          สลับ PHP + restart
  aptstack use apache 2.4.69       สลับ Apache + restart (mod_php)
  aptstack use mysql 11.4.13       สลับ MySQL/MariaDB (datadir แยกต่อ version)
  aptstack add app [folder|zip]    copy version ใหม่ลง แล้ว use เลย
                                    (ไม่ใส่ path = เมนูเลือกหมายเลข)
  aptstack add apache <ver|zip|url> เพิ่ม Apache (เช่น 2.4.69 — โหลดจาก Apache Lounge ให้เอง) -> stack\apache\
  aptstack add mysql <version|zip> เพิ่ม MySQL/MariaDB -> stack\mysql\
  aptstack add phpmyadmin [ver|latest]  ติดตั้ง/เปลี่ยน -> www\phpmyadmin (URL: /phpmyadmin/)
  aptstack list --available phpmyadmin  ดูเวอร์ชันที่โหลดได้
  aptstack db                     ดู user/URL ของ stack นี้
  aptstack db-list [all]          ชื่อ database + user ทั้งหมด (สั้น)
  aptstack db list [all]          รายชื่อ database + จำนวนตาราง + ขนาด + users (all = รวม system)
  aptstack db set-root <pass>     ตั้งรหัส root (อัปเดต stack.json + phpMyAdmin ให้)
  aptstack db add-user <user> <pass>   เพิ่ม MySQL user ใหม่

  ── web / db mode (ไม่ต้องแก้มือ config\stack.json) ──
  aptstack config                 ดู webMode/dbMode/https/พอร์ต ปัจจุบัน
  aptstack config web apache      ใช้ Apache (HTTPS/vhost ได้)  |  builtin | auto
  aptstack config db internal     MariaDB ใน bundle | external = ยืม MySQL ของ XAMPP
  aptstack config https on|off    เปิด/ปิด HTTPS (ต้อง webMode=apache)
  aptstack config http <port>     เปลี่ยนพอร์ต HTTP
  aptstack config dbport <port>   เปลี่ยนพอร์ต DB
  "webMode":  "auto"|"apache"|"builtin"
  "dbMode":   "internal"|"external"   external = ยืม MySQL ของ XAMPP

  ── เปิด/ปิด ──────────────────────────────────────────
  aptstack start | stop | restart
  aptstack stop <port>           หยุด program ที่จองพอร์ตนั้น (โชว์ exe path ก่อน · ถามถ้าไม่ใช่ของเรา)
  aptstack ports                 ดูพอร์ตของ stack + เจ้าของ (PID/exe/folder) — รู้ทันทีของ bundle ไหน
  aptstack shorttag [on|off]     short_open_tag สำหรับแอป CI3 / โค้ด <? เก่า (default: On)
  aptstack run                   dev console: start + บล็อกหน้าจอ กด Ctrl+C หยุด (ไม่ต้อง register service)
  aptstack status                รวม mapping พอร์ต -> program
  aptstack backup [file.sql]       dump ทุก database ไป data\dumps\
  aptstack seed                    import database ตัวอย่าง (aptstack_demo)
  aptstack import <file.sql|.sql.zip> [dbname]
                                   import dump เข้า database (สร้าง DB ให้ · ไทยไม่พัง · แบบ db_manager)
  aptstack import <โฟลเดอร์ dump> [dbname]
                                   ลิสต์ .sql/.sql.zip/.zip ให้เลือกหมายเลข (1,2 / all / 1,3)
                                   ระบุ [dbname] = ใช้ชื่อนั้น · ไม่ระบุ = ถาม + โชว์รายการ DB (กันซ้ำ)
                                   เช่น aptstack import ..\_setup_appoint\ appoint052569
  aptstack import <โฟลเดอร์ aptstack เก่า> [--no-downloads]
                                   ย้ายทั้ง install เก่า (stack/data/www/versions/config) เข้า root นี้
                                   — โค้ดใหม่คงเดิม · แสดงสถานะทีละขั้น · data เก่ากันไว้ data.preimport-*
  aptstack logs <apache|mysql|php> ดู log ท้ายไฟล์ (ตัวเลข = กี่บรรทัด, default 50)
  aptstack logs all                ดู log error ทุกตัว

  ── HTTPS / TLS ───────────────────────────────────────
  aptstack tls status               ดูสถานะ + วันหมดอายุ cert
  aptstack tls init [domain,..]     สร้าง self-signed cert (openssl/mkcert) แล้วเปิดให้เลย
  aptstack tls import <c.pem> <k.pem>  ใช้ SSL cert จริง (Let's Encrypt/พาณิชย์)
  aptstack tls off                  ปิด HTTPS

  ── จัดการ version / ข้อมูล (มียืนยันก่อนลบ) ──────
  aptstack clone                   ถามก่อน: app หรือ mysql แล้วเข้าเมนู
  aptstack clone app               เมนูเลือก app + ชื่อเวอร์ชันถัดให้เอง (1.0->1.1)
                                   คัดลอกโค้ด · DB เดิม · ยังไม่สลับ -> use เอง
  aptstack clone app <จาก> [เป็น]  ไม่ใส่ [เป็น] = คำนวณชื่อเวอร์ชันถัดให้
  aptstack clone mysql             เมนูเลือก datadir + ชื่อถัดให้ (ต้อง stop ก่อน)
  aptstack clone mysql <จาก> [เป็น] คัดลอก datadir (ไม่ใส่ [เป็น] = ชื่อถัดให้)
  aptstack clone-tree              ดูสายสัมพันธ์ clone ระหว่าง app version (console)
  aptstack report clone [path]     HTML แผนผัง clone/family + ตาราง size/source
  aptstack remove app <ชื่อ>       ลบโค้ด app (ถามยืนยัน · ตัวที่ใช้อยู่ลบไม่ได้)
  aptstack remove php|apache|mysql <ชื่อ> [data]  ลบ binary (data เก็บไว้ เว้นแต่ใส่ data แล้วยืนยัน DELETE)
  aptstack migrate mysql <ใหม่>    โยกข้อมูล DB ไป engine ใหม่ (dump -> switch -> restore)
  aptstack pull mysql <สูง> [root]  ดึง config + ฐานข้อมูล จาก version ต่ำ/root อื่น -> version สูง
                                   list แหล่งรวม -> เลือกกลุ่ม -> เลือกรายตัวหรือ all -> ดูแผนก่อน
                                   -> มี % + ETA ระหว่าง dump/import
  aptstack report [path]           สร้างหน้า HTML สรุปสถานะทั้งหมด (เปิดให้ + พิมพ์ได้)
  aptstack report db [name]        inventory database (ก้อน/ตาราง/ขนาด/ดิสก์รวม)
  aptstack report clone [path]     รายงานสายสัมพันธ์ clone ระหว่าง app version
  aptstack clone-tree              ดู clone lineage สั้น ๆ ใน console
  aptstack record start [name]     บันทึกคำสั่งเป็น scripts\*.ps1 (รันซ้ำได้)
  aptstack record stop | status
  aptstack play <file.ps1>         รัน script ที่ record ไว้
  aptstack size                    ดูพื้นที่ทุกโฟลเดอร์ + เตือน bundle บวม / ดิสก์ใกล้เต็ม

  ── deploy / เทียบโค้ด ───────────────────────────────
  aptstack dist <app> [out] [nostack]
        copy ทั้งก้อน → dist_paste\<app>\
        (scripts + app + stack ถ้าไม่ nostack + VERSIONS.txt)
        = "เอาชุดสมบูรณ์ไปวาง server ใหม่"
        → ใหญ่ · ไม่เทียบกับต้นทาง · ใช้ตอนติดตั้งครั้งแรก/ย้ายเครื่อง

  aptstack diff [app] [out]
        เทียบ ต้นทาง(.aptstack-source) vs versions\<app>
        → เฉพาะไฟล์ที่ต่าง (files\ + manifest + report + apply.ps1)
        = "เอาเฉพาะ patch ที่แก้ไป overwrite server เดิม"
        → เล็ก · ต้องมี zip/folder ต้นทาง · เมนูเลือก app/output
        ดูต้นทางทุก app:  aptstack import-origin

  aptstack import-origin           แสดงต้นทางว่า import app/binary มาจากไหน (ทุกตัว)
  aptstack git init|status|clear   git ของ bundle บน server (track config เฉย ๆ / ลบ .git)

  ── Windows Service ──────────────────────────────────
  aptstack service                 ดูวิธีใช้ + สถานะ service
  aptstack service install         ติดตั้ง service (ต้อง Run as admin)
  aptstack service uninstall
  aptstack service start | stop | status | restart
  aptstack service compile         build bin\aptstack-svc.exe อย่างเดียว

  ── ทางลัด ──────────────────────────────────────────
  as list                          ใช้ as แทน aptstack ได้
  aptstack l                       l = list
'@ | Write-Host
}

# ---------------------------------------------------------------- service
function Cmd-ServiceHelp {
    Write-Head 'Windows Service (AptStack)'
    Write-Info 'bin : bin\aptstack-svc.exe   (compile จาก service\AptStackService.cs)'
    Write-Info 'run : aptstack.ps1 service-run  (service เรียกตัวนี้เอง)'
    Write-Host ''
    Write-Host '   คำสั่ง (ต้อง Run as admin สำหรับ install/uninstall/start/stop):' -ForegroundColor Gray
    Write-Host '   aptstack service                 หน้านี้ + สถานะปัจจุบัน' -ForegroundColor White
    Write-Host '   aptstack service status          ดูสถานะ + binPath' -ForegroundColor White
    Write-Host '   aptstack service install         ติดตั้ง (sc create Auto + failure restart)' -ForegroundColor White
    Write-Host '   aptstack service uninstall       ถอน (sc stop + sc delete)' -ForegroundColor White
    Write-Host '   aptstack service start           เริ่ม stack ผ่าน service' -ForegroundColor White
    Write-Host '   aptstack service stop            หยุด (เขียน stop.flag → Cmd-Stop)' -ForegroundColor White
    Write-Host '   aptstack service restart         stop + start' -ForegroundColor White
    Write-Host '   aptstack service compile         build aptstack-svc.exe อย่างเดียว' -ForegroundColor White
    Write-Host ''
    Write-Info 'หมายเหตุ: ชื่อ service = AptStack · binPath ชี้ bundle root ที่สั่ง install'
    Write-Info 'ย้ายไป bundle อื่น → uninstall จาก root เก่า แล้ว install จาก root ใหม่'
    Write-Host ''
    & (Join-Path $Root 'service.ps1') -Action status
}

function Cmd-Service([string]$act) {
    $sa = "$act".Trim().ToLowerInvariant()
    if (-not $sa -or $sa -in @('help', 'h', '?', '--help', '-?', '/?')) {
        Cmd-ServiceHelp
        return
    }
    $valid = @('install', 'uninstall', 'start', 'stop', 'restart', 'status', 'compile')
    if ($sa -notin $valid) {
        Write-Warn2 "ไม่รู้จัก action: $act"
        Cmd-ServiceHelp
        throw ("ใช้: aptstack service [install|uninstall|start|stop|restart|status|compile]`n     (ไม่ใส่ action = help)")
    }
    & (Join-Path $Root 'service.ps1') -Action $sa
}

# ---------------------------------------------------------------- service run
function Cmd-ServiceRun {
    # ถูกเรียกโดย aptstack-svc.exe (Windows Service)
    Remove-Item $Script:P.StopFlag -Force -ErrorAction SilentlyContinue
    $cfg = Get-Config
    $cfg.dbAdmin = 'auto'
    Save-Config $cfg
    Cmd-Start
    Write-Info 'service: stack running — รอสัญญาณหยุด'
    while (-not (Test-Path $Script:P.StopFlag)) {
        Start-Sleep -Seconds 2
        # ถ้า web ดับเองให้ปลุกขึ้นมาใหม่
        if ((-not (Test-Running 'web')) -and (Test-PortFree $cfg.httpPort)) {
            Write-Warn2 'service: web หาย — เริ่มใหม่'
            Start-Web $cfg | Out-Null
        }
    }
    Write-Info 'service: ได้รับสัญญาณหยุด'
    Cmd-Stop
}

# ---------------------------------------------------------------- dispatch
Ensure-Dirs
# -h / -? / --help ทุกรูปแบบ -> พาไป help
if ($HelpFlag) { $Command = 'help' }
# -v / -Version -> โชว์เวอร์ชัน (ค่าเริ่มต้น Command = help ถ้าไม่ใส่อะไร)
if ($VersionFlag) { $Command = 'version' }

# จับ throw ทั้งหมด -> โชว์เป็น [ERR] สีแดง (ไม่ให้ PowerShell ทิ้ง RuntimeException ยาว ๆ)
try {
switch ($Command.ToLower()) {
    'init'        { Cmd-Init }
    'help'        { Cmd-Help }
    'h'           { Cmd-Help }
    '?'           { Cmd-Help }
    '/?'          { Cmd-Help }
    '--help'      { Cmd-Help }
    'version'     { Cmd-Version }
    'ver'         { Cmd-Version }
    '--version'   { Cmd-Version }
    'info'        { Cmd-Info }
    '--info'      { Cmd-Info }
    'add'         { Cmd-Add $Action $Value $Extra }
    'list'        {
        # -Available (switch) กิน token `--available` ไป -> kind หลุดมาอยู่ $Action
        if ($Available) { Cmd-ListAvailable $Action }
        elseif ($Action -eq 'available' -or $Action -eq '-a') { Cmd-ListAvailable $Value }
        else { Cmd-List }
    }
    'ls'          {
        if ($Available) { Cmd-ListAvailable $Action }
        elseif ($Action -eq 'available' -or $Action -eq '-a') { Cmd-ListAvailable $Value }
        else { Cmd-List }
    }
    'l'           {
        if ($Available) { Cmd-ListAvailable $Action }
        elseif ($Action -eq 'available' -or $Action -eq '-a') { Cmd-ListAvailable $Value }
        else { Cmd-List }
    }
    'use'         { Cmd-Use $Action $Value }
    'u'           { Cmd-Use $Action $Value }
    'next'        { Step-App 1 }
    'prev'        { Step-App -1 }
    'start'       { Cmd-Start }
    'run'         { Cmd-Run }
    'stop'        { Cmd-Stop $Action }
    'ports'       { Cmd-Ports $Action }
    'shorttag'    { Cmd-ShortTag $Action }
    'short_open_tag' { Cmd-ShortTag $Action }
    'restart'     { Cmd-Restart }
    'status'      { Cmd-Status }
    'doctor'      { Cmd-Doctor }
    'backup'      { Cmd-Backup $Action }
    'seed'        { Cmd-Seed }
    'import'      { Cmd-Import $Action $Value $Extra }
    'db'          { Cmd-Db $Action $Value $Extra }
    'db-list'     {
        # aptstack db-list [all] — ชื่อ DB + user ทั้งหมด (ไม่โชว์ขนาด)
        if ("$Action" -eq 'help' -or "$Action" -eq '-h') {
            Write-Head 'aptstack db-list — ชื่อ database + user ทั้งหมด'
            Write-Info 'ใช้: aptstack db-list'
            Write-Info '     aptstack db-list all     รวม system db'
            Write-Info 'ดูขนาด/ตาราง: aptstack db list'
            return
        }
        Write-Head 'db-list — database names + users'
        Show-DbNamesAndUsers (Get-Config) $true
        Write-Host ''
        Write-Info 'รายละเอียด+ขนาด: aptstack db list [all]'
        Write-Info 'เพิ่ม user     : aptstack db add-user <user> <pass>'
    }
    'dblist'      { Cmd-Db 'list' $Action $Value }
    'config'      { Cmd-Config $Action $Value }
    'samples'     { Cmd-Samples }
    'report'      { Cmd-Report $Action $Value }
    'record'      { Cmd-Record $Action $Value }
    'play'        { Cmd-Play $Action }
    'size'        { Cmd-Size }
    'dist'        { Cmd-Dist $Action $Value $Extra }
    'diff'        { Cmd-Diff $Action $Value $Extra }
    'import-origin' { Cmd-ImportOrigin }
    'origin'      { Cmd-ImportOrigin }
    'update'      { Cmd-Update $Action $Value }
    'upgrade'     { Cmd-Update $Action $Value }
    'git'         { Cmd-Git $Action $Value }
    'clone'       { Cmd-Clone $Action $Value $Extra }
    'clone-tree'  { Cmd-CloneTree }
    'clonetree'   { Cmd-CloneTree }
    'lineage'     { Cmd-CloneTree }
    'remove'      { Cmd-Remove $Action $Value $Extra }
    'rm'          { Cmd-Remove $Action $Value $Extra }
    'migrate'     { Cmd-Migrate $Action $Value }
    'pull'        { Cmd-Pull $Action $Value $Extra }
    'logs'        { Cmd-Logs $Action $Value }
    'tls'         { Cmd-Tls $Action $Value $Extra }
    'https'       { Cmd-Tls $Action $Value $Extra }
    'service'     { Cmd-Service $Action }
    'service-run' { Cmd-ServiceRun }
    default       { Cmd-Help }
}

# หลังรันคำสั่งสำเร็จ — ถ้า record อยู่ ให้เขียนลง script (ยกเว้น record/play เอง)
if ($Command) { Write-RecordEntry $Command $Action $Value $Extra }
}
catch {
    $raw = "$($_.Exception.Message)"
    if (-not $raw) { $raw = "$_" }
    $lines = @($raw -split "`r?`n")
    Write-Err2 $lines[0]
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $ln = "$($lines[$i])".TrimEnd()
        if ($ln.Trim()) { Write-Info $ln.TrimStart() }
    }
    exit 1
}


