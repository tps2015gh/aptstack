#Requires -Version 5.1
<#
.SYNOPSIS
  สร้าง diff สำหรับ deploy (copy-paste แบบเลือกไฟล์) ระหว่างสองฝั่ง
  (โฟลเดอร์ หรือ .zip ก็ได้)

.DESCRIPTION
  เทียบ Base (ของเดิม/ต้นทาง) vs Compare (ของใหม่ที่จะ deploy)
  ฝั่งใดฝั่งหนึ่งเป็น .zip ได้ — จะแตก zip ชั่วคราวตอนเทียบแล้วลบทิ้ง

  แล้วสร้างโฟลเดอร์ออกเป็น:
    - manifest.csv        รายการ added/modified/deleted + SHA256
    - report.txt          สรุปอ่านง่าย
    - files\              ไฟล์ที่เปลี่ยน/ใหม่ (โครงสร้างเดียวกับ root)
    - deleted.txt         ไฟล์ที่หายจาก Base (ไม่ลบอัตโนมัติ)
    - apply.ps1           สคริปต์ apply ไปยัง target (copy ไฟล์ที่เปลี่ยน)

  ดู version แอปที่มี: ดูโฟลเดอร์ under versions\ หรือ
  `aptstack list` (app = ที่ใช้อยู่ · from: = ต้นทาง binary)

.EXAMPLE
  # เทียบ zip ต้นฉบับ  vs  โค้ดที่แก้แล้วใน versions\
  .\tools\make-deploy-diff.ps1 `
    -Base    'C:\...\_setup_inet\my-app_20261025_023201.zip' `
    -Compare '.\versions\my-app_20261025_023201' `
    -Out     '.\dist\deploy-diff-lands'

.EXAMPLE
  # เทียบสองโฟลเดอร์ version
  .\tools\make-deploy-diff.ps1 `
    -Base    .\versions\apt052569 `
    -Compare .\versions\my-app_20261025_023201 `
    -Out     .\dist\deploy-diff-lands-auth
#>
[CmdletBinding()]
param(
    [string]$Base = '',

    [string]$Compare = '',

    [string]$Out = '',

    # path บน server ที่ apply.ps1 จะ copy ไปใส่ (ใส่ภายหลังใน apply.ps1 ก็ได้)
    [string]$TargetRoot = '',

    [string[]]$ExcludeDirs = @(
        '.git', 'node_modules', '.mimocode', 'vendor',
        'logs', 'data', 'tmp', 'cache', 'sessions', 'dist'
    ),

    [string[]]$ExcludeExt = @('*.log', '*.tmp', '*.bak', 'Thumbs.db', 'desktop.ini'),

    [Alias('h','?','Help')]
    [switch]$HelpFlag
)

function Show-Usage {
    Write-Host ''
    Write-Host '  make-deploy-diff — สร้าง deploy diff (เทียบ 2 ฝั่ง → copy เฉพาะที่ต่าง)' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'วิธีใช้:' -ForegroundColor Yellow
    Write-Host '  .\tools\make-deploy-diff.ps1 -Base <โฟลเดอร์|zip> -Compare <โฟลเดอร์|zip> [-Out <โฟลเดอร์>]'
    Write-Host '  .\tools\make-deploy-diff.ps1 -Help'
    Write-Host ''
    Write-Host 'พารามิเตอร์:' -ForegroundColor Yellow
    Write-Host '  -Base      (บังคับ) ของเดิม / ต้นทาง — folder หรือ .zip'
    Write-Host '  -Compare   (บังคับ) ของใหม่ที่จะ deploy — folder หรือ .zip'
    Write-Host '  -Out       โฟลเดอร์ผลลัพธ์ (ถ้าไม่ใส่ = dist\deploy-diff-<เวลา>)'
    Write-Host '  -ExcludeDirs โฟลเดอร์ที่ข้าม (ค่าเริ่ม: .git,node_modules,logs,data,...)'
    Write-Host '  -Help      แสดงวิธีใช้นี้แล้วจบ'
    Write-Host ''
    Write-Host 'ตัวอย่าง:' -ForegroundColor Yellow
    Write-Host '  # เทียบ zip ต้นฉบับ vs โค้ดที่แก้ใน versions\'
    Write-Host "  .\tools\make-deploy-diff.ps1 ``"
    Write-Host "    -Base    'C:\...\_setup_inet\my-app_20261025_023201.zip' ``"
    Write-Host "    -Compare '.\versions\my-app_20261025_023201' ``"
    Write-Host "    -Out     '.\dist\deploy-diff-lands'"
    Write-Host ''
    Write-Host '  # เทียบสองโฟลเดอร์ version'
    Write-Host "  .\tools\make-deploy-diff.ps1 -Base .\versions\OLD -Compare .\versions\NEW"
    Write-Host ''
    Write-Host 'ผลลัพธ์ใน -Out:' -ForegroundColor Yellow
    Write-Host '  manifest.csv  report.txt  files\  deleted.txt  apply.ps1'
    Write-Host '  deploy บน target:  powershell -File apply.ps1 -Target <root>'
    Write-Host ''
    Write-Host 'ดู version แอป: โฟลเดอร์ใน versions\ · aptstack list' -ForegroundColor DarkGray
    Write-Host ''
}

if ($HelpFlag -or [string]::IsNullOrWhiteSpace($Base) -or [string]::IsNullOrWhiteSpace($Compare)) {
    if ($HelpFlag) {
        Write-Host ''
        Write-Host '  ความช่วยเหลือ (-Help / ไม่ได้ป้อน param)' -ForegroundColor Gray
    } else {
        Write-Host ''
        Write-Host '  [ต้องการ param] ยังไม่ได้ป้อน -Base และ/หรือ -Compare' -ForegroundColor Yellow
    }
    Show-Usage
    exit 0
}

$ErrorActionPreference = 'Stop'
$script:TempZips = @()

function Resolve-Input([string]$p, [string]$label) {
    if (-not $p) { throw "$label ว่าง" }
    $rp = Resolve-Path $p -ErrorAction SilentlyContinue
    if (-not $rp) { throw "ไม่พบ path $label : $p" }
    $full = $rp.Path
    if (Test-Path $full -PathType Leaf) {
        if ($full -notmatch '\.zip$') { throw "$label ต้องเป็นโฟลเดอร์หรือ .zip : $p" }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('aptstack-dd-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Write-Host "  แตก zip ชั่วคราว: $(Split-Path $full -Leaf) -> $tmp" -ForegroundColor DarkGray
        [IO.Compression.ZipFile]::ExtractToDirectory($full, $tmp)
        $script:TempZips += $tmp
        # ถ้า zip มีโฟลเดอร์เดียวห่อ (เช่น app/) ใช้ชั้นในเป็น root
        $entries = @(Get-ChildItem $tmp -Force)
        if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
            return $entries[0].FullName.TrimEnd('\')
        }
        return $tmp.TrimEnd('\')
    }
    if (-not (Test-Path $full -PathType Container)) {
        throw "$label ไม่ใช่โฟลเดอร์หรือไฟล์: $p"
    }
    return $full.TrimEnd('\')
}

$BaseDir     = Resolve-Input $Base     'Base'
$CompareDir  = Resolve-Input $Compare  'Compare'

if ($BaseDir.TrimEnd('\') -ieq $CompareDir.TrimEnd('\')) {
    throw 'Base และ Compare เป็น path เดียวกัน'
}

if (-not $Out) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Out = Join-Path (Get-Location) ("dist\deploy-diff-$stamp")
}
$OutFull = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Path $OutFull -Force | Out-Null
$filesOut = Join-Path $OutFull 'files'
New-Item -ItemType Directory -Path $filesOut -Force | Out-Null

Write-Host ''
Write-Host '  make-deploy-diff' -ForegroundColor Cyan
Write-Host "  Base    : $BaseDir"
Write-Host "  Compare : $CompareDir"
Write-Host "  Out     : $OutFull"
Write-Host ''

function Should-ExcludeDir([string]$name) {
    foreach ($e in $ExcludeDirs) {
        if ($name -ieq $e) { return $true }
    }
    return $false
}

function Should-ExcludeFile([string]$name) {
    foreach ($e in $ExcludeExt) {
        if ($name -like $e) { return $true }
    }
    return $false
}

function Get-RelMap([string]$root, [string[]]$exDirs, [string[]]$exExt) {
    $map = @{}
    $stack = [System.Collections.Stack]::new()
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($f in [IO.Directory]::GetFiles($dir)) {
            $name = [IO.Path]::GetFileName($f)
            if (Should-ExcludeFile $name) { continue }
            $rel = $f.Substring($root.Length).TrimStart('\', '/')
            $map[$rel] = $f
        }
        foreach ($d in [IO.Directory]::GetDirectories($dir)) {
            $dn = [IO.Path]::GetFileName($d)
            if (Should-ExcludeDir $dn) { continue }
            $stack.Push($d)
        }
    }
    return $map
}

function Get-Sha($path) {
    if ([string]::IsNullOrEmpty("$path")) { return 'ERR' }
    if (-not (Test-Path -LiteralPath "$path")) { return 'ERR' }
    try { return (Get-FileHash -LiteralPath "$path" -Algorithm SHA256).Hash }
    catch { return 'ERR' }
}

Write-Host '  สแกนไฟล์…' -ForegroundColor DarkGray
$mapA = Get-RelMap $BaseDir
$mapB = Get-RelMap $CompareDir
Write-Host "  Base=$($mapA.Count)  Compare=$($mapB.Count)" -ForegroundColor DarkGray

$rows = [System.Collections.Generic.List[object]]::new()
$added = 0; $modified = 0; $deleted = 0; $same = 0

foreach ($rel in ($mapB.Keys | Sort-Object)) {
    $pathB = $mapB[$rel]
    $hashB = Get-Sha $pathB
    if (-not $mapA.ContainsKey($rel)) {
        $status = 'added'
        $added++
        $dest = Join-Path $filesOut $rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Copy-Item $pathB $dest -Force
    } else {
        $pathA = $mapA[$rel]
        $hashA = Get-Sha $pathA
        if ($hashA -eq $hashB) {
            $status = 'same'
            $same++
        } else {
            $status = 'modified'
            $modified++
            $dest = Join-Path $filesOut $rel
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
            Copy-Item $pathB $dest -Force
        }
    }
    $sizeB = 0
    try { $sizeB = (Get-Item $pathB).Length } catch { }
    $sizeA = 0
    $hashA = ''
    if ($mapA.ContainsKey($rel)) {
        try { $sizeA = (Get-Item $mapA[$rel]).Length } catch { }
        $hashA = Get-Sha $mapA[$rel]
    }
    $relWin = $rel.Replace([string]'/', [string]'\')
    $rows.Add([pscustomobject]@{
        Status = $status
        Path   = $relWin
        SizeA  = $sizeA
        SizeB  = $sizeB
        HashA  = $hashA
        HashB  = $hashB
    })
}

$deletedList = @()
foreach ($rel in ($mapA.Keys | Sort-Object)) {
    if (-not $mapB.ContainsKey($rel)) {
        $deleted++
        $relWin = $rel.Replace([string]'/', [string]'\')
        $deletedList += $relWin
        $sizeA = 0
        try { $sizeA = (Get-Item $mapA[$rel]).Length } catch { }
        $rows.Add([pscustomobject]@{
            Status = 'deleted'
            Path   = $relWin
            SizeA  = $sizeA
            SizeB  = 0
            HashA  = Get-Sha $mapA[$rel]
            HashB  = ''
        })
    }
}

# manifest
$csvPath = Join-Path $OutFull 'manifest.csv'
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# deleted list
$delPath = Join-Path $OutFull 'deleted.txt'
$deletedList | Set-Content -Path $delPath -Encoding UTF8

# report
$changes = @($rows | Where-Object { $_.Status -ne 'same' })
$report = @"
deploy-diff report
generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
base:     $BaseDir
compare:  $CompareDir

summary:
  added:    $added
  modified: $modified
  deleted:  $deleted
  unchanged(same): $same
  change total: $($changes.Count)

files payload: files\   (added+modified only)
manifest:      manifest.csv
deleted:       deleted.txt   (list only — ไม่ลบอัตโนมัติ)
apply script:  apply.ps1

how to deploy on target:
  1) copy โฟลเดอร์ output ทั้งชุดไปเครื่อง target (flash/network)
  2) บน target: powershell -ExecutionPolicy Bypass -File apply.ps1 -Target 'C:\path\to\app-root'
  3) ตรวจ manifest.csv / deleted.txt แล้วค่อย restart service/app

"@
$report | Set-Content -Path (Join-Path $OutFull 'report.txt') -Encoding UTF8

# apply.ps1
$apply = @"
#Requires -Version 5.1
# apply deploy-diff -> target root (สร้างจาก make-deploy-diff)
param(
    [Parameter(Mandatory=`$true)]
    [string]`$Target,
    [switch]`$WhatIf
)
`$ErrorActionPreference = 'Stop'
`$srcRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$filesRoot = Join-Path `$srcRoot 'files'
if (-not (Test-Path `$Target)) { throw "ไม่พบ target: `$Target" }
if (-not (Test-Path `$filesRoot)) { throw "ไม่พบ files\: `$filesRoot" }

`$items = Get-ChildItem `$filesRoot -Recurse -File
`$n = 0
foreach (`$f in `$items) {
    `$rel = `$f.FullName.Substring(`$filesRoot.Length).TrimStart('\','/')
    `$dst = Join-Path `$Target `$rel
    `$dir = Split-Path `$dst -Parent
    if (-not (Test-Path `$dir)) {
        if (`$WhatIf) { Write-Host "[WhatIf] mkdir `$dir" }
        else { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
    }
    if (`$WhatIf) { Write-Host "[WhatIf] copy `$rel" }
    else { Copy-Item `$f.FullName `$dst -Force }
    `$n++
}
Write-Host "apply done: `$n file(s) -> `$Target"
Write-Host "review deleted.txt ก่อนลบเองถ้าจำเป็น"
Write-Host "แล้ว restart web/app ให้พอดี"
"@
Set-Content -Path (Join-Path $OutFull 'apply.ps1') -Value $apply -Encoding UTF8

# ---- HTML report (deploy-diff) ----
$baseLeaf = Split-Path $BaseDir -Leaf
if (-not $baseLeaf) { $baseLeaf = $BaseDir }
$cmpLeaf = Split-Path $CompareDir -Leaf
if (-not $cmpLeaf) { $cmpLeaf = $CompareDir }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$htmlName = "deploy-diff-$($baseLeaf)_vs_$($cmpLeaf)_$stamp"
$htmlName = ($htmlName -replace '[^\w\.-]+', '_')

function HtmlEnc([string]$s) {
    if ($null -eq $s) { return '' }
    return [Net.WebUtility]::HtmlEncode($s)
}

$changeRows = @($rows | Where-Object { $_.Status -ne 'same' } | Select-Object -First 300)
$trHtml = ''
foreach ($r in $changeRows) {
    $badge = switch ($r.Status) {
        'added'    { '<span class="badge add">added</span>' }
        'modified' { '<span class="badge mod">modified</span>' }
        'deleted'  { '<span class="badge del">deleted</span>' }
        default    { '<span class="badge">' + (HtmlEnc $r.Status) + '</span>' }
    }
    $trHtml += "<tr><td>$badge</td><td class='path'>" + (HtmlEnc $r.Path) + "</td>" +
        "<td class='num'>$($r.SizeA)</td><td class='num'>$($r.SizeB)</td>" +
        "<td class='hash'>" + (HtmlEnc $r.HashB) + "</td></tr>"
}
$truncNote = ''
if ($changes.Count -gt 300) {
    $truncNote = "<p class='warn'>แสดง 300 แถวแรกจาก $($changes.Count) — รายละเอียดเต็มดู manifest.csv</p>"
}
if ($deletedList.Count -gt 0) {
    $delHtml = '<ul>' + (($deletedList | Select-Object -First 50 | ForEach-Object { '<li>' + (HtmlEnc $_) + '</li>' }) -join '') + '</ul>'
    if ($deletedList.Count -gt 50) { $delHtml += '<p class="hint">… รวม ' + $deletedList.Count + ' ไฟล์</p>' }
} else {
    $delHtml = '<p class="hint">ไม่มีไฟล์ถูกลบ (deleted = 0)</p>'
}

$htmlReport = @"
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Deploy diff — $(HtmlEnc $baseLeaf) vs $(HtmlEnc $cmpLeaf)</title>
<style>
  body { font-family: "Sarabun","TH Sarabun New",Tahoma,sans-serif; margin:0; background:#f4f6f8; color:#222; }
  .wrap { max-width:1100px; margin:0 auto; padding:20px; }
  h1 { font-size:20px; margin:0 0 6px; }
  .meta { color:#666; font-size:13px; margin-bottom:14px; }
  .card { background:#fff; border-radius:6px; padding:14px 16px; margin-bottom:14px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
  h2 { font-size:16px; margin:0 0 8px; border-left:4px solid #c62828; padding-left:8px; }
  .stats { display:flex; flex-wrap:wrap; gap:10px; }
  .stat { min-width:100px; padding:10px 14px; border-radius:6px; color:#fff; text-align:center; }
  .stat .n { font-size:22px; font-weight:700; display:block; }
  .stat .l { font-size:12px; opacity:.9; }
  .s-add { background:#2e7d32; } .s-mod { background:#ef6c00; }
  .s-del { background:#c62828; } .s-same { background:#607d8b; }
  table { width:100%; border-collapse:collapse; font-size:12px; }
  th,td { border:1px solid #ddd; padding:6px 8px; text-align:left; }
  th { background:#1a4e8a; color:#fff; }
  tr:nth-child(even) td { background:#f8fafc; }
  .path { font-family:Consolas,monospace; font-size:11px; word-break:break-all; }
  .num { text-align:right; font-family:Consolas,monospace; }
  .hash { font-family:Consolas,monospace; font-size:10px; color:#888; word-break:break-all; }
  .badge { display:inline-block; padding:1px 7px; border-radius:3px; font-size:11px; color:#fff; font-weight:600; }
  .badge.add { background:#2e7d32; } .badge.mod { background:#ef6c00; } .badge.del { background:#c62828; }
  .cmd { background:#eee; padding:2px 5px; font-family:Consolas,monospace; font-size:11px; }
  .warn { color:#b71c1c; font-size:12px; }
  .hint { color:#888; font-size:12px; }
  .foot { color:#888; font-size:12px; text-align:center; margin-top:16px; }
  code { background:#eee; padding:0 4px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>Deploy diff report</h1>
  <div class="meta">
    generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')<br>
    <strong>Base</strong> (ต้นทาง/ของเดิม): <code>$(HtmlEnc $BaseDir)</code><br>
    <strong>Compare</strong> (ของใหม่): <code>$(HtmlEnc $CompareDir)</code><br>
    payload: <code>$(HtmlEnc $OutFull)</code>
  </div>

  <div class="card">
    <h2>สรุป</h2>
    <div class="stats">
      <div class="stat s-add"><span class="n">$added</span><span class="l">added</span></div>
      <div class="stat s-mod"><span class="n">$modified</span><span class="l">modified</span></div>
      <div class="stat s-del"><span class="n">$deleted</span><span class="l">deleted</span></div>
      <div class="stat s-same"><span class="n">$same</span><span class="l">unchanged</span></div>
    </div>
    <p style="margin:10px 0 0;">รวมเปลี่ยนแปลง: <strong>$($changes.Count)</strong> ไฟล์</p>
  </div>

  <div class="card">
    <h2>Deploy บน target</h2>
    <ol style="margin:6px 0;padding-left:22px;">
      <li>copy โฟลเดอร์ <code class="cmd">$(HtmlEnc $OutFull)</code> ทั้งชุดไปเครื่อง target</li>
      <li>รัน: <code class="cmd">powershell -ExecutionPolicy Bypass -File apply.ps1 -Target 'C:\path\to\app-root'</code></li>
      <li>ตรวจไฟล์ด้านล่าง / <code>manifest.csv</code> แล้ว restart web/app</li>
    </ol>
  </div>

  <div class="card">
    <h2>ไฟล์ที่เพิ่ม/เปลี่ยน (สูงสุด 300 รายการ)</h2>
    $truncNote
    <table>
      <thead><tr><th style="width:12%;">สถานะ</th><th>Path</th><th style="width:10%;">Size Base</th><th style="width:10%;">Size New</th><th style="width:28%;">SHA256 (new)</th></tr></thead>
      <tbody>
      $trHtml
      </tbody>
    </table>
  </div>

  <div class="card">
    <h2>ไฟล์ที่หายจาก Base (deleted — ไม่ลบอัตโนมัติ)</h2>
    $delHtml
  </div>

  <div class="foot">
    make-deploy-diff.ps1 · ดูรายงานอื่น ๆ ใน <code>report_html\</code>
  </div>
</div>
</body>
</html>
"@

$htmlInOut = Join-Path $OutFull 'report.html'
Set-Content -Path $htmlInOut -Value $htmlReport -Encoding UTF8

# copy เข้า report_html\ ด้วย (bundle root = parent ของ tools\)
$bundleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (Test-Path (Join-Path $bundleRoot 'report_html')) {
    $reportHtmlDir = Join-Path $bundleRoot 'report_html'
} else {
    $reportHtmlDir = Join-Path $bundleRoot 'report_html'
}
New-Item -ItemType Directory -Path $reportHtmlDir -Force | Out-Null
$htmlInReport = Join-Path $reportHtmlDir ($htmlName + '.html')
Copy-Item $htmlInOut $htmlInReport -Force

# สร้าง index.html ใน report_html (รายการรายงาน)
$lineageLink = 'app-lineage.html'
$existing = @(Get-ChildItem $reportHtmlDir -Filter '*.html' -File | Where-Object { $_.Name -ne 'index.html' } | Sort-Object LastWriteTime -Descending)
$idx = "<!DOCTYPE html>`n<html lang=`"th`"><head><meta charset=`"utf-8`"><title>report_html</title>"
$idx += "`n<style>body{font-family:sans-serif;padding:20px;max-width:800px;margin:0 auto;} li{margin:6px 0;} .m{color:#666;font-size:12px;}</style></head><body>"
$idx += "`n<h1>รายงาน aptstack</h1><p class=`"m`">generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p><ul>"
foreach ($f in $existing) {
    $idx += "`n<li><a href=`"$($f.Name)`">$($f.Name)</a> <span class=`"m`">($([math]::Round($f.Length/1KB,1)) KB · $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))</span></li>"
}
$idx += "`n</ul><p class=`"m`">tools: show-app-lineage.ps1 · make-deploy-diff.ps1</p></body></html>"
Set-Content -Path (Join-Path $reportHtmlDir 'index.html') -Value $idx -Encoding UTF8

Write-Host '  OK' -ForegroundColor Green
Write-Host "  added=$added  modified=$modified  deleted=$deleted  same=$same"
Write-Host "  out : $OutFull"
Write-Host "  html: $htmlInOut"
Write-Host "  report_html: $htmlInReport"
Write-Host ''
Get-ChildItem $OutFull | Select-Object Name, Length | Format-Table -AutoSize

# ล้าง temp ที่แตกจาก zip
foreach ($t in $script:TempZips) {
    Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
