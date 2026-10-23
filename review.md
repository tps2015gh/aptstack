# review.md — รายงานตรวจงาน (code + บั๊คที่เจอระหว่างสร้าง)

> ขอบเขต: ตรวจและรันทดสอบจริงบน **Windows 11 + Apache 2.4.69 + PHP 8.3.36 + MariaDB 11.4.13**
> คู่: [audit.md](audit.md) (ความปลอดภัย) · [concept.md](concept.md) · [ai.md](ai.md)

---

## 1. สรุปผู้ตรวจ

| หัวข้อ | ผล |
|---|---|
| Syntax (PS5.1 AST parser) | ✅ ผ่านทุกไฟล์ `.ps1` |
| รันจริง (start/stop/use/clone/remove/report/doctor) | ✅ ผ่าน |
| HTTP/HTTPS/DB probe | ✅ 200 ทุก endpoint |
| ข้อมูลจริงหลุด git | ✅ 0 ไฟล์ (ตรวจซ้ำก่อน commit) |
| ชื่อระบบจริงในเอกสาร | ✅ 0 จุด (หลังแทนด้วย `app`) |
| **บั๊คที่พบและแก้แล้ว** | **17 จุด** (ดูข้อ 2) |
| ข้อจำกัดที่เหลือ | ดูข้อ 4 — ยังไม่ถือว่า production-ready ทุกด้าน |

---

## 2. บั๊คที่พบและแก้ (เรียงตามความรุนแรง)

| # | อาการ | สาเหตุจริง | แก้ |
|---|---|---|---|
| 1 | **MySQL start ไม่ขึ้น** `Found option without preceding group` | `my.ini` มี UTF-8 BOM | `Write-Utf8NoBom` สำหรับ ini/json ทุกไฟล์ |
| 2 | **โค้ดไทยใน .ps1 เพี้ยน/พัง parse** | PS5.1 อ่าน `.ps1` ไม่มี BOM เป็น ANSI | บังคับ BOM ทุกครั้งหลังแก้ไฟล์ |
| 3 | **แอปอ่าน config ไม่ออก → DB โยน gssapi** | `stack.json` มี BOM → `json_decode` = null → รหัสผ่านหาย | `Save-Config` เขียน UTF8 ไม่มี BOM + PHP strip BOM |
| 4 | **white page / `mysqli_connect undefined`** | zip PHP ทางการไม่มี `php.ini` → ใช้ production ที่ comment ext หมด + `extension_dir` ไม่ถูกตั้ง (ไปหา `C:\php\ext`) | `templates\php-extensions.ini` + ตั้ง `extension_dir` เป็น absolute ของ build |
| 5 | **`Resolve-Apache` คืน null ทั้งที่มี Apache** | PS5.1 `.Count` = null บน `PSCustomObject` เดียว | `@(Get-Xxx)` ทุกจุดที่ใช้ `.Count`/`[-1]` |
| 6 | **httpd `ServerRoot` ผิด / module not found** | zip Apache Lounge มี `Apache24` ซ้อน → Dir ชี้ผิดชั้น | คำนวณ ServerRoot = parent ของ `bin\` |
| 7 | **`httpd -t` โยน exception** | native stderr + `EAP=Stop` = `NativeCommandError` | wrap ด้วย `EAP='Continue'` ชั่วคราว |
| 8 | **ข้อมูลไทยใน DB เป็น `???`** | `Get-Content \| client` → PS encode ตาม codepage | `Start-Process -RedirectStandardInput <file>` |
| 9 | **curl/intl/sodium โหลดไม่ได้ใต้ Apache** | Windows หา dependency DLL จาก PATH ของ process | prepend PATH ของ PHP ก่อน start httpd (ตรวจ ext ครบ 12/12) |
| 10 | **openssl ฟ้อง `C:\Apache24\conf\openssl.cnf`** | path compile-time | ชี้ `OPENSSL_CONF` ไป conf ของ bundle |
| 11 | **`SSLSessionCache: cache size not numerical`** | build นี้ไม่รับ `shmcb` ทกรูปแบบ | ตัด directive ออก (ใช้ default ได้) |
| 12 | **HTTPS probe fail ทั้งที่ server ตอบ** | `ServerCertificateValidationCallback` **ใช้ไม่ได้จริง**ใน PS5.1 (ทดสอบแล้วว่ายิ่งพัง) | ไว้ใจผ่าน **Trusted Root** (`tls init` ใส่ให้) + เอา callback ออก |
| 13 | **`https://host` ตกหน้า default / RemoteCertificateNameMismatch** | ไม่มี default vhost + cert ไม่มีชื่อ host ใน SAN | ใส่ default vhost **ก่อน**เสมอ + `tls init` ดึง host จาก `vhosts.json` เข้า SAN |
| 14 | **`aptstack.cmd` พิมพ์ `'-' is not recognized`** | `.cmd` เป็น LF (cmd ต้องการ CRLF) | convert เป็น CRLF ทุก `.cmd`/`.bat` |
| 15 | **`report` พัง `op_Addition`** | nested function ใช้ `$script:checks` ผิด scope → `+=` บน PSObject | ตั้งชื่อ `$script:RepChecks` + wrap `@(...)` |
| 16 | **script push พังทั้งที่ push สำเร็จ** | git เขียน progress ลง stderr | `EAP='Continue'` รอบ git push |
| 17 | **`$h` ทับ `$H`** | PowerShell ไม่แยก case ตัวแปร → headers กลายเป็นค่า hash | ใช้ชื่อตัวแปรต่างกัน (`$sha` / `$hdrs`) |

**บั๊คที่เป็นเอกสาร/ความถูกต้องของข้อมูล (ไม่ใช่ runtime):**

| # | พบ | แก้ |
|---|---|---|
| 18 | `doctor` false positive: เช็ค `HasPrivateKey` บนไฟล์ cert (ไม่มีวันมี) | แยกเช็คไฟล์ key |
| 19 | `doctor` flag `examples/seed.sql` ว่า leak | ยกเว้น `examples/*` |
| 20 | `seed` รายงานเลขแถวผิด label (2 SELECT ในไฟล์เดียว) | รายงานเลขทุกตาราง |
| 21 | `sysinfo` CPU/RAM ไม่แสดงบนเครื่องไม่มี `wmic` (Win11 24H2) | เปลี่ยนเป็น PowerShell CIM |
| 22 | ชื่อระบบจริง `app` อยู่ใน docs/โค้ด 8 ไฟล์ | แทนด้วย `app` + ตรวจซ้ำ = 0 |
| 23 | `dist/*.zip` หลุดเข้า track | `/dist/` ใน gitignore + `git rm --cached` |
| 24 | release มี zip เก่าปน | ลบ asset เก่า เหลือเฉพาะรุ่นปัจจุบัน |
| 25 | เครดิต "ทีม Hermes" ผิด | แก้เป็น "เจ้าของสร้างเองเริ่มจาก 0 ด้วย AI บน Hermes" |

---

## 3. หลักฐานการทดสอบ (รันจริง)

| ทดสอบ | ผล |
|---|---|
| `start` (Apache+mod_php) | `health: http -> 200 OK` , `https -> 200 OK` |
| DB | `mariadb-admin ping OK` + `SELECT VERSION() = 11.4.13` |
| แอปเดิม (CodeIgniter) บน PHP 8.3.36 | 200 + doctype + **0 PHP error** (หลังแก้ index.php 1 บรรทัด) |
| `use` app/PHP/Apache/MySQL | สลับ + restart อัตโนมัติ ทุกตัว |
| `use -` | ย้อนกลับได้ |
| `seed` + `todo-app` GET/POST | เพิ่มงานผ่าน POST แล้วแสดงกลับ (เขียน DB จริง) |
| vhost | default/`demo.local`/`apt.local` แยกถูก ทั้ง http และ https |
| `tls init` | cert 365 วัน + trust + HTTPS 200 |
| `service install/start` | Running, child = powershell → php/httpd + mariadbd |
| `samples` / `clone app` / `remove` guards | ติดตั้ง 3 ตัว, clone สำเร็จ, ปฏิเสธ active/`n`/traversal ถูก |
| `report` | ✓17 !1 ✗0 → HTML 9.8KB เปิดให้เลย |
| `doctor` | **ผ่านทุกข้อ** (ฝั่ง 8.1.34 = 2 `[ERR]` ดักได้จริง) |
| release zip | 40 entries, ไม่มีชื่อระบบจริง, มี docs ครบ |

---

## 4. ข้อจำกัดที่เหลือ (ยังไม่ปิด)

1. **ยังไม่ได้ทดสอบบน Windows Server จริง** — ทดสอบบน Win11 เท่านั้น
2. **`migrate mysql`** — เขียน + guard แล้ว แต่**ยังไม่ได้รัน end-to-end**
   (เครื่องมี engine เดียว → จำลองต้องมี engine ที่สองก่อน)
3. **`remove mysql ... data`** — guard + double-confirmation แล้ว แต่ยังไม่ได้ลบ datadir จริงทิ้ง
   (จงใจไม่ทดสอบทำลายของจริงบนเครื่องที่มีข้อมูล)
4. **โหลด binary ผ่าน URL** — `add php <version>` ทดสอบแล้ว (8.2.35 ดาวน์โหลด+ติดตั้งจริง)
   แต่**ยังไม่ได้ verify checksum อัตโนมัติ** (มีแค่แนะนำให้ user เช็ค) → ดู audit.md
5. **โค้ดแอปจริงยังไม่ผ่าน static security review** (SQLi/XSS) — คนละขอบเขตกับตัว stack
6. **Apache+VS18 vs PHP vs16** — ทดสอบแล้วว่าใช้ได้ แต่เป็น combination เดียวที่ทดสอบ
7. **single-file design** — `aptstack.ps1` ~2,500 บรรทัด สะดวกตอนนี้ แต่ควร split เป็น module
   ถ้าคำสั่งเกิน ~30 ตัว (ยังไม่ถึง แต่ใกล้)

## 5. ข้อเสนอแนะก่อนถือว่า "production"

- [ ] รัน `migrate` end-to-end ด้วย engine ที่สอง (เช่น 10.11)
- [ ] เพิ่ม verify SHA256 ตอน `add` (เทียบกับ `sha256sum.txt` ที่โหลดมา)
- [ ] ทดสอบบน Windows Server 2019/2022 + เป็น service ตั้งแต่บูต
- [ ] เปลี่ยนรหัสผ่าน DB + จำกัด firewall ก่อนเปิดพอร์ตออก
- [ ] static review โค้ดแอป (แยกขอบเขต)

## 6. คำตัดสิน

**ผ่านสำหรับใช้เป็นเครื่องมือ deploy/test บน Windows ภายในเครื่องและ lab** —
มี health probe จริง, doctor ที่ fail ได้, rollback ได้เสมอ, ไม่มีของ sensitive หลุด repo
**ยังไม่ผ่านสำหรับประกาศว่า production-ready ทุกด้าน** จนกว่าข้อเสนอแนะในข้อ 5 จะครบ
