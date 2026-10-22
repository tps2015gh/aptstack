#Requires -Version 5.1
<#
.SYNOPSIS
    สร้าง repo (ถ้ายังไม่มี) แล้ว push branch main + tag ขึ้น GitHub
.DESCRIPTION
    ใช้ Personal Access Token (scope: repo) ผ่าน API
    หลัง push เสร็จจะเปลี่ยน remote กลับเป็น https ธรรมดา -> ไม่เก็บ token ไว้ใน .git/config
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\push-github.ps1 -Token "ghp_xxx"
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\push-github.ps1 -Token "ghp_xxx" -RepoName aptstack -Private
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$RepoName = 'aptstack',
    [string]$Description = 'Portable PHP / MariaDB stack for Windows - app version switching + Windows Service',
    [switch]$Private,
    [switch]$SkipRelease
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info($t) { Write-Host "         $t" -ForegroundColor Gray }
function Head($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('  ' + ('-' * 50)) -ForegroundColor DarkGray }
function Err($t)  { Write-Host "  [ERR]  $t" -ForegroundColor Red }

$H = @{
    Authorization           = "token $Token"
    'User-Agent'            = 'aptstack-push'
    'Accept'                = 'application/vnd.github+json'
    'X-GitHub-Api-Version'  = '2022-11-28'
}

function Invoke-Gh($Method, $Uri, $BodyObj) {
    $p = @{ Method = $Method; Uri = $Uri; Headers = $H; ErrorAction = 'Stop' }
    if ($null -ne $BodyObj) {
        $json = $BodyObj | ConvertTo-Json -Depth 6
        $p.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $p.ContentType = 'application/json'
    }
    try { return Invoke-RestMethod @p }
    catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        $msg = $_.Exception.Message
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) { $stream.Position = 0; $reader = New-Object IO.StreamReader($stream); $msg = $reader.ReadToEnd() }
        } catch { }
        throw "HTTP $code on $Method $Uri -> $msg"
    }
}

Head '1) ยืนยันตัวตน'
try {
    $me = Invoke-Gh 'GET' 'https://api.github.com/user'
} catch {
    Err "token ใช้ไม่ได้: $_"
    Err 'ตรวจว่า token มี scope `repo` และยังไม่ถูก revoke'
    exit 1
}
Ok "login = $($me.login)"
$owner = $me.login

Head "2) ตรวจ/สร้าง repo '$RepoName'"
$repo = $null
try { $repo = Invoke-Gh 'GET' "https://api.github.com/repos/$owner/$RepoName" } catch { $repo = $null }

if (-not $repo) {
    Info 'ยังไม่มี -> สร้างใหม่'
    $repo = Invoke-Gh 'POST' 'https://api.github.com/user/repos' @{
        name           = $RepoName
        description    = $Description
        private        = [bool]$Private
        has_issues     = $true
        has_wiki       = $false
        auto_init      = $false
    }
    Ok "สร้างแล้ว: $($repo.html_url)"
} else {
    Ok "มีอยู่แล้ว: $($repo.html_url)"
    if (-not $Private -and $repo.private) {
        Write-Warning 'repo เป็น private อยู่ — ถ้าต้องการ public ให้แก้ใน Settings ของ repo'
    }
}

Head '3) commit ให้หมดก่อน push'
$dirty = & git -C $Root status --porcelain 2>&1
if ($dirty) {
    Err 'ยังมีไฟล์ที่ commit ไม่หมด:'
    $dirty | ForEach-Object { Info "$_" }
    Err 'รัน: git add -A && git commit -m "..."  แล้วสคริปต์ซ้ำ'
    exit 1
}
Ok 'working tree สะอาด'

Head '4) push'
$urlClean = "https://github.com/$owner/$RepoName.git"
$urlAuth  = "https://x-access-token:$Token@github.com/$owner/$RepoName.git"

$hasRemote = & git -C $Root remote | Select-String -Pattern '^origin$' -Quiet
if ($hasRemote) { & git -C $Root remote set-url origin $urlAuth }
else { & git -C $Root remote add origin $urlAuth }

# git เขียน progress ลง stderr -> ถ้า EAP=Stop จะโยน NativeCommandError แล้ว script สะดุด
# ทั้งที่ push สำเร็จ ("Everything up-to-date" ก็เป็น stderr) จึงต้องกด EAP เป็น Continue ชั่วคราว
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& git -C $Root push -u origin HEAD --force-with-lease 2>&1 | ForEach-Object { Info "$_" }
$pushCode = $LASTEXITCODE
& git -C $Root push origin --tags 2>&1 | ForEach-Object { Info "$_" }
$tagCode = $LASTEXITCODE
$ErrorActionPreference = $oldEap
if ($pushCode -ne 0) { Err "push ล้มเหลว (exit $pushCode)"; exit 1 }
Ok 'push branch หลักแล้ว'
if ($tagCode -ne 0) { Write-Warning "push tags exit=$tagCode" } else { Ok 'push tags แล้ว' }

# สำคัญ: เอา token ออกจาก .git/config ทันที
& git -C $Root remote set-url origin $urlClean
Ok 'เปลี่ยน remote กลับเป็น https ธรรมดา (ไม่มี token ค้างใน .git/config)'

Head '5) แนบ release asset (ถ้ามี zip)'
if (-not $SkipRelease) {
    $dist = Join-Path $Root 'dist'
    $zips = @(Get-ChildItem $dist -Filter '*.zip' -ErrorAction SilentlyContinue)
    if ($zips.Count -eq 0) { Info 'ยังไม่มี zip ใน dist\ — ข้าม (รัน tools\make-release.ps1 ก่อน)'; }
    else {
        $tag = (& git -C $Root describe --tags --exact-match 2>$null)
        if (-not $tag) { $tag = (& git -C $Root describe --tags 2>$null) }
        if (-not $tag) { $tag = 'v1.0.0' }
        $rel = $null
        try { $rel = Invoke-Gh 'GET' "https://api.github.com/repos/$owner/$RepoName/releases/tags/$tag" } catch { $rel = $null }
        if (-not $rel) {
            $rel = Invoke-Gh 'POST' "https://api.github.com/repos/$owner/$RepoName/releases" @{
                tag_name         = $tag
                name             = "aptstack $tag"
                body             = 'Portable PHP / MariaDB stack for Windows. ดู README-TH.md สำหรับคู่มือภาษาไทย'
                draft            = $false
                prerelease       = $false
            }
            Ok "สร้าง release: $tag"
        }
        foreach ($z in $zips) {
            $name = $z.Name
            $ctype = 'application/zip'
            $bin = [IO.File]::ReadAllBytes($z.FullName)
            $assetUrl = "https://uploads.github.com/repos/$owner/$RepoName/releases/$($rel.id)/assets?name=$([Uri]::EscapeDataString($name))"
            $r = Invoke-RestMethod -Method Post -Uri $assetUrl -Headers @{ Authorization = "token $Token"; 'User-Agent' = 'aptstack-push' } `
                                   -ContentType $ctype -Body $bin -ErrorAction Stop
            Ok "แนบ asset: $name -> $($r.browser_download_url)"
        }
        $sha = "$($zips[0].FullName).sha256"
        if (Test-Path $sha) { Info "แนบ .sha256 ด้วยถ้าต้องการ (manual)" }
    }
}

Head 'เสร็จแล้ว'
Write-Host "  Repo   : https://github.com/$owner/$RepoName" -ForegroundColor Green
Write-Host "  Clone  : git clone https://github.com/$owner/$RepoName.git" -ForegroundColor Gray
Write-Host ''
Write-Host '  !! ขั้นตอนถัดไปสำคัญ: ไป revoke token ทันที' -ForegroundColor Yellow
Write-Host '     github.com -> Settings -> Developer settings -> Tokens (classic) -> ถังขยะ' -ForegroundColor Yellow
