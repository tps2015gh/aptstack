# aptstack — portable PHP / MariaDB / จัดการเวอร์ชันแอป สำหรับ Windows

**ไม่ต้องติดตั้ง** — copy โฟลเดอร์ไปเครื่อง server ก็ใช้ได้ · **ติดตั้งเป็น Windows Service ได้** ·
**สลับเวอร์ชันแอป / PHP ด้วยคำสั่งเดียว** แล้วย้อนกลับได้ทันที

ทำแบบ XAMPP / Laragon แต่เพิ่ม 2 อย่างที่ของเดิมไม่มี:
**สลับเวอร์ชันแอป** ได้ และ **ลง Windows Service** ได้

> คู่มือทั้งหมด:
> 🚀 **[Scenario ยาว — แตก ZIP จนใช้จริง](docs/SCENARIO.md)** ·
> [ไดอะแกรม/ภาพรวมระบบ](docs/diagrams.md) ·
> [คู่มือใช้งาน](docs/คู่มือ.md) · [คู่มือ (HTML)](docs/คู่มือ.html) ·
> [แบบ offline/intranet](docs/OFFLINE-DEPLOY.md) ·
> [เทียบกับ devstack](docs/เปรียบเทียบ-devstack.md) · [ความปลอดภัย](SECURITY.md) ·
> [ตรวจงาน / บั๊คที่เจอ](review.md) · [ตรวจความปลอดภัย](audit.md) ·
> [แนวคิด+สถาปัตยกรรม](concept.md) · [จิตวิญญาณ+เครดิต](soul.md) · [คู่มือสำหรับ AI](ai.md) ·
> [เกี่ยวกับโปรเจกต์ / เครดิต + ความเห็น](docs/ABOUT-TH.md) ·
> [README ภาษาอังกฤษ](README.md)

---

## 🧠 แผ่นจำ (จำแค่นี้ก็ใช้ได้)

| จำอะไร | ค่า |
|---|---|
| พอร์ต | web **8077** · MySQL **3307** · HTTPS **8443** |
| PHP ปลอดภัย | **8.3.36 / 8.4.27 / 8.5.12 / 8.2.35** (ต่ำกว่านี้ = ห้ามใช้) |
| โฟลเดอร์ | `stack`=binary · `versions`=โค้ดแอป · `data`=ฐานข้อมูล · `config`=ค่า |
| สลับแอป | `use <ชื่อ>` · ย้อนกลับ `use -` |
| เรียกคำสั่ง | **ต้องใช้ `aptstack.cmd`** (ห้ามเรียก `.ps1` ตรง ๆ) |
| ตรวจก่อนขึ้นจริง | `aptstack doctor` ต้องไม่มี **[ERR]** |

**5 คำสั่งที่ใช้ทุกวัน**

```cmd
aptstack list       :: มีอะไร / ใช้อันไหนอยู่
aptstack start      :: เปิด stack
aptstack use <ชื่อ> :: สลับ
aptstack doctor     :: ปลอดภัยไหม
aptstack report     :: สรุปเป็น HTML (พิมพ์ได้)
```

> จำไม่ได้? พิมพ์ `aptstack help` หรือ `-h` ได้ทุกเมื่อ

---

## เริ่มใช้ 4 คำสั่ง

```cmd
cd /d D:\aptstack
aptstack init             :: สร้างโครงสร้าง + ติดตั้ง "ตัวอย่าง 3 แอป" ให้เอง
aptstack seed             :: import database ตัวอย่าง (greetings + todo_items)
aptstack start            :: เปิด database + web (+ health probe จริง)
aptstack doctor           :: ตรวจสุขภาพ + ช่องโหว่
```

เปิดเบราว์เซอร์ → **http://127.0.0.1:8077/app/** แล้วสลับดูได้เลย:

```cmd
aptstack list             :: เห็น path เต็มของทุก app
aptstack use todo-app     :: Todolist (ใช้ database จริง)
aptstack use sysinfo-app  :: inventory เครื่อง (IPv4/subnet/CPU/RAM/disk)
aptstack next | prev      :: วนดู · aptstack use - = ย้อนกลับ
```

| ตัวอย่าง | พิสูจน์ |
|---|---|
| `hello-app` | web+PHP+DB เชื่อมกัน (ตาราง `greetings`) |
| `todo-app` | **ใช้ database ได้จริง** (CRUD ลง `todo_items`) |
| `sysinfo-app` | อ่าน IP/subnet/CPU/RAM/disk ของเครื่องที่รันได้ |

phpMyAdmin → **http://127.0.0.1:8077/phpmyadmin/** (ถ้ามีใน `www\`)

> **บน release ที่ดาวน์โหลดมา** จะมีแค่ scripts/templates/docs + `examples\`
> ต้องใส่ binary เอง — **ใส่แค่เลขเวอร์ชันก็ได้**:
> `aptstack add php 8.3.36` (ระบบเติม URL ทางการ + โหลด + ติดตั้งให้)
> แล้ว `aptstack list` จะโชว์ `from: <url>` ให้ copy โหลดเองภายหลังได้
> (สายที่ปลอดภัย: 8.3.36 / 8.4.27 / 8.5.12 / 8.2.35)
>
> 📌 **ทุกโฟลเดอร์อยู่ในโฟลเดอร์ที่แตก** — `stack\`, `versions\`, `config\`, **`data\`**, `logs\`
> ไม่มีการเขียนออกนอกนั้น (ยกเว้น `stack\` ที่ต้องใส่ binary ตอนแรก)
>
> ⚠️ **ต้องอยู่โฟลเดอร์เดียวกับ `aptstack` เท่านั้น (และ drive เดียวกัน)**
> โค้ดแอป, PHP, ฐานข้อมูล **ห้ามชี้ไปโฟลเดอร์/drive อื่น** — เพราะ aptstack
> สร้าง `php.ini`/`my.ini`/`httpd.conf` ใหม่ทุกครั้งที่ `start` โดยชี้เข้าไปในตัวเอง
> ของที่อยู่ข้างนอกจะถูกเมิน (ยังไม่มีฟีเจอร์ external path)

### โหลด binary แบบ offline / intranet (server ไม่มีเน็ต)

`add` **รับ path ท้องถิ่นอยู่แล้ว** — เตรียม zip บนเครื่องที่มีเน็ต แล้ว copy เข้า server:

```cmd
:: บนเครื่องมีเน็ต: โหลด zip + sha256sum.txt ไว้ใน D:\staging\
:: ย้ายเข้า server ด้วย USB / share / RDP copy-paste

cd /d E:\aptstack
aptstack add php     D:\staging\php-8.3.36-Win32-vs16-x64.zip
aptstack add apache  D:\staging\httpd-2.4.69-261002-Win64-VS18.zip
aptstack add mysql   D:\staging\mariadb-11.4.13-winx64.zip
aptstack use php 8.3.36
aptstack start
aptstack doctor
```

- หรือ**วางไฟล์เอง**ใน `stack\php\<ver>\` / `stack\apache\<name>\` / `stack\mysql\<name>\` ก็ได้
- `add` ยังรับ **URL mirror ภายใน** ได้: `aptstack add php http://pkg.internal/apt/php.zip`
- อย่าลืม `vc_redist_x64.exe` ถ้าเครื่อง server ยังไม่มี VC++ runtime
- ขั้นตอนเต็ม + checksum + checklist → **[docs/OFFLINE-DEPLOY.md](docs/OFFLINE-DEPLOY.md)**

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

**ตั้งชื่อ version อย่างไร?** → **ชื่อ = ชื่อโฟลเดอร์ใน `versions\`** ตั้งเองอิสระ 100%
ไม่มี format บังคับ ไม่ได้อ่านจาก manifest ที่ไหน

| อยากได้ชื่อแบบ | ตัวอย่าง | ทำยังไง |
|---|---|---|
| release | `1.2.0` | `aptstack add app C:\deploy\myapp.zip myapp-1.2.0` |
| build รายวัน | `build-1022` | `aptstack add app \\share\build-1022` |
| สถานะ | `uat`, `staging-hotfix` | ตั้งชื่อโฟลเดอร์แล้ว `add app <path>` |
| ชื่อโปรเจกต์ | `todo-app`, `sysinfo-app` | `aptstack samples` ตั้งให้เอง |

กติกา: ไม่เว้นวรรค · อย่าชื่อซ้ำ · อย่า rename ตัวที่กำลังใช้อยู่ · prefix สั้นอาจชน
(`use 1.2` ถ้ามี `1.2.0`+`1.2.1` → เอาตัวใหม่สุด) · ยืนยันด้วย `aptstack list`
→ รายละเอียด: [docs/SCENARIO.md](docs/SCENARIO.md) ข้อ 6

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

### 7) จัดการ version: clone / remove / migrate / report

```cmd
:: ก้อปปี้ app 1.0 -> 1.1 (ยังไม่สลับให้ -> use เอง · DB ใช้ตัวเดิม)
aptstack clone app 1.0 1.1

:: คัดลอก datadir (ต้อง stop ก่อน — ไฟล์ InnoDB ห้าม copy ตอนเปิด)
aptstack stop
aptstack clone mysql mariadb-11.4.13 mariadb-11.4.14

:: โยกข้อมูล DB ไป engine ใหม่ (dump -> switch -> restore · ของเดิมไม่ถูกแตะ)
aptstack migrate mysql mariadb-10.11.19

:: ลบ (ถามยืนยันเสมอ · ตัวที่ใช้อยู่ลบไม่ได้)
aptstack remove app 1.0
aptstack remove php 8.1.34
aptstack remove mysql mariadb-11.4.13          :: เก็บ data ไว้
aptstack remove mysql mariadb-11.4.13 data     :: ลบทั้งคู่ (ต้องพิมพ์ DELETE)

:: สรุปสถานะทั้งหมดเป็น HTML เปิดดู/พิมพ์ได้ (Ctrl+P A4)
aptstack report
```

> `help` ทุกคำสั่ง: `aptstack help` (หรือ `-h` / `--help` / `/?`) — แต่**ต้องเรียกผ่าน `.cmd`**
> (`.\aptstack.ps1` ตรง ๆ จะโดน ExecutionPolicy บล็อก)

---

## โครงสร้าง (แก้ตรงไหน?)

```
aptstack\
├── aptstack.cmd, as.cmd      ตัวเรียกใช้ (พิมพ์ aptstack / as)
├── aptstack.ps1              ตรรกะทั้งหมด
├── setup.ps1                 wizard ติดตั้งครั้งแรก
├── service.ps1               ติดตั้ง/ถอน Windows Service
├── service\AptStackService.cs  source ของ service host (compile เองตอน install)
│
├── examples\                 ✅ ตัวอย่าง 3 แอป + seed.sql (commit ลง git)
│   ├── hello-app\              โชว์ PHP + ตาราง greetings
│   ├── todo-app\               Todolist CRUD (ใช้ database จริง)
│   ├── sysinfo-app\            inventory เครื่อง (IP/subnet/CPU/RAM)
│   ├── seed.sql                รันด้วย: aptstack seed
│   └── vhosts.sample.json      ตัวอย่าง virtual host
│
├── templates\                ✅ แก้ที่นี่ (ถาวร, commit ลง git)
│   ├── php-extensions.ini      รายการ extension ที่เปิด
│   ├── php-hardening.ini       ค่าความปลอดภัย
│   ├── my.ini.tpl              template ของ MariaDB
│   ├── httpd.conf.tpl          (webMode=apache)
│   └── ssl.conf.tpl            (httpsEnabled=true)
│
├── config\                   ⚠️ config อยู่ที่เดียว (ห้าม commit)
│   ├── stack.json               ★ เลือก version + port + httpsEnabled
│   ├── vhosts.json              ★ virtual host หลายชื่อ host/หลายแอป
│   ├── certs\                   ★ cert/key TLS (aptstack tls init | tls import)
│   ├── php.ini, my.ini, httpd.conf  generate ใหม่ทุกครั้งที่ start (ห้ามแก้)
│   └── pids\, tmp\, stop.flag
│
├── stack\                    binary (ห้าม commit)
│   ├── php\8.3.36\, php\8.1.34\
│   ├── apache\httpd-2.4.69\
│   └── mysql\mariadb-11.4.13-winx64\
│
├── versions\                 โค้ดแอป (ห้าม commit)  hello-app\ todo-app\ sysinfo-app\ 1.1.0\
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

## HTTPS / Virtual host / log (เพิ่มใหม่)

```cmd
:: HTTPS (ใช้ได้กับ webMode=apache)
aptstack tls init                      :: สร้าง self-signed + เปิด 8443 + trust ให้เลย
aptstack tls import fullchain.pem privkey.pem   :: ใช้ SSL cert จริง
aptstack tls status | tls off

:: virtual host (แยกหลายแอป/หลายชื่อ host)
:: แก้ config\vhosts.json แล้ว aptstack restart
::   [ { "host": "demo.local", "app": "hello-1.0.0" },
::     { "host": "apt.local",  "app": "1.1.0" } ]

:: log
aptstack logs apache | mysql | php     :: ดูท้ายไฟล์ (ใส่ตัวเลข = กี่บรรทัด)
aptstack logs all
```

- **health probe หลัง start** — ไม่รอแบบ blind อีกต่อไป:
  `start` จะยิง HTTP จริง (และ HTTPS ถ้าเปิด) + `ping` database แล้วรายงาน
  `health: https -> 200 OK (660 ms)` ถ้า fail จะบอกให้เปิด `aptstack logs <ตัว>`
- `tls init` ใช้ `openssl.exe` ที่มากับ Apache (ไม่ต้องติดตั้งอะไรเพิ่ม)
  และ**ใส่ cert เข้า Trusted Root ของผู้ใช้ให้** ไม่งั้น .NET/browser ปฏิเสธ
- ดูรายละเอียด: [docs/คู่มือ.md](docs/คู่มือ.md) ข้อ 5a และ 5b

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
