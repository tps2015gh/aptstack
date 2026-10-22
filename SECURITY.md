# SECURITY.md — ความปลอดภัยของ aptstack

อ้างอิง `security-php.txt` (ช่องโหว่ PHP RCE ระดับ CVSS 9.2, Unauthenticated Remote Code Execution)

## 1. เวอร์ชัน PHP ที่ปลอดภัย (บังคับ)

| สาย PHP | ต้องใช้อย่างน้อย | สถานะ |
|---|---|---|
| 8.5 | **8.5.12** | ✅ patch แล้ว |
| 8.4 | **8.4.27** | ✅ patch แล้ว |
| 8.3 | **8.3.36** | ✅ patch แล้ว |
| 8.2 | **8.2.35** | ✅ patch แล้ว |
| **8.1 และต่ำกว่า** | — | ❌ **ไม่มี binary patch (EOL)** |

**ข้อกำหนดของ repo นี้:** PHP ที่ active ต้องอยู่ในกลุ่มผ่านเกณฑ์เท่านั้น
`aptstack doctor` จะ **fail** ถ้าไม่ผ่าน

```cmd
aptstack add php https://windows.php.net/downloads/releases/php-8.3.36-Win32-vs16-x64.zip
aptstack use php 8.3.36
aptstack doctor
```

> PHP 8.1 ที่ติดมาใน bundle เก่า ถูกเก็บไว้ที่ `stack\php\8.1.34` **เฉพาะสำหรับเทียบโค้ดเก่า
> ในเครื่อง developer เท่านั้น** — ห้ามใช้เป็น production และห้ามเปิดพอร์ตออกอินเทอร์เน็ต

## 2. ค่า hardening ที่ aptstack บังคับใช้

Generate ใหม่ทุกครั้งที่ `start` / `use php` จาก `templates\php-hardening.ini`:

| ค่า | ทำไม |
|---|---|
| `session.upload_progress.enabled = Off` | หนึ่งในทางเข้าของช่องโหว่ |
| `expose_php = Off` | ไม่เผยเวอร์ชัน PHP ให้สแกนเจอร์ |
| `allow_url_include = Off` | กันโหลด remote code |
| `display_errors = Off` + `log_errors = On` | ไม่รั่ว path/SQL ออกหน้าเว็บ เก็บลง `logs\php-error.log` |
| `session.cookie_httponly/strict/samesite` | ลดความเสี่ยง session hijack |
| `max_execution_time=60`, `memory_limit=512M`, upload size | จำกัด resource |

### `memory_limit = -1` ต้องใช้ไหม?

[security-php2.txt](https://www.aikido.dev/blog/critical-vulnerabilities-in-php-php2shell) ระบุว่า
**ถ้าอัปเดต PHP ไม่ได้ทันที** ให้เปิด mitigation **ทั้งสองอันพร้อมกัน** (ห้ามใช้อันใดอันหนึ่ง):

```ini
session.upload_progress.enabled = 0
memory_limit = -1
```

เหตุผล: ช่องโหว่ทั้งสองตัว (`CVE-2026-109618` / `CVE-2026-109619`) เป็น memory-safety
ตอนจัดการ out-of-memory → `memory_limit=-1` ตัดทางเข้าช่องโหว่ไปในตัว

**aptstack เลือกแบบนี้**

| สถานะ PHP ที่ใช้ | สิ่งที่ aptstack ทำ |
|---|---|
| **patch แล้ว** (8.3.36 ฯลฯ) | ❌ ไม่ตั้ง `memory_limit=-1` — เก็บ `512M` ไว้กัน DoS ดีกว่า |
| **ยัง patch ไม่ได้** (8.1 ฯลฯ) | ✅ `doctor` จะ **[ERR]** จนกว่าจะเปิด **ทั้งสอง** ค่า |

`aptstack doctor` ตรวจทั้งสองกรณีให้เอง


และ `templates\php-extensions.ini` กำหนด `extension_dir` ชี้ไปที่ build ที่ใช้จริง
(ป้องกัน scenario ที่ PHP ไปโหลด ext จาก `C:\php\ext` ของคนอื่น)

## 3. ฐานข้อมูล

- `bind-address=127.0.0.1` → รับเฉพาะ localhost
- `local_infile=0` → กัน LOAD DATA LOCAL
- `symbolic-links=0`, `skip-name-resolve`
- datadir อยู่ที่ `data\<ชื่อเครื่องยนต์>` แยกจาก binary
- ตั้งรหัสผ่าน root ใหม่ (ค่าเริ่มต้นของ bundle เป็น `root/root` → **ต้องเปลี่ยนบน server จริง**)

```sql
ALTER USER 'root'@'localhost' IDENTIFIED BY 'รหัสใหม่ที่ยาวและสุ่ม';
```

แล้วแก้ `dbPass` ใน `config\stack.json`

## 4. ข้อมูลจริงห้ามขึ้น GitHub

repo นี้เป็น **public** — `.gitignore` กันไว้แล้ว:

- `/stack/` (binary), `/versions/` (โค้ดแอป), `/data/` (datadir + dump), `/config/` (ค่า + ini)
- `*.sql`, `*.pem`, `*.key`, `.env`

`aptstack doctor` เช็คซ้ำว่าไม่มีไฟล์เหล่านี้ถูก `git track` อยู่ — ถ้าเจอจะ **[ERR]**

> ถ้าต้องแชร์โค้ดแอป ให้ทำ repo แยกต่างหาก อย่าใส่ใน repo นี้

## 5. สิ่งที่ aptstack ยัง**ไม่**ทำ (ต้องจัดการเอง)

- ⚠️ **HTTPS ไม่ได้เปิดโดยปริยาย** — มีให้แล้ว (`aptstack tls init` / `tls import`)
  แต่**ต้องสั่งเปิดเอง** และใช้ได้กับ `webMode=apache` เท่านั้น
  ถ้าจะเปิดออกอินเทอร์เน็ต: ใช้ **cert จริง** (`aptstack tls import fullchain.pem privkey.pem`)
  ไม่ใช่ self-signed
- ❌ ไม่ patch PHP ให้ — ต้องอัปเดต binary เอง
- ❌ ไม่ได้แก้ช่องโหว่ในโค้ดแอป (SQL injection / XSS ฯลฯ) — ตรวจด้วย static review ของแอป
- ❌ ไม่ได้ firewall พอร์ต — 8077/8443/3307 bind localhost แต่ถ้าเปิด firewall ต้องกำหนดเอง
- ❌ ไม่มี rate limit / WAF / reverse proxy — ถ้าเปิดสู่ internet ให้ต่อ proxy (Caddy/Nginx) ไว้หน้า

## 6. Checklist ก่อนขึ้น server จริง

```cmd
aptstack doctor          :: ต้องไม่มี [ERR]
:: เปลี่ยนรหัสผ่าน DB root
:: ตั้ง dbMode/dbPort ให้ตรง
aptstack backup          :: dump ไว้ก่อนเสมอ
aptstack service install :: ลง service (admin)
```

---

## 7. สรุป compliance (ตรวจสอบแล้ว)

### 7.1 เทียบ `security-php.txt`

| ข้อกำหนด | สถานะ | หลักฐาน |
|---|---|---|
| PHP เป็น 8.5.12 / 8.4.27 / 8.3.36 / 8.2.35 ขึ้นไป | ✅ | active = **8.3.36** (`aptstack list`) |
| 8.1 และต่ำกว่า ห้ามใช้ production | ✅ | `doctor` = `[ERR] ... EOL` ทันทีที่สลับไป 8.1.34 |
| อัปเดตแล้วต้อง restart PHP worker | ✅ | `use php` / `start` / `restart` restart ให้เอง |
| ถ้าอัปเดตไม่ได้ → แยกระบบออกจากอินเทอร์เน็ต | ✅ (ออกแบบ) | bind `127.0.0.1` ทั้ง web และ DB |
| แค่ขึ้นหน้า "ปิดปรับปรุง" ไม่เพียงพอ | ✅ | ไม่ได้ทำ — patch ที่ runtime จริง |

### 7.2 เทียบ `security-php2.txt` (Aikido / PHP2Shell)

| ข้อกำหนด | สถานะ | หลักฐาน |
|---|---|---|
| Update แล้ว restart PHP | ✅ | 8.3.36 + auto restart |
| ไม่ได้ใช้ mod_php (ตัวที่ PHP ระบุว่าเสี่ยงสูงสุด) | ✅ | ใช้ PHP built-in server (`cli-server`) |
| `session.upload_progress.enabled = 0` | ✅ | `Off` (ยืนยันผ่าน `ini_get` บน web SAPI) |
| `memory_limit = -1` (เฉพาะตอนยัง patch ไม่ได้) | ⏸ ไม่ใช้ | patch แล้ว → เก็บ `512M`; `doctor` เตือนเองถ้าหลุดไปใช้ 8.1 |
| ตั้งค่าให้แอป override ไม่ได้ | ⚠️ บางส่วน | ค่าอยู่ใน `config\php.ini` (ต้นทางเดียว) แต่แอปยัง `ini_set()` ได้ |
| low `post_max_size` ช่วยลดการโจมตี | ⚠️ `64M` | แอปมีรูป/ไฟล์อัปโหลด → ลดเหลือ `8M` ได้ถ้าไม่จำเป็น |
| บล็อก `multipart/form-data` ถ้าไม่ใช้ upload | ❌ ไม่ทำ | แอปใช้อัปโหลดไฟล์ → ใช้ไม่ได้ |
| หลัง patch: ไล่ดูสัญญาณถูกเจาะ | ✅ (ครึ่งหนึ่ง) | `doctor` เช็ค memory-limit error ใน log + บอก checklist ที่เหลือ |
| rotate password / API key / token | ⚠️ manual | ดู §8 |

### 7.3 ยืนยันค่าจริง (รันบน web SAPI `cli-server`)

```
session.upload_progress.enabled    = Off
expose_php                         = Off
allow_url_include                  = Off
display_errors                     = Off
log_errors                         = On
memory_limit                       = 512M
max_execution_time                 = 60
PHP_VERSION                        = 8.3.36
ZTS                                = YES
mysqli                             = YES
```

### 7.4 ผล `aptstack doctor`

```
[OK]   PHP 8.3.36 ผ่านเกณฑ์ patch ช่องโหว่ RCE
[OK]   session.upload_progress ปิด (จุดที่ช่องโหว่ใช้)
[OK]   expose_php / allow_url_include / display_errors ปิด
[OK]   patch แล้ว — ไม่ต้องใช้ memory_limit=-1
[OK]   ไม่พบ memory-limit error ใน log (ไม่เข้าข่าย IOC)
[OK]   my.ini / php.ini : path ทั้งหมดอยู่ใน bundle
[OK]   MariaDB bind 127.0.0.1, local_infile ปิด
[OK]   ไม่มีไฟล์ .sql / binary / โค้ดแอป ถูก track ใน git
[OK]   ผ่านทุกข้อ
```

เมื่อสลับไป PHP 8.1.34 → `doctor` คืน **2 [ERR]**
(EOL + mitigation ไม่ครบ) — พิสูจน์แล้วว่าดักได้ทั้งสองฝั่ง

---

## 8. หลัง patch — ไล่สัญญาณถูกเจาะ (manual)

`doctor` เช็คให้แล้ว: memory-limit error ใน `logs\php-error.log`
ที่เหลือต้องตรวจเอง:

1. `PHPSESSID` ตัวใหญ่/ผิดรูป หรือ multipart request แปลก ๆ ใน access log
2. HTTP 500 ซ้ำ ๆ หรือ PHP worker restart โดยไม่ทราบสาเหตุ
3. ค้น webshell / ไฟล์ `.php` ใหม่ใน `www\` และ `versions\`
   ```cmd
   git -C versions\1.1.0 status --short     :: ถ้า app มี git
   ```
4. user admin ใหม่ / รหัสผ่านเปลี่ยนในระบบ
5. ไฟล์ PHP ถูกแก้ (`*.php` เปลี่ยนเมื่อไหร่)
6. การเชื่อมต่อ outbound ผิดปกติ

**ถ้าเว็บเปิดออกอินเทอร์เน็ต:** ให้ rotate password / API key / token ของระบบ
ที่รันบน PHP ตัวนั้น เพราะช่องโหว่เปิดทางอ่าน memory ของ worker ได้

