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
    [switch]$NoRestart
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
function Get-AppVersions {
    if (-not (Test-Path $Script:P.Versions)) { return @() }
    $out = @()
    foreach ($d in (Get-ChildItem $Script:P.Versions -Directory -ErrorAction SilentlyContinue)) {
        $out += [pscustomobject]@{
            Name   = $d.Name
            Dir    = $d.FullName
            Usable = (Test-Path (Join-Path $d.FullName 'index.php'))
        }
    }
    return ($out | Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0' } })
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

function Stop-ByPort($port, $label) {
    $id = Get-PortPid $port
    if (-not $id) { return }
    try {
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        Stop-Process -Id $id -Force -ErrorAction Stop
        Write-Ok "หยุด $label (PID $id$(if($proc){' / ' + $proc.ProcessName})) ที่จองพอร์ต $port"
    } catch { Write-Warn2 "หยุด process บนพอร์ต $port ไม่สำเร็จ" }
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
        Write-Warn2 "พอร์ต $($cfg.dbPort) ถูกใช้อยู่โดย process อื่น (PID $(Get-PortPid $cfg.dbPort)) — ข้าม MariaDB"
        return $false
    }
    $hit = Resolve-MySql $cfg.mysql
    if (-not $hit) { Write-Warn2 'ไม่พบ MariaDB/MySQL ใน stack\mysql\ — ข้าม'; return $false }

    $datadir = Get-DataDir $hit
    if (-not (Test-Path $datadir)) { New-Item -ItemType Directory -Path $datadir -Force | Out-Null }
    if (-not (Test-Path (Join-Path $datadir 'mysql'))) {
        Write-Head 'สร้าง data directory ครั้งแรก'
        Write-Info $datadir
        $args = @('--initialize-insecure', "--datadir=$datadir", "--basedir=$($hit.Dir)")
        $p = Start-Process -FilePath $hit.Daemon -ArgumentList $args -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { Write-Err2 "mysqld --initialize ล้มเหลว (exit $($p.ExitCode))"; return $false }
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
        Write-Warn2 "พอร์ต $($cfg.httpPort) ถูกใช้อยู่โดย process อื่น (PID $(Get-PortPid $cfg.httpPort)) — ข้าม web"
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
    Start-Web $cfg | Out-Null
    Cmd-Summary
}

function Cmd-Stop {
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
            Invoke-WebRequest -Uri $source -OutFile $zip -UseBasicParsing
            Write-Ok "บันทึกไว้: $zip"
        }
        return $zip
    }
    if (-not (Test-Path $source)) { throw "ไม่พบไฟล์/โฟลเดอร์: $source" }
    return (Resolve-Path $source).Path
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

function Cmd-Add($kind, $source, $extra) {
    if (-not $kind -or -not $source) { throw 'ใช้: aptstack add <app|php|mysql> <path|url> [name]' }
    Ensure-Dirs

    switch ($kind.ToLower()) {
        'app' {
            $src = Get-DownloadedZip $source
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
            Write-Ok "ติดตั้ง app $name เรียบร้อย"
            Write-Info "เปิดใช้: aptstack use $name"
        }
        'php' {
            $src = Get-DownloadedZip $source
            if (Test-Path $src -PathType Container) { throw 'PHP ต้องเป็นไฟล์ .zip' }
            $leaf = [IO.Path]::GetFileNameWithoutExtension((Split-Path $src -Leaf))
            $name = if ($leaf -match 'php-(\d+\.\d+\.\d+)') { $Matches[1] } else { $leaf }
            $dest = Join-Path $Script:P.PhpRoot $name
            if (Test-Path $dest) { Write-Warn2 "มีอยู่แล้ว: $dest"; return }
            Write-Head "ติดตั้ง PHP -> stack\php\$name"
            Expand-AndFlatten $src $dest
            if (-not (Test-Path (Join-Path $dest 'php.exe'))) { throw "zip ไม่มี php.exe — ตรวจว่าเลือกถูกตัว" }
            $php = Resolve-Php $name
            Write-Ok "ติดตั้ง PHP $($php.Version) เรียบร้อย"
            if ($php.ApacheMod) { Write-Info 'Thread Safe build (มี php8apache2_4.dll)' }
            else { Write-Info 'NTS build — ใช้ได้กับ PHP built-in server ของ aptstack เท่านั้น' }
            $risk = Get-PhpRisk $php.Version
            if ($risk) { Write-Warn2 "version นี้ยังไม่ปลอดภัย ($risk) — ใช้เฉพาะทดสอบในเครื่องตัวเอง" }
            Write-Info "เปิดใช้: aptstack use php $($php.Version)"
        }
        'mysql' {
            $src = Get-DownloadedZip $source
            if (Test-Path $src -PathType Container) { throw 'MySQL/MariaDB ต้องเป็นไฟล์ .zip' }
            $leaf = [IO.Path]::GetFileNameWithoutExtension((Split-Path $src -Leaf))
            $name = if ($leaf -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { $leaf }
            $dest = Join-Path $Script:P.MySqlRoot $name
            if (Test-Path $dest) { Write-Warn2 "มีอยู่แล้ว: $dest"; return }
            Write-Head "ติดตั้ง MySQL/MariaDB -> stack\mysql\$name"
            Expand-AndFlatten $src $dest
            Write-Ok "ติดตั้งแล้ว — datadir จะถูกสร้างใหม่ต่อ version (data ไม่ปนกัน)"
        }
        'apache' {
            $src = Get-DownloadedZip $source
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
        Write-Host "   $mark $($a.Name)  $($a.Dir)$flag" -ForegroundColor $(if ($flag) { 'Yellow' } else { 'Gray' })
    }

    $phps = @(Get-PhpVersions)
    Write-Host '  PHP:' -ForegroundColor White
    if ($phps.Count -eq 0) { Write-Warn2 'ยังไม่มี — ใช้: aptstack add php <zip|url>' }
    foreach ($p in $phps) {
        $mark = if ($cfg.php -eq $p.Version) { '*' } else { ' ' }
        $r = Get-PhpRisk $p.Version
        $tag = if ($r -eq 'UNPATCHED') { '  <- ยังไม่ patch ช่องโหว่ RCE' } elseif ($r -eq 'EOL') { '  <- EOL ไม่มี patch' } else { '' }
        Write-Host "   $mark $($p.Version)  $($p.Dir)$tag" -ForegroundColor $(if ($tag) { 'Yellow' } else { 'Gray' })
    }

    $dbs = @(Get-MySqlVersions)
    Write-Host '  Database:' -ForegroundColor White
    if ($dbs.Count -eq 0) { Write-Info '(ยังไม่มี)' }
    foreach ($m in $dbs) { Write-Host "     $($m.Version)  $($m.Dir)" -ForegroundColor Gray }

    $aps = @(Get-ApacheVersions)
    Write-Host '  Apache:' -ForegroundColor White
    if ($aps.Count -eq 0) { Write-Info '(ยังไม่มี) ใช้ได้ด้วย: aptstack add apache <httpd zip>' }
    foreach ($a in $aps) { Write-Host "     $($a.Version)  $($a.Dir)" -ForegroundColor Gray }

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
        elseif ($up) { Write-Warn2 "พอร์ต $($pair[1]) ถูก program อื่นใช้อยู่ (PID $(Get-PortPid $pair[1]))" }
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

    # ถ้ายังไม่มีแอปเลย -> ติดตั้งตัวอย่าง hello-app ให้ (ของจริงอยู่ใน examples\ ไม่ถูก git ignore)
    if (@(Get-AppVersions).Count -eq 0) {
        $ex = Join-Path $Root 'examples\hello-app'
        if (Test-Path $ex) {
            $dest = Join-Path $Script:P.Versions 'hello-1.0.0'
            robocopy $ex $dest /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
            Write-Ok 'ติดตั้งตัวอย่าง app -> versions\hello-1.0.0'
            Write-Info 'ใช้งาน: aptstack start แล้วเปิด http://127.0.0.1:<port>/<appAlias>/'
        }
    }

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
    $countLine = $out | Where-Object { "$_" -match '^\s*\d+\s*$' } | Select-Object -Last 1
    Write-Ok 'import เรียบร้อย (CREATE DATABASE IF NOT EXISTS — ซ้ำได้)'
    if ($countLine) { Write-Info "greetings rows: $("$countLine".Trim())" }
    Write-Info 'เปิดดู:  http://127.0.0.1:<port>/<appAlias>/  แล้วดูตารางด้านล่าง'
}

function Cmd-Help {
    Write-Head 'aptstack — portable PHP / MariaDB / app-version manager'
    @'
  ── ติดตั้งครั้งแรก ───────────────────────────────────
  aptstack init                    เตรียมโครงสร้างโฟลเดอร์
  aptstack add app <folder|zip>    เพิ่มเวอร์ชันแอป -> versions\<name>
  aptstack add php <zip|url>       เพิ่ม PHP        -> stack\php\<ver>
  aptstack list                    ดูที่ติดตั้ง + ที่ใช้อยู่
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
  aptstack add apache <zip>        เพิ่ม Apache -> stack\apache\
  aptstack add mysql <zip>         เพิ่ม MySQL/MariaDB -> stack\mysql\

  ── web / db mode (config\stack.json) ─────────────────
  "webMode":  "auto"|"apache"|"builtin"
  "dbMode":   "internal"|"external"   external = ยืม MySQL ของ XAMPP

  ── เปิด/ปิด ──────────────────────────────────────────
  aptstack start | stop | restart
  aptstack status
  aptstack backup [file.sql]       dump ทุก database ไป data\dumps\
  aptstack seed                    import database ตัวอย่าง (aptstack_demo)
  aptstack logs <apache|mysql|php> ดู log ท้ายไฟล์ (ตัวเลข = กี่บรรทัด, default 50)
  aptstack logs all                ดู log error ทุกตัว

  ── HTTPS / TLS ───────────────────────────────────────
  aptstack tls status               ดูสถานะ + วันหมดอายุ cert
  aptstack tls init [domain,..]     สร้าง self-signed cert (openssl/mkcert) แล้วเปิดให้เลย
  aptstack tls import <c.pem> <k.pem>  ใช้ SSL cert จริง (Let's Encrypt/พาณิชย์)
  aptstack tls off                  ปิด HTTPS

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
switch ($Command.ToLower()) {
    'init'        { Cmd-Init }
    'add'         { Cmd-Add $Action $Value $Extra }
    'list'        { Cmd-List }
    'ls'          { Cmd-List }
    'l'           { Cmd-List }
    'use'         { Cmd-Use $Action $Value }
    'u'           { Cmd-Use $Action $Value }
    'next'        { Step-App 1 }
    'prev'        { Step-App -1 }
    'start'       { Cmd-Start }
    'stop'        { Cmd-Stop }
    'restart'     { Cmd-Restart }
    'status'      { Cmd-Status }
    'doctor'      { Cmd-Doctor }
    'backup'      { Cmd-Backup $Action }
    'seed'        { Cmd-Seed }
    'logs'        { Cmd-Logs $Action $Value }
    'tls'         { Cmd-Tls $Action $Value $Extra }
    'https'       { Cmd-Tls $Action $Value $Extra }
    'service'     { & (Join-Path $Root 'service.ps1') -Action $Action }
    'service-run' { Cmd-ServiceRun }
    'help'        { Cmd-Help }
    default       { Cmd-Help }
}


