# ai.md — คู่มือสำหรับ AI agent ที่จะมาช่วยงาน repo นี้

> อ่านไฟล์นี้ก่อนแก้อะไรก็ตาม · เอกสารคน: [README-TH.md](README-TH.md) ·
> [concept.md](concept.md) (สถาปัตยกรรม) · [soul.md](soul.md) (เจตนารมณ์)

---

## 1. นี่คืออะไร

`aptstack` = portable stack สำหรับ Windows: **PHP + MariaDB + จัดการเวอร์ชันแอป**
อยู่โฟลเดอร์เดียว copy ไป server ได้ ติดตั้ง Windows Service ได้ สลับเวอร์ชันได้
ภาษาหลัก: **PowerShell 5.1** (ไม่ใช่ PS7) + HTML/CSS สำหรับ docs

## 2. โครงสร้าง (อะไรอยู่ไหน)

| พาธ | บทบาท | commit? |
|---|---|---|
| `aptstack.ps1` | **logic ทั้งหมด** (~2,500 บรรทัด) — เพิ่มคำสั่งที่นี่ | ✅ |
| `aptstack.cmd` / `as.cmd` | ตัวห่อ `-ExecutionPolicy Bypass` | ✅ |
| `setup.ps1` / `service.ps1` | wizard / ติดตั้ง Windows Service | ✅ |
| `service\AptStackService.cs` | source ของ service host (compile ด้วย csc.exe) | ✅ |
| `templates\` | ต้นฉบับ config ที่ generate ใหม่เสมอ | ✅ |
| `examples\` | ตัวอย่าง 3 แอป + `seed.sql` + `vhosts.sample.json` | ✅ |
| `docs\` | คู่มือทั้งหมด | ✅ |
| `stack\`, `versions\`, `config\`, `data\`, `logs\`, `downloads\`, `bin\`, `dist\` | runtime/ข้อมูลจริง | ❌ **ห้าม commit** |

## 3. กฎเหล็ก (ฝ่าแล้วพังจริง)

1. **`.ps1` ต้องมี UTF-8 BOM** — PS5.1 อ่านเป็น ANSI ถ้าไม่มี BOM → ภาษาไทยพังทันที
   หลังแก้ไฟล์ด้วยเครื่องมือทุกครั้ง ต้อง re-add BOM:
   ```powershell
   $b=[IO.File]::ReadAllBytes($p); if(-not($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)){
     $n=New-Object byte[] ($b.Length+3); $n[0]=0xEF;$n[1]=0xBB;$n[2]=0xBF;
     [Array]::Copy($b,0,$n,3,$b.Length); [IO.File]::WriteAllBytes($p,$n) }
   ```
2. **`.cmd`/`.bat` ต้องเป็น CRLF** — LF อย่างเดียวทำให้ cmd.exe พิมพ์ `'-' is not recognized`
3. **เขียนไฟล์ config/ini ด้วย UTF-8 ไม่มี BOM** (`Write-Utf8NoBom`) —
   MariaDB อ่าน `my.ini` ไม่ออกถ้ามี BOM, PHP `json_decode()` คืน null ถ้า config มี BOM
4. **PS5.1 ไม่มี `??` / ไม่มี `.Count` บน object เดียว** → ใช้ `@(Get-Xxx)` เสมอ
   (บั๊คจริงที่เคยเจอ: `Resolve-Apache` คืน null เมื่อมี Apache ตัวเดียว)
5. **native program (git/httpd/openssl/mariadb) เขียน stderr** → ถ้า `$ErrorActionPreference='Stop'`
   จะโยน `NativeCommandError` → ต้อง wrap ด้วย `EAP='Continue'` ชั่วคราว
6. **อย่า pipe string เข้า process ไทย** (`Get-Content | mysql`) → โดน encode ตาม codepage
   เป็น `???` → ใช้ `Start-Process -RedirectStandardInput <file>`
7. **ชื่อระบบจริง** (`app`, URL ระบบงาน) ห้ามอยู่ในไฟล์ที่ track — default alias คือ `app`

## 4. เพิ่มคำสั่งใหม่ (checklist)

1. เขียน `function Cmd-Xxx(...)` ใน `aptstack.ps1` (วางก่อน `function Cmd-Help`)
2. เพิ่ม case ใน `switch ($Command.ToLower())`
3. เพิ่มบรรทัดใน `Cmd-Help` (Here-string)
4. Syntax check + **re-add BOM**
   ```powershell
   $errs=$null;$tok=$null
   [System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$errs)
   ```
5. รันทดสอบจริง: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\aptstack.ps1 <cmd>`
6. ห้ามเรียก `.ps1` ตรง ๆ ผ่าน `.\` (ExecutionPolicy) — ใช้ `.cmd` หรือ `powershell -File`
7. อัปเดต: `docs/คู่มือ.md` + `.html` + `README-TH.md` + `README.md` + `CHANGELOG.md`

## 5. แพตเทิร์นที่ใช้ประจำ

```powershell
Write-Head / Write-Ok / Write-Warn2 / Write-Err2 / Write-Info   # output สี
Resolve-Php / Resolve-Apache / Resolve-MySql / Resolve-App      # resolve + prefix match
Get-Config / Save-Config                                        # config\stack.json
Ensure-Dirs                                                     # สร้างโฟลเดอร์ที่ขาด
Wait-Healthy / Invoke-HttpProbe                                 # health probe จริง
Confirm-Action $prompt 'y'                                      # ยืนยันก่อนทำลาย
Guard-Name $name                                                # กัน path traversal
Set-SourceMeta / Get-SourceMeta                                 # บันทึกที่มาของ binary
Write-Utf8NoBom                                                 # เขียนไฟล์ UTF8 ไม่มี BOM
```

## 6. dispatch ปัจจุบัน

`init · add · list/ls/l · use/u · next · prev · php · mysql · apache · start · stop ·
restart · status · doctor · backup · seed · samples · report · logs · tls/https ·
clone · remove/rm · migrate · service · service-run · help/h/-h/--help`

## 7. ข้อควรระวังด้านความปลอดภัย

- `doctor` ต้องผ่าน (`[ERR]` = ยังไม่พร้อมขึ้น server) — อ้างอิง `security-php.txt` + `security-php2.txt`
- PHP ต้อง ≥ 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 · **8.1 = EOL**
- `.gitignore` กัน `stack/ versions/ data/ config/ *.sql` — **อย่าขยาย allowlist** นอกจาก `examples/`
- command ที่ลบของจริงต้องมี `Confirm-Action` + guard path อยู่ใน root ของตัวเองเสมอ

## 8. ทดสอบอย่างไร

```powershell
# syntax
[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tok,[ref]$errs)

# รันจริง (ทุกคำสั่ง)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\aptstack.ps1 doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\aptstack.ps1 start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\aptstack.ps1 report

# HTTP probe
Invoke-WebRequest http://127.0.0.1:8077/app/ -UseBasicParsing
```

**อย่า** commit `data\` (ข้อมูลจริง), `stack\` (binary), หรือไฟล์ที่มีชื่อระบบจริง
ก่อน commit รัน: `git status --short` + ตรวจ grep `app` = 0 ผล

## 9. เอกสารอื่นที่ต้อง sync เมื่อเปลี่ยนพฤติกรรม

`docs/คู่มือ.md` ↔ `docs/คู่มือ.html` (คู่กัน) · `README-TH.md` ↔ `README.md` ·
`CHANGELOG.md` (เพิ่มหัวข้อใหม่) · `docs/SCENARIO.md` (walkthrough) ·
`docs/OFFLINE-DEPLOY.md` (offline) · `SECURITY.md` (ความปลอดภัย)
