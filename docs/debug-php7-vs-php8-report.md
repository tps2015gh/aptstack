# aptstack Debug Report — PHP 7 mod_php vs PHP 8, TS/NTS, MariaDB install, Vulnerability Audit

> **วันที่:** 25 ต.ค. 2026 · **เวอร์ชัน:** 1.3.4 (test copy) → 1.3.5 (source)
> **เครื่องทดสอบ:** `C:\NoteBook1\2569-10-23-TryUse-AppStack\aptstack-1.3.4`
> **โปรเจกต์ต้นทาง:** `C:\NoteBook1\2569-10-22-create-XAMPP-Laragon-clone\aptstack`
> **ฉบับ HTML:** [debug-php7-vs-php8-report.html](debug-php7-vs-php8-report.html)

## ภาพรวมสถานะ

| # | ปัญหา | สถานะ | Root cause / ข้อสรุป |
|---|--------|-------|----------------------|
| 1 | TS จริง แต่ aptstack แจ้งเป็น NTS | ✅ แก้แล้ว (source) | โค้ด 1.3.4 เช็คเฉพาะ `php8apache2_4.dll` → PHP 7.4 TS ถูกตีเป็น NTS |
| 2 | ติดตั้ง `mariadb-10.4.8` ค้างกลางคัน | ⏳ รอแก้ | `Expand-AndFlatten` ย้ายไฟล์ติดล็อกชั่วคราว → dest ครึ่งๆกลางๆ แล้วโดน "มีอยู่แล้ว" รอบถัดไป |
| 3 | `httpd -t` เมินโมดูล PHP 7.4 แต่ยอม PHP 8.3 | 🔴 กำลังสืบ | dll ของจริง/สมบูรณ์ โหลดผ่านใน process ธรรมดา แต่ล้มเหลวเฉพาะใน `httpd.exe` |
| 4 | setup/URL ไม่แยก PHP 7 กับ PHP 8 | ⏳ รอแก้ | `Get-OfficialUrls` hardcode `Win32-vs16-x64` (ชื่อยุค PHP 8) — PHP 7.4 ของจริงคือ `Win32-vc15-x64` |
| 5 | ช่องโหว่/ความเสี่ยงใน stack | ⚠️ ดู §6 | PHP EOL 2 ตัว (ตัว active เป็น 8.1.25), MariaDB 10.4.8 เก่า, phpMyAdmin config-auth เปิด LAN ได้ |

---

## 1. Apache ที่ใช้โฟกัส

```
stack\apache\httpd-2.4.69\Apache24\bin\httpd.exe
  FileVersion  : 2.4.69
  ProductName  : Apache HTTP Server
  รายละเอียด log: Apache Lounge VS18 Server built: Oct 1 2026 — Win64, OpenSSL/3.5.9
  โครงสร้าง     : httpd.exe + libhttpd.dll + libapr-1.dll + libaprutil-1.dll (อยู่ใน bin\)
  คอนฟิก       : config\httpd.conf (LoadModule php_module ที่บรรทัด 37)
```

การทดสอบทั้งหมดใน §4 ใช้ตัวนี้ตัวเดียวกันทุกครั้ง — ไม่มีการสลับ Apache อื่นเข้ามาเกี่ยว

---

## 2. ปัญหา TS/NTS — ปิดเคสแล้ว

### อาการ

```
.\aptstack.cmd add php ..\php-7.4.33-Win32-vc15-x64.zip
[OK]  ติดตั้ง PHP 7.4.33 เรียบร้อย
      NTS build — ใช้ได้กับ PHP built-in server ของ aptstack เท่านั้น   ← ทั้งที่ไฟล์เป็น TS
```

### Root cause

เทียบไบต์ต่อไบต์ระหว่าง `dist\aptstack-1.3.4.zip` (ของที่รันจริง) กับ working copy:

```powershell
# dist 1.3.4 (ของเดิม) — เช็ค "php8..." เท่านั้น ทุกจุด
225:  ApacheMod = (Test-Path (Join-Path $d.FullName 'php8apache2_4.dll'))
924:  if (-not (Test-Path (Join-Path $php.Dir 'php8apache2_4.dll'))) { ... "เป็น NTS" ... }

# working copy / โค้ดที่แก้แล้ว (1.3.5)
212:  $hit = @(Get-ChildItem -Path $Dir -Filter 'php*apache2_4.dll' -File ...)
      # PHP 8 = php8apache2_4.dll · PHP 7 = php7apache2_4.dll · PHP 5 = php5apache2_4.dll
```

สัญลักษณ์ mod_php ของ PHP 7 คือ `php7apache2_4.dll` — โค้ดเดิมมองไม่เห็น → สรุปผิดว่า NTS ทันที แล้วบล็อกการใช้ Apache mod_php ทั้งที่ใช้ได้

### หลักฐานสนับสนุน

| รายการ | ผล |
|--------|-----|
| `php-7.4.33-ts-Win32-vc15-x64.zip` (user rename) | มี `php7apache2_4.dll` ✓ |
| `php-7.4.33-nts-Win32-vc15-x64.zip` | ไม่มี apache dll ✓ (NTS จริง) |
| `stack\php\7.4.33\php7apache2_4.dll` SHA256 | ตรงกับ official windows.php.net ทุกไบต์ (`6241A38C…B0D288`) |
| `php -v` | `ZTS Visual C++ 2017 x64` — TS จริง |

### ข้อควรรู้

- การตัดสิน TS/NTS ของ aptstack ใช้**เนื้อไฟล์** (มี `php*apache2_4.dll` ไหม) ซึ่งเชื่อถือได้กว่าชื่อไฟล์ — ชื่อ zip อย่าง `php-7.4.33-Win32-vc15-x64.zip` ของ windows.php.net "ไม่มี nts = TS" จริง แต่ถ้าไฟล์ถูก rename มา ชื่อก็ไม่บอกอะไร
- โค้ดที่แก้แล้วอยู่ที่ working copy + test copy (identical, MD5 `9B79AC42…` 262062 bytes) — **`dist\aptstack-1.3.5.zip` ยังเป็นโค้ดเก่า (php8-only) ต้อง build ใหม่ก่อนแจก**

---

## 3. ปัญหา MariaDB 10.4.8 ติดตั้งค้าง

### เหตุการณ์

```
ดาวน์โหลด https://archive.mariadb.org/mariadb-10.4.8/winx64-packages/mariadb-10.4.8-winx64.zip
[OK] บันทึกไว้: ...\downloads\mariadb-10.4.8-winx64.zip
ติดตั้ง MySQL/MariaDB -> stack\mysql\10.4.8
Move-Item : Cannot remove item ...\stack\mysql\10.4.8\mariadb-10.4.8-winx64\share\russian:
            The process cannot access the file ... because it is being used by another process.
  At aptstack.ps1:1411  Get-ChildItem $inner -Force | Move-Item -Destination $dest -Force
```

### กลไกที่พัง (`Expand-AndFlatten`)

```
Expand-Archive zip -> dest
  dest = { mariadb-10.4.8-winx64 }          # inner folder เดียว
  flatten: ย้ายลูก inner ขึ้น dest ทีละตัว
    Move-Item ถ้าชน/ล็อก -> Windows แก้ด้วย copy แล้วค่อยลบ source
    ลบ source ติดล็อกที่ share\russian       # ล็อกชั่วคราว (AV/scan)
    -> pipeline หยุดกลางทาง -> dest ครึ่งๆกลางๆ
```

### สภาพที่ค้างอยู่จริง (inspection)

```
stack\mysql\10.4.8\
├─ bin\  data\  include\  lib\  share\        # ย้ายขึ้นมาได้บางส่วน (share ไม่สมบูรณ์)
└─ mariadb-10.4.8-winx64\                    # inner เหลือค้าง
   └─ share\, COPYING, CREDITS, README.md ... # ย้ายไม่หมดเพราะค้างที่ share\russian
─ .aptstack-source   # ไม่มี -> Set-SourceMeta (ขั้นสุดท้าย) ยังไม่ถูกเรียก = ติดตั้งไม่เสร็จ
─ bin\mysqld.exe     # มี (ย้ายก่อน) แต่ share\errmsg.sys ยังไม่มี
```

> **Dead-end ที่สอง:** รอบถัดไปของ `add mysql 10.4.8` เจอ `Test-Path $dest` → ตอบ "มีอยู่แล้ว" แล้วจบ — ผู้ใช้ซ่อมด้วยคำสั่ง add ไม่ได้ (ต้อง `rm mysql 10.4.8` ก่อน ถึงจะ add ใหม่ได้)

### งานที่ต้องแก้ (backlog)

1. `Expand-AndFlatten` — แตกไฟล์ลง temp แล้ว flatten ใน temp (ไม่ชนของเดิม) + retry/robocopy fallback รายไฟล์ + ข้อความไทยบอกชื่อไฟล์ที่ล็อกชัดเจน ห้ามค้าง dest ครึ่งๆกลางๆ
2. ทางซ่อม — ถ้า dest มีอยู่แต่**ยังไม่จบ** (ไม่มี `.aptstack-source`) → ให้ re-add ทับได้ (แจ้งเตือนก่อน) แทนคำว่า "มีอยู่แล้ว"
3. Alias — `aptstack add mariadb <ver>` = mysql (ตอนนี้ `Normalize-PmaKind` รับแค่ pma/phpmyadmin)
4. เมนู interactive — เพิ่มหัวข้อ `[MariaDB]` ใน `Select-Interactive` (ตอนนี้มีแค่ [แอป] กับ [PHP]) เลือกแล้วเรียก `Switch-MySql` เหมือน PHP

> หมายเหตุ: ดาวน์โหลด URL ของ mariadb **ทำงานถูกต้องแล้ว** (`Get-OfficialUrls mysql` → archive.mariadb.org) — ที่พังคือขั้น extract/flatten ไม่ใช่ขั้นโหลด

---

## 4. เคสใหญ่: `httpd -t` เมิน PHP 7.4 แต่ยอม PHP 8.3

### อาการหลัก (ทำซ้ำได้ 100%)

```
httpd.exe: Syntax error on line 37 of .../config/httpd.conf:
  Can't locate API module structure `php_module' in file
  .../stack/php/7.4.33/php7apache2_4.dll: No error      exit=1

vs. ชี้ LoadModule ไปที่ php8apache2_4.dll (8.3.36) -> Syntax OK  exit=0
```

### 4.1 ตารางทดสอบ (matrix)

| # | เงื่อนไข | `httpd -t` | LoadLibrary (process ธรรมดา) |
|---|----------|-----------|------------------------------|
| A | conf 7.4 + PATH ปกติ (ไม่ prepend) | ❌ FAIL 1 | ❌ FAIL 126 (php7ts หาไม่เจอ — ปกติ) |
| B | conf 7.4 + PATH มีโฟลเดอร์ PHP | ❌ FAIL 1 | — |
| C | conf 7.4 + PATH มี **PHP dir + Apache bin** | ❌ FAIL 1 | ✅ **PASS** handle≠0, err=0 |
| D | conf 7.4 + PATH มี Apache bin อย่างเดียว | ❌ FAIL 1 | — |
| E | conf **ชี้ 8.3.36** + PATH มี PHP8 dir + bin | ✅ **Syntax OK** | ✅ PASS |
| T3 | conf 7.4 ทำ round-trip re-encode (ค่าเท่า E ทุกอย่าง ยกเว้น dll) | ❌ FAIL 1 | ✅ PASS |

**ใจความ:** process ธรรมดากับ PATH ชุดเดียวกัน → โหลด `php7apache2_4.dll` สำเร็จ แต่ `httpd.exe` ล้มเหลว — ความต่างอยู่ที่**ตัว process httpd เท่านั้น** และ**เจาะจงที่ PHP 7.4 เท่านั้น**

### 4.2 สมมุติฐานที่ตัดทิ้งแล้ว (พร้อมหลักฐาน)

| สมมุติฐาน | ผล | หลักฐาน |
|-----------|-----|---------|
| ไฟล์เสีย / แตกไม่ครบ | ตัดทิ้ง | SHA256 `php7apache2_4.dll` = `6241A38C…B0D288`, `php7ts.dll` = `5D46E026…E3E14` **ตรงกับ official zip ที่เพิ่งโหลดจาก windows.php.net ทุกไบต์** |
| สถาปัตยกรรมผิด (x86/x64) | ตัดทิ้ง | PE machine = `0x8664` ทุกไฟล์ (php.exe, php7apache2_4, php7ts, httpd Win64) |
| โดน MOTW/บล็อกไฟล์ | ตัดทิ้ง | ไม่มี ADS `Zone.Identifier` เหลืออยู่ |
| path ใน conf มีอักขระมองไม่เห็น | ตัดทิ้ง | hex dump บรรทัด 37 = ASCII ล้วน + `Test-Path -LiteralPath` = True + ชื่อไดเรกทอรี = `0037 002E 0034 002E 0033 0033` |
| encoding/ภาษาไทยใน conf เพี้ยน | ตัดทิ้ง | conf ต้นฉบับกับ round-trip (UTF8+BOM) ให้ผลเดียวกัน (T3); บรรทัด 36 เป็น comment ไทยปกติ |
| export `php_module` หาย | ตัดทิ้ง | มีใน dll + เป็นไฟล์ official + ข้อความผิดเป็นฝั่ง "โหลด" ไม่ใช่ฝั่ง "symbol" |
| PATH ไม่พอ / หา dependency ไม่เจอ | ตัดทิ้งบางส่วน | PATH = PHP dir + bin แล้ว httpd ยัง fail; แต่ process ธรรมดา load สำเร็จด้วย PATH ชุดเดียวกัน |
| ไฟล์ถูกสลับระหว่างทดสอบ | ตัดทิ้ง | โหลด official มาเทียบทีหลัง — match=True ทั้งสองไฟล์ |
| Signed-module policy / CIG | ตัดทิ้ง | php7/php8 dll = unsigned ทั้งคู่ (Authenticode NotSigned เหมือนกัน) → ถ้า policy บล็อก ต้องบล็อกทั้งคู่ |

### 4.3 ข้อเท็จจริงที่เหลืออยู่

- **dlerror = "No error"** — แปลว่า LoadLibrary คืน NULL โดยที่ GetLastError() = 0 ซึ่งเกิดได้ในเคส **DllMain คืน FALSE** (CRT/loader init ล้มเหลวใน process นั้นๆ) ต่างจาก dependency หายที่จะได้ error 126 "The specified module could not be found"
- **php7ts.dll vs php8ts.dll** — import แทบเหมือนกันทุกประการ ต่างที่ php7ts มี `imagehlp.dll` เพิ่ม (System32 — ไม่น่าใช่ปัญหา) และ php7 สร้างด้วย **VC15/VS2017** (vc15) ส่วน php8.3 = vs16 — คนละ toolset
- dll ทั้งคู่ import `libapr-1 / libaprutil-1 / libhttpd / VCRUNTIME140 / api-ms-win-crt-*` — ตัว httpd (Apache Lounge VS18, built ต.ค. 2026) ใหม่กว่า PHP 7.4.33 (built พ.ย. 2022) ราว 4 ปี
- log `apache-error.log` จาก run ก่อนหน้ามี `VirtualProtect() failed [87] The parameter is incorrect` 2 ครั้ง ก่อน server ยุติ — คนละ run แต่คุ้มค่าสอบต่อ (เกี่ยวกับการ map หน้าความจำของ mod_php/TS)

### 4.4 แนวทางปิดเคส (ขั้นถัดไป)

1. **ETW loader trace** — `logman` เปิด provider Microsoft-Windows-Kernel-Process (Image/Thread keywords) แล้ว `tracerpt` แปลง ETL → CSV เทียบรูป image ที่โหลด/ล้มเหลว ระหว่าง run 7.4 กับ 8.3 จะเห็นชื่อ dll ตัวสุดท้ายที่แตะก่อนพัง
2. **ProcMon** — filter Process = httpd.exe + Path contains php7 → อ่านผล Load Image / NAME NOT FOUND แบบ raw
3. test แยกโฟลเดอร์: copy `php7apache2_4.dll + php7ts.dll` ลงไดเรกทอรีสะอาดชี้ conf ไป — ถ้าผ่านแปลว่าไฟล์อื่นใน `stack\php\7.4.33` แทรกแซง; ถ้า fail คือ interaction ระหว่าง httpd VS18 กับ VC15 ล้วนๆ
4. ถ้ายังไม่ตาย: แตก official zip ใหม่ทั้งโฟลเดอร์ `7.4.33` (กันเศษไฟล์ NTS ที่เคย merge ค้าง)

---

## 5. "แยก PHP 7 กับ PHP 8 ใน setup" — ถูก แต่แค่บางส่วน

| ส่วน | ต้องแยกไหม? | เหตุผล |
|------|-------------|--------|
| ชื่อไฟล์โหลดอัตโนมัติ (`Get-OfficialUrls` / `setup.ps1`) | ❌ **ต้องแยก — บั๊กจริง** | `aptstack.ps1:1448` hardcode `$base = "php-$ver-Win32-vs16-x64.zip"` → PHP 7.x ของจริงชื่อ `php-7.4.33-Win32-vc15-x64.zip` (vc15 ไม่ใช่ vs16) → `add php 7.4.33` พิมพ์ URL ผิด/โหลดไม่ได้ ส่วน `setup.ps1:82` บอก "vs17" อีกแบบ |
| LoadModule ใน httpd.conf | ✅ ไม่ต้องแยก | `New-HttpdConf` ใส่ชื่อ dll ตามไดเรกทอรี PHP ที่ active อยู่แล้ว (หลักฐาน: บรรทัด 37 = `php7apache2_4.dll` ถูกต้องเมื่อ active = 7.4.33) และ symbol `php_module` ใช้ร่วมกันทั้ง 7/8 |
| การตรวจ TS/NTS | ✅ ไม่ต้องแยก | ใช้ `php*apache2_4.dll` ร่วมกันได้ (หลังแก้ §2) |
| Redistributable ที่ต้องแจ้งเตือน | ⚠️ ควรแยกข้อความ | PHP 7.4 = VC++2017 (VC15) · PHP 8.0–8.3 = VS2019 (VS16) — ตัว runtime ต่างกัน ควร warn ตอน add |

```text
# แผนแก้ Get-OfficialUrls (php) — แปลง tag จากเลขเวอร์ชัน
ver >= 8.0  ->  php-{ver}-Win32-vs16-x64.zip
ver 7.2–7.4 ->  php-{ver}-Win32-vc15-x64.zip
ver 7.0–7.1 ->  php-{ver}-Win32-vc14-x64.zip   (ถ้าจะรองรับ)
```

---

## 6. ช่องโหว่/ความเสี่ยงที่ตรวจพบ (audit จากของจริงใน stack + โค้ด aptstack)

> **ขอบเขต:** สิ่งที่ "เจอเอง" จากการ inspect ไฟล์/คอนฟิก/โค้ดในเครื่องนี้ + รายการ CVE สาธารณะที่ทราบที่ฐานความรู้ของโมเดล (ตรวจสอบล่าสุดเท่าที่ครอบคลุม — ควรยืนยันซ้ำกับ [NVD](https://nvd.nist.gov/) / [PHP security](https://www.php.net/manual/en/security.php) / [Apache advisories](https://httpd.apache.org/security_report.html) ล่าสุดเสมอ)

### 6.1 ของเก่าใน stack (ควรรู้ก่อนใช้ทดสอบ)

| รายการ | ความเสี่ยง | รายละเอียด |
|--------|-----------|------------|
| **PHP 7.4.33** | 🔴 สูง (ตามอายุ) | **EOL 28 พ.ย. 2022** — ไม่มี patch ความปลอดภัยอีกเลย ~4 ปี ตัวนี้**เคยถูก active ใช้งาน**ในสแตก (menu ขึ้น `<- ใช้อยู่`) aptstack เตือน EOL แล้ว แต่ยังรันได้ → ใช้เทสต์บนเครื่องตัวเองเท่านั้น |
| **PHP 8.1.25** | 🔴 สูง (ตามอายุ+ระดับ patch) | **EOL 31 ธ.ค. 2025** และเป็นระดับก่อน 8.1.28 → **CVE-2024-4577** (Windows PHP-CGI argument injection, CVSS 9.8) ที่ออก mid-2024 **ไม่ได้รับ patch ในฝั่ง 8.1.25** — *ข้อจำกัด:* ช่องโหว่นี้ exploiting ผ่าน `php-cgi.exe` กับ locale Best-Fit ซึ่ง aptstack ไม่ได้ใช้โหมด CGI (ใช้ built-in server + mod_php) → ความเสี่ยงจริงในสแต็กนี้จึง**ต่ำกว่าปกติ** แต่สถานะ EOL ทำให้ช่องโหว่ใหม่หลังจากนี้จะไม่มีวันถูกอุด — *ตอนนี้ `stack.json` ตั้ง `"php": "8.1.25"` อยู่* |
| **MariaDB 10.4.8** | 🟠 กลาง–สูง | ระดับ patch ปี **2019**; สาขา 10.4 **EOL ก.พ. 2024** → ค้าง patch หลายรายการ (สาย privilege/DoS ใน 10.4.x ที่ทยอยออกหลัง 2019) ข้อจำกัด: bind `127.0.0.1:3307` → โดนจากนอกเครื่องยาก ควรย้ายไป **10.11/11.4 LTS** |
| Apache **httpd 2.4.69** | 🟢 ต่ำ | เป็นรุ่นปัจจุบันของ Apache Lounge (built ต.ค. 2026) — จากที่ทราบไม่มี CVE สาธารณะที่กระทบ 2.4.69 โดยตรง (ชุดใหญ่ CVE-2024-3847x / h2 DoS / SSRF ถูกปิดไปแล้วในสาย 2.4.59–2.4.64) — **ยืนยันซ้ำกับ httpd security report** *หมายเหตุ:* ไบนารี Apache Lounge ไม่มีลายเซ็น Authenticode (ปกติของที่นี่ แต่เป็นจุด supply-chain ที่ต้องวางใจแหล่งโหลด) |
| PHP **8.2.35 / 8.3.36** | 🟢 ต่ำ | รุ่นยังได้รับ support (8.2 หมด security support 31 ธ.ค. 2026 — เริ่มใกล้ EOL; 8.3 ยังเหลืออีกปี) — **เป็นตัวที่แนะนำ**แทน 7.4/8.1 |

### 6.2 เจอเองจากโค้ด/คอนฟิก aptstack (code review ระหว่าง debug)

| # | ระดับ | พบ | รายละเอียด / แนะนำ |
|---|-------|-----|--------------------|
| V1 | 🔴 สูง | **phpMyAdmin config-auth + root/root เปิดจาก LAN ได้** | `Write-PmaConfig` สร้าง `config.inc.php` เป็น `auth_type='config'` (user `root`/pass จาก `stack.json` = `root`) **ไม่มีหน้าล็อกอิน** ขณะที่ `Listen 8077` (ไม่ระบุ IP → รับทุก interface) และ `Require all granted` — ใครใน LAN ที่ถึง port 8077 เปิด `/phpmyadmin/` ได้ **เข้าเป็น root ทันที** · *แก้:* เพิ่ม `Require local` สำหรับ `/phpmyadmin` หรือ `Listen 127.0.0.1:8077` หรือบังคับ `auth_type='cookie'` |
| V2 | 🟠 กลาง | **ไม่มี integrity check ไฟล์ที่ดาวน์โหลด** | `add` รับ URL อะไรก็ได้แล้วแตกเลย — ไม่มีการเทียบ SHA256 กับค่าอ้างอิง (ทั้งที่ตัว dist ของ aptstack เองมี `.sha256`) · *แก้:* pin hash ของ official หรืออย่างน้อยโชว์ hash หลังดาวน์โหลดให้ user เทียบ |
| V3 | 🟠 กลาง | **creds เริ่มต้น root/root + `dbAdmin: auto`** | ผูก `127.0.0.1:3307` (ดี) แต่รหัสผ่าน default ง่ายมาก และ `dbAdmin auto` ตั้ง phpMyAdminให้แชร์ creds เดียวกัน · *แก้:* สุ่มรหัสผ่านตอน setup แล้วบันทึกให้เห็นชัด |
| V4 | 🟡 ต่ำ | `Expand-AndFlatten` ใช้ `Expand-Archive` ตรงๆ | พึ่งพาการกัน path traversal ของ PowerShell — ควร validate รายชื่อ entry ใน zip ว่าไม่มี `..`/พาธเด็ดขาดก่อนแตก (zip-slip defense-in-depth) — **ยังไม่พบ exploitable ในไฟล์ที่ใช้จริง** เป็น hardening |
| V5 | 🟡 ต่ำ | config/session files อยู่ใน `config\sessions\` | ตอนนี้ปลอดภัยเพราะ httpd.conf มี `RedirectMatch 404 ^/(config|stack|...)` กันไว้แล้ว — เพียงแต่ตำแหน่งนี้ "ต้องไม่โดนยกเลิก" เมื่อแก้ template |

### 6.3 สิ่งที่ตรวจแล้วดี (ไม่พบรอบโหว่)

- `Options -Indexes` ปิด directory listing ✓
- `RedirectMatch 404 ^/(config|stack|versions|data|logs|templates|bin)(/|$)` กันโฟลเดอร์ระบบไม่ให้เว็บเข้าถึง ✓
- `FilesMatch` ปฏิเสธ `.bak/.ini/.log/.sql/.pem/.key/...` ✓ (รวม `config.inc.php` ของ phpMyAdmin ด้วย `.inc`)
- `/server-status` = `Require local` ✓
- Header `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` ✓
- MariaDB bind `127.0.0.1` ✓ · HTTPS self-signed เปิด `httpsEnabled` ✓

---

## 7. Backlog ที่ยังค้างอยู่

| งาน | อ้างอิง | สถานะ |
|-----|---------|-------|
| แก้ `Expand-AndFlatten` (temp + retry + fallback) และลบ dead-end "มีอยู่แล้ว" | §3 | ยังไม่เริ่ม |
| alias `mariadb` ใน add/use/rm | §3 | ยังไม่เริ่ม |
| เมนูเลือกเวอร์ชันเพิ่มหัวข้อ [MariaDB] (ใช้ `Switch-MySql`) | §3 | ยังไม่เริ่ม |
| build `dist\aptstack-1.3.5.zip` ใหม่ (ของเดิมยังเป็นโค้ด php8-only) | §2 | ยังไม่เริ่ม |
| ETW/ProcMon สืบเคส httpd + PHP7 | §4.4 | ยังไม่เริ่ม |
| แยก tag ชื่อไฟล์ PHP 7 (vc15) vs 8 (vs16) ใน Get-OfficialUrls/setup | §5 | ยังไม่เริ่ม |
| ปิด V1 (phpMyAdmin Require local / bind loopback) | §6.2 | ยังไม่เริ่ม ⚠️ **ควรทำก่อน** |

---

*รายงานสรุปจาก session debug — หลักฐานสำคัญ: SHA256 เทียบ official zip · LoadLibraryExW P/Invoke · PE import/machine parse · A/B `httpd -t` · hex dump conf · Authenticode check*
