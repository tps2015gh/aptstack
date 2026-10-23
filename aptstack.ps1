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
    [Alias('h', '?', 'Help')][switch]$HelpFlag
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
                ApacheMod  = (Test-Path (Join-Path $d.FullName 'php8apache2_4.dll'))
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
            # auto: ใช้ Apache ถ้ามี ครบทั้ง httpd + php8apache2_4.dll (Thread Safe)
            if ($apache -and $php -and (Test-Path (Join-Path $php.Dir 'php8apache2_4.dll'))) { return 'apache' }
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
    $map = @{
        '{{APACHE_DIR}}' = ($apacheHit.Dir -replace '\\', '/')
        '{{PHP_DIR}}'    = ($php.Dir -replace '\\', '/')
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
    if ($p) { return $p }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    return $null
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
    $healthy = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($w = 0; $w -lt 30; $w++) {
        Start-Sleep -Seconds 1
        if (Test-PortFree $cfg.dbPort) { continue }
        if (Invoke-DbAdmin $hit @('ping')) { $healthy = $true; break }
    }
    $sw.Stop()
    if (-not $healthy) {
        Write-Err2 "MariaDB ไม่ตอบ (รอ $($sw.Elapsed.TotalSeconds.ToString('0.0')) วิ) — ดู logs\mariadb-error.log"
        Write-Info 'เปิดดู: aptstack logs mysql'
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
        if (-not (Test-Path (Join-Path $php.Dir 'php8apache2_4.dll'))) {
            Write-Err2 "PHP $($php.Version) เป็น NTS — ใช้กับ mod_php ไม่ได้ (ต้อง Thread Safe)"
            Write-Info 'ลอง: aptstack use php 8.3.36 หรือ add PHP แบบ Win32-vs16-x64 (ไม่ใช่ -nts-)'
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
            for ($w = 0; $w -lt 20; $w++) { Start-Sleep -Seconds 1; if (Test-PortFree $cfg.dbPort) { break } }
            Write-Ok 'MariaDB ปิดแบบ clean shutdown'
            Clear-Pid 'mysql'
        } else {
            Stop-ByPidFile 'mysql'
        }
    } else {
        Clear-Pid 'mysql'
    }
    Stop-ByPort -port $cfg.dbPort -label 'MariaDB'
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
    if (-not $php -or -not (Test-Path (Join-Path $php.Dir 'php8apache2_4.dll'))) {
        Write-Warn2 "PHP $($cfg.php) ไม่มี php8apache2_4.dll (NTS) — Apache mod_php จะ start ไม่ขึ้น"
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

function Cmd-Add($kind, $source, $extra) {
    if (-not $kind -or -not $source) {
        throw 'ใช้: aptstack add <app|php|mysql|apache> <path|url|version> [name]   (เช่น: aptstack add php 8.3.36)'
    }
    Ensure-Dirs

    # ใส่แค่เลขเวอร์ชัน / latest -> เติม URL ทางการให้เอง แล้ว print ให้เห็น (จะได้ copy โหลดเองได้)
    $origSource = $source
    $candidates = @($source)
    $isBinary = @('php', 'mysql', 'apache') -contains ("$kind".ToLower())
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
            $name = if ($extra) { $extra } else {
                $n = Split-Path $src -Leaf
                $n -replace '\.(zip|7z|tar\.gz)$', ''
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
            if ($php.ApacheMod) { Write-Info 'Thread Safe build (มี php8apache2_4.dll)' }
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
            if ($php -and (Test-Path (Join-Path $php.Dir 'php8apache2_4.dll'))) {
                Write-Ok "Apache พร้อมใช้ mod_php กับ PHP $($php.Version)"
            } else {
                Write-Warn2 'PHP ที่เลือกยังไม่มี php8apache2_4.dll (NTS) — ต้องเปลี่ยนเป็น Thread Safe ก่อนใช้ Apache'
            }
            Write-Info 'เปิดใช้: แก้ config\stack.json -> "webMode": "apache" แล้ว aptstack restart'
        }
        default { throw "ไม่รู้จักชนิด: $kind (ใช้ app | php | mysql | apache)" }
    }
}

# ---------------------------------------------------------------- list
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
    Write-Host '  Database:' -ForegroundColor White
    if ($dbs.Count -eq 0) { Write-Info '(ยังไม่มี)' }
    foreach ($m in $dbs) {
        Write-Host "     $($m.Version)  $($m.Dir)" -ForegroundColor Gray
        $sm = Get-SourceMeta $m.Dir
        if ($sm -and $sm['source']) { Write-Host "           from: $($sm['source'])" -ForegroundColor DarkGray }
    }

    $aps = @(Get-ApacheVersions)
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
    Write-Host "  MySQL   : 127.0.0.1:$($cfg.dbPort)"
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
    if (@('all', 'php', 'mysql', 'apache') -notcontains $kind) {
        throw "ไม่รู้จัก '$kind' — ใช้: aptstack list --available [php|mysql|apache]"
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
        elseif (-not $php -or -not (Test-Path (Join-Path $php.Dir 'php8apache2_4.dll'))) {
            Write-Err2 'Apache mode ต้องใช้ PHP แบบ Thread Safe (มี php8apache2_4.dll)'; $problems++
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

    # 5) app link
    $cfg2 = Get-Config
    $link = Join-Path $Script:P.Www $cfg2.appAlias
    $i = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if (-not $i) { Write-Err2 "ไม่พบ www\$($cfg2.appAlias)"; $problems++ }
    elseif (-not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Write-Warn2 "www\$($cfg2.appAlias) ไม่ใช่ junction — สลับเวอร์ชันไม่ได้" }
    else { Write-Ok "www\$($cfg2.appAlias) -> $(Split-Path $i.Target -Leaf)" }
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

function Cmd-Report([string]$OutPath) {
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

<h2>8. คำสั่งที่ใช้บ่อย</h2>
<table class="kv">
<tr><td>สลับแอป</td><td><code>aptstack use &lt;ชื่อ&gt;</code> · <code>next</code> · <code>prev</code> · <code>use -</code></td></tr>
<tr><td>สลับ PHP</td><td><code>aptstack use php &lt;ver&gt;</code></td></tr>
<tr><td>ตรวจซ้ำ</td><td><code>aptstack doctor</code></td></tr>
<tr><td>ดู log</td><td><code>aptstack logs apache|mysql|php</code></td></tr>
<tr><td>backup</td><td><code>aptstack backup</code></td></tr>
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
    if (-not $what -or -not $from -or -not $to) { throw 'ใช้: aptstack clone <app|mysql> <จาก> <เป็น>' }
    Guard-Name $from 'ชื่อต้นทาง'
    Guard-Name $to 'ชื่อปลายทาง'

    switch ($what.ToLower()) {
        'app' {
            $src = Join-Path $Script:P.Versions $from
            $dst = Join-Path $Script:P.Versions $to
            if (-not (Test-Path $src)) { throw "ไม่พบ versions\$from" }
            if (Test-Path $dst) { throw "มี versions\$to อยู่แล้ว — เปลี่ยนชื่อปลายทาง" }
            $cfg = Get-Config
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
        }
        'mysql' {
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
        default { throw "ไม่รู้จัก '$what' — ใช้ได้: app | mysql" }
    }
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

function Cmd-Dist($appVer, $outRoot, $extra) {
    # สร้างชุด deploy แบบ copy-paste ได้ทันที: dist_paste\<appver>\
    # รวม scripts + app code + (ถ้าไม่บอก nostack) binary ทั้งหมด + www + config บางส่วน
    # ไม่รวม: data (DB), config ที่ generate, certs, logs, .git  -> server สร้างเองตอน start
    Ensure-Dirs
    if (-not $appVer) { $appVer = Get-CurrentAppName }
    if (-not $appVer) { throw 'ไม่ได้ระบุ app และยังไม่มีตัว active — ใช้: aptstack dist <ชื่อapp> [outRoot] [nostack]' }
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

function Cmd-Help {
    Write-Head 'aptstack — portable PHP / MariaDB / app-version manager'
    @'
  ── ติดตั้งครั้งแรก ───────────────────────────────────
  aptstack init                    เตรียมโครงสร้างโฟลเดอร์ (ไม่มีแอปเลย -> ลงตัวอย่างให้)
  aptstack samples                 ติดตั้งตัวอย่างทั้งหมด (hello / todo / sysinfo)
  aptstack add app <folder|zip>    เพิ่มเวอร์ชันแอป -> versions\<name>
  aptstack seed                    สร้าง database ตัวอย่าง (greetings + todo_items)
  aptstack add php 8.3.36          เติม URL ทางการให้เอง + โหลด + ติดตั้ง (ใช้ latest ก็ได้)
  aptstack add php <zip|url>       หรือส่ง URL/path เอง
  aptstack list                    ดูที่ติดตั้ง + ที่ใช้อยู่ (มี from: <url> ให้ copy โหลดเองได้)
  aptstack list --available        ดูเวอร์ชันที่ "โหลดได้" จากเว็บทางการ (php|mysql|apache)
  aptstack start                   เริ่ม MariaDB + Web
  aptstack doctor                  ตรวจสุขภาพ + ช่องโหว่ RCE

  ── สลับเวอร์ชัน (ง่ายสุด) ──────────────────────────
  aptstack use                     เมนูเลือก (แอป + PHP)
  aptstack use 1.1.0               สลับแอป + restart ให้เอง
  aptstack use 1.0                 ใช้ prefix ได้
  aptstack use -                   ย้อนกลับตัวก่อนหน้า
  aptstack next | prev             วนไปตัวถัดไป / ก่อนหน้า
  aptstack use php 8.3.36          สลับ PHP + restart
  aptstack use apache 2.4.69       สลับ Apache + restart (mod_php)
  aptstack use mysql 11.4.13       สลับ MySQL/MariaDB (datadir แยกต่อ version)
  aptstack add app <folder|zip>    copy version ใหม่ลง แล้ว use เลย
  aptstack add apache <ver|zip|url> เพิ่ม Apache (เช่น 2.4.69 — โหลดจาก Apache Lounge ให้เอง) -> stack\apache\
  aptstack add mysql <version|zip> เพิ่ม MySQL/MariaDB -> stack\mysql\

  ── web / db mode (config\stack.json) ─────────────────
  "webMode":  "auto"|"apache"|"builtin"
  "dbMode":   "internal"|"external"   external = ยืม MySQL ของ XAMPP

  ── เปิด/ปิด ──────────────────────────────────────────
  aptstack start | stop | restart
  aptstack stop <port>           หยุด program ที่จองพอร์ตนั้น (โชว์ exe path ก่อน · ถามถ้าไม่ใช่ของเรา)
  aptstack ports                 ดูพอร์ตของ stack + เจ้าของ (PID/exe/folder) — รู้ทันทีของ bundle ไหน
  aptstack run                   dev console: start + บล็อกหน้าจอ กด Ctrl+C หยุด (ไม่ต้อง register service)
  aptstack status                รวม mapping พอร์ต -> program
  aptstack backup [file.sql]       dump ทุก database ไป data\dumps\
  aptstack seed                    import database ตัวอย่าง (aptstack_demo)
  aptstack logs <apache|mysql|php> ดู log ท้ายไฟล์ (ตัวเลข = กี่บรรทัด, default 50)
  aptstack logs all                ดู log error ทุกตัว

  ── HTTPS / TLS ───────────────────────────────────────
  aptstack tls status               ดูสถานะ + วันหมดอายุ cert
  aptstack tls init [domain,..]     สร้าง self-signed cert (openssl/mkcert) แล้วเปิดให้เลย
  aptstack tls import <c.pem> <k.pem>  ใช้ SSL cert จริง (Let's Encrypt/พาณิชย์)
  aptstack tls off                  ปิด HTTPS

  ── จัดการ version / ข้อมูล (มียืนยันก่อนลบ) ──────
  aptstack clone app <จาก> <เป็น>  ก้อปปี้โค้ด app 1.0 -> 1.1 (ยังไม่สลับให้ -> use เอง)
  aptstack clone mysql <จาก> <เป็น> คัดลอก datadir (ต้อง stop ก่อน · ใช้กับ engine ใหม่)
  aptstack remove app <ชื่อ>       ลบโค้ด app (ถามยืนยัน · ตัวที่ใช้อยู่ลบไม่ได้)
  aptstack remove php|apache|mysql <ชื่อ> [data]  ลบ binary (data เก็บไว้ เว้นแต่ใส่ data แล้วยืนยัน DELETE)
  aptstack migrate mysql <ใหม่>    โยกข้อมูล DB ไป engine ใหม่ (dump -> switch -> restore)
  aptstack report [path]           สร้างหน้า HTML สรุปสถานะทั้งหมด (เปิดให้ + พิมพ์ได้)
  aptstack size                    ดูพื้นที่ทุกโฟลเดอร์ + เตือน bundle บวม / ดิสก์ใกล้เต็ม
  aptstack dist <app> [out] [nostack]  สร้างชุด deploy copy-paste (มี VERSIONS.txt + DEPLOY.txt)
  aptstack git init|status|clear   git ของ bundle บน server (track config เฉย ๆ / ลบ .git)

  ── Windows Service ──────────────────────────────────
  aptstack service install         ติดตั้ง service (ต้อง Run as admin)
  aptstack service uninstall
  aptstack service start | stop | status

  ── ทางลัด ──────────────────────────────────────────
  as list                          ใช้ as แทน aptstack ได้
  aptstack l                       l = list
'@ | Write-Host
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

switch ($Command.ToLower()) {
    'init'        { Cmd-Init }
    'help'        { Cmd-Help }
    'h'           { Cmd-Help }
    '?'           { Cmd-Help }
    '/?'          { Cmd-Help }
    '--help'      { Cmd-Help }
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
    'restart'     { Cmd-Restart }
    'status'      { Cmd-Status }
    'doctor'      { Cmd-Doctor }
    'backup'      { Cmd-Backup $Action }
    'seed'        { Cmd-Seed }
    'samples'     { Cmd-Samples }
    'report'      { Cmd-Report $Action }
    'size'        { Cmd-Size }
    'dist'        { Cmd-Dist $Action $Value $Extra }
    'git'         { Cmd-Git $Action $Value }
    'clone'       { Cmd-Clone $Action $Value $Extra }
    'remove'      { Cmd-Remove $Action $Value $Extra }
    'rm'          { Cmd-Remove $Action $Value $Extra }
    'migrate'     { Cmd-Migrate $Action $Value }
    'logs'        { Cmd-Logs $Action $Value }
    'tls'         { Cmd-Tls $Action $Value $Extra }
    'https'       { Cmd-Tls $Action $Value $Extra }
    'service'     { & (Join-Path $Root 'service.ps1') -Action $Action }
    'service-run' { Cmd-ServiceRun }
    default       { Cmd-Help }
}


