# aptstack — portable PHP / MariaDB / จัดการเวอร์ชันแอป สำหรับ Windows

**ไม่ต้องติดตั้ง** — copy โฟลเดอร์ไปเครื่อง server ก็ใช้ได้ · **ติดตั้งเป็น Windows Service ได้** ·
**สลับเวอร์ชันแอป / PHP ด้วยคำสั่งเดียว** แล้วย้อนกลับได้ทันที

ทำแบบ XAMPP / Laragon แต่เพิ่ม 2 อย่างที่ของเดิมไม่มี:
**สลับเวอร์ชันแอป** ได้ และ **ลง Windows Service** ได้

> คู่มือทั้งหมด:
> [คู่มือใช้งาน](docs/คู่มือ.md) · [คู่มือ (HTML)](docs/คู่มือ.html) ·
> [เทียบกับ devstack](docs/เปรียบเทียบ-devstack.md) · [ความปลอดภัย](SECURITY.md) ·
> [README ภาษาอังกฤษ](README.md)

---

## เริ่มใช้ 4 คำสั่ง

```cmd
cd /d D:\aptstack
aptstack init             :: สร้างโครงสร้าง + ติดตั้งตัวอย่าง app (ถ้ายังไม่มี)
aptstack start            :: เปิด database + web
aptstack seed             :: import database ตัวอย่าง (aptstack_demo)
aptstack doctor           :: ตรวจสุขภาพ + ช่องโหว่
```

เปิดเบราว์เซอร์ → **http://127.0.0.1:8077/app/**
(ตัวอย่าง app จะโชว์ PHP version + ตาราง `greetings` จาก database → พิสูจน์ว่าทุกอย่างรันได้จริง)

phpMyAdmin → **http://127.0.0.1:8077/phpmyadmin/** (ถ้ามีใน `www\`)

> **บน release ที่ดาวน์โหลดมา** จะมีแค่ scripts/templates/docs + `examples\`
> ต้องโหลด PHP เอง: `aptstack add php <php-x.y.z-Win32-vs16-x64.zip>`
> (สายที่ปลอดภัย: 8.3.36 / 8.4.27 / 8.5.12 / 8.2.35)

---

## งานที่ใช้บ่อย

### 1) เปลี่ยนเวอร์ชันแอป (copy ลง แล้วสั่งเดียว)

```cmd
:: copy เวอร์ชันใหม่ลง server
aptstack add app C:\deploy\myapp-1.2.0.zip     :: หรือชี้ไปโฟลเดอร์

aptstack use 1.2.0        :: สลับ + restart ให้เอง
aptstack use -            :: ไม่ดี! ย้อนกลับตัวเมื่อกี้ทันที
aptstack next             :: วนดูหลายเวอร์ชัน
```

ที่อยู่ข้างหลัง: `www\app` เป็น **junction** ชี้ไป `versions\<เวอร์ชัน>`
→ ของเก่าไม่หาย ย้อนกลับได้เสมอ

### 2) เปลี่ยน PHP (เรื่องความปลอดภัย)

```cmd
aptstack add php https://windows.php.net/downloads/releases/php-8.3.36-Win32-vs16-x64.zip
aptstack use php 8.3.36
aptstack doctor
```

| สาย PHP | ต้องใช้ |
|---|---|
| 8.5 | **8.5.12+** |
| 8.4 | **8.4.27+** |
| 8.3 | **8.3.36+** |
| 8.2 | **8.2.35+** |
| 8.1 และต่ำกว่า | ❌ หมด support ไม่มี patch — ห้ามใช้ production |

> เลือกตัวไหน? → **8.3.36** (ปลอดภัย + กระโดดจาก 8.1 ไม่มาก โค้ด CodeIgniter เก่าไม่พัง)
> โหลดแบบ **Thread Safe x64** (`php-x.y.z-Win32-vs16-x64.zip`)

### 3) เปลี่ยน Apache / MySQL (เหมือน PHP เป๊ะ)

```cmd
aptstack add apache C:\Downloads\httpd-2.4.69-Win64-VS18.zip
aptstack use apache 2.4.69        :: สลับ Apache + restart

aptstack add mysql  C:\Downloads\mariadb-11.4.13-winx64.zip
aptstack use mysql  11.4.13       :: สลับ MySQL (datadir แยกต่อ version ข้อมูลไม่ปน)
```

web server ที่ใช้ตอนนี้ดูที่ `webMode` ใน `config\stack.json`:
`"auto"` (มี Apache ใช้ Apache) · `"apache"` · `"builtin"` (PHP built-in)

### 4) เปิด / ปิด

```cmd
aptstack start | stop | restart | status | list
```

### 5) ติดตั้งเป็น Windows Service

```cmd
:: รัน cmd/PowerShell ในโหมด administrator
aptstack service install
aptstack service start
aptstack service status
aptstack service uninstall     :: ถอน (ไม่เหลืออะไรค้าง)
```

ไม่ต้องโหลด NSSM/WinSW — ตัว service compile ให้เองด้วย `csc.exe` ที่มากับ Windows

### 6) backup ก่อนเปลี่ยนเวอร์ชัน

```cmd
aptstack backup            :: dump ทุก database -> data\dumps\
```

---

## โครงสร้าง (แก้ตรงไหน?)

```
aptstack\
├── aptstack.cmd, as.cmd      ตัวเรียกใช้ (พิมพ์ aptstack / as)
├── aptstack.ps1              ตรรกะทั้งหมด
├── setup.ps1                 wizard ติดตั้งครั้งแรก
├── service.ps1               ติดตั้ง/ถอน Windows Service
│
├── templates\                ✅ แก้ที่นี่ (ถาวร, commit ลง git)
│   ├── php-extensions.ini      รายการ extension ที่เปิด
│   ├── php-hardening.ini       ค่าความปลอดภัย
│   └── my.ini.tpl              template ของ MariaDB
│
├── config\                   ⚠️ config อยู่ที่เดียว (ห้าม commit)
│   ├── stack.json               ★ เลือก version + port ที่นี่ที่เดียว
│   ├── php.ini, my.ini          generate ใหม่ทุกครั้งที่ start (ห้ามแก้)
│   └── pids\, tmp\, stop.flag
│
├── stack\                    binary (ห้าม commit)
│   ├── php\8.3.36\, php\8.1.34\
│   └── mysql\mariadb-11.4.13-winx64\
│
├── versions\                 โค้ดแอป (ห้าม commit)  versions\1.0.0\, 1.1.0\
├── data\                     ฐานข้อมูล (ห้าม commit)
│   ├── mariadb-11.4.13-winx64\   datadir จริง
│   └── dumps\                    *.sql
│
├── www\                      docroot
│   ├── router.php                ✅ commit
│   ├── phpmyadmin\
│   └── app                 junction -> versions\<เวอร์ชันที่ใช้>
│
├── logs\  downloads\  bin\
└── docs\                     คู่มือ
```

**กฎสั้น ๆ**

| โฟลเดอร์ | คืออะไร | แก้ได้? |
|---|---|---|
| `templates\` | ต้นฉบับ | ✅ แก้ตรงนี้ |
| `config\stack.json` | ค่าจริง (version, port) | ✅ แก้ได้ |
| `config\php.ini`, `my.ini` | ของ generate | ❌ ห้ามแก้ (หายทุก restart) |
| `stack\` | binary | ❌ |
| `versions\` | โค้ดแอป | ✅ |
| `data\` | ฐานข้อมูล | ❌ ยกเว้น backup |

---

## ใช้ MySQL ของ XAMPP แทน MariaDB ใน bundle

ได้ — ตั้ง `config\stack.json`:

```json
"dbMode": "external",
"dbPort": 3306
```

แล้ว `aptstack restart` → aptstack จะ**ไม่ start และไม่ stop** MySQL ของ XAMPPเลย
(ปลอดภัย ไม่ kill ของคนอื่น) ส่วน web + phpMyAdmin ยังรันจาก aptstack ที่ port 8077

> phpMyAdmin ใน `www\phpmyadmin\` ชี้ `127.0.0.1:3306` ให้ตรงกับ `dbPort` ที่ใช้จริง

---

## แก้ปัญหาบ่อย

| อาการ | ทำอะไร |
|---|---|
| หน้าแอปขาว / ขึ้น `mysqli_connect() ไม่มี` | `aptstack restart` (php.ini generate ใหม่) |
| พอร์ตชน | แก้ `httpPort` / `dbPort` ใน `config\stack.json` แล้ว restart |
| อยากดู log | `logs\php-error.log`, `logs\mariadb-error.log` |
| `aptstack` ไม่รู้จัก | ต้อง `cd` อยู่ที่โฟลเดอร์นี้ก่อน หรือใช้ `as` |
| เปลี่ยน php.ini แล้วหาย | ถูกต้อง — ให้แก้ที่ `templates\php-extensions.ini` / `php-hardening.ini` |
| Service start ไม่ขึ้น | `aptstack service status` แล้วดู `logs\` (ต้องรัน as admin) |
| copy ไปเครื่องอื่นแล้วพัง | ไม่ควรถ้าใช้ `aptstack start` — ทุก path generate ใหม่เอง (เช็คด้วย `doctor`) |

---

## ความปลอดภัย

`aptstack doctor` ตรวจให้ครบ:

- PHP ตรงเกณฑ์ patch ช่องโหว่ RCE แล้วหรือยัง
- `session.upload_progress` ปิด (หนึ่งในทางเข้าช่องโหว่)
- `expose_php` / `allow_url_include` / `display_errors` ปิด
- path ใน `my.ini` / `php.ini` ไม่ชี้ออกจากโฟลเดอร์ (copy ไปเครื่องอื่นได้จริง)
- MariaDB bind `127.0.0.1` และ `local_infile=0`
- **ไม่มีไฟล์ .sql / binary / โค้ดแอป ถูก track ใน git**

รายละเอียด → [SECURITY.md](SECURITY.md)

---

## License

MIT — ใช้/แก้/แจกได้ตามใจ
