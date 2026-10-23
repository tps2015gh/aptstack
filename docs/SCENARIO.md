# Scenario — ตั้งแต่แตก ZIP จนใช้งานจริง (ยาว แต่ทำตามทีละขั้นได้เลย)

> เอกสารนี้พาไปครบรอบ: **ดาวน์โหลด → แตก → ใส่ binary → เริ่ม → ดูตัวอย่าง 3 แอป
> → สลับแอป → ตั้งชื่อ version → เพิ่มแอปตัวเอง → HTTPS/vhost → Service → backup**
> · กลับไป [README-TH.md](../README-TH.md) · คู่มือสั้น [คู่มือ.md](คู่มือ.md) ·
> แบบ offline [OFFLINE-DEPLOY.md](OFFLINE-DEPLOY.md)

---

## 0. สรุป 60 วินาที

```cmd
:: ได้ไฟล์มาจาก GitHub Release แล้ว
tar -xf aptstack-1.2.0.zip -C D:\
cd /d D:\aptstack

aptstack add php 8.3.36        :: เติม URL ทางการให้เอง + โหลด + ติดตั้ง
aptstack add apache <url|path> :: (ถ้าจะใช้ Apache/mod_php หรือ HTTPS)
aptstack add mysql 11.4.13     :: (หรือ copy stack\mysql มา)
aptstack init                  :: ติดตั้งตัวอย่าง 3 แอปให้เอง
aptstack seed                  :: สร้าง database ตัวอย่าง
aptstack start                 :: เริ่ม + health probe จริง
aptstack doctor                :: ต้องไม่มี [ERR]
```

เปิด `http://127.0.0.1:8077/<appAlias>/` → เล่นได้ทันที

---

## 1. ได้ไฟล์มาจาก GitHub แล้วทำอะไร

### 1.1 ดาวน์โหลด

- Repo: https://github.com/tps2015gh/aptstack
- Release: https://github.com/tps2015gh/aptstack/releases → ไฟล์ `aptstack-x.y.z.zip` (~90KB)
- (เครื่องที่โหลดก็แตกไฟล์ได้จาก https://raw.githubusercontent.com หรือ clone repo ก็ได้)

### 1.2 แตกไฟล์

```cmd
:: Windows 10/11 มี tar ในตัว (หรือใช้ 7-Zip / Expand-Archive)
tar -xf aptstack-1.2.0.zip -C D:\
cd /d D:\aptstack
```

### 1.3 สิ่งที่ได้ — และ **ทุกโฟลเดอร์อยู่ในนี้ทั้งหมด**

```
D:\aptstack\                      <- โฟลเดอร์ที่แตก (root ของ bundle)
├── aptstack.cmd / as.cmd          ตัวเรียกใช้ (ใช้ตัวนี้! ห้ามเรียก .ps1 ตรง ๆ)
├── aptstack.ps1                   logic ทั้งหมด
├── setup.ps1  service.ps1
├── templates\                     ต้นฉบับ config (commit ลง git)
├── examples\                      ตัวอย่าง 3 แอป + seed.sql + vhosts.sample.json
├── docs\                          คู่มือทั้งหมด
├── service\AptStackService.cs     source ของ Windows Service host
│
├── stack\        <- ใส่ binary ที่นี่ (php/apache/mysql)      [ยังไม่มีใน zip]
├── versions\     <- โค้ดแอป                              [init จะใส่ตัวอย่างให้]
├── config\       <- ค่าจริง + ini ที่ generate             [init จะสร้าง]
├── data\         <- **database จริง** ทั้ง datadir + dumps   [start จะสร้าง]
├── www\          <- docroot (router.php + junction ชี้ app ที่ active)
└── logs\  downloads\  bin\
```

> ✅ **ยืนยัน:** หลังแตกแล้ว ทุกอย่าง (`stack`, `versions`, `config`, **`data`**, `logs`)
> อยู่ **ภายใน `D:\aptstack` ทั้งหมด** — ไม่มีการเขียนออกนอกโฟลเดอร์นี้
> → copy ย้ายเครื่องได้ทั้งก้อน, ลบโฟลเดอร์เดียว = ถอนหมด, backup ง่าย
>
> ⚠️ ที่ยังไม่มีตอนแตกใหม่คือ **binary** (`stack\`) เพราะ release ตั้งใจไม่แถม (ดูข้อ 2)

---

## 2. ใส่ binary (PHP + Apache + MariaDB)

### ทาง A — มีเน็ต: ให้ระบบโหลดให้เอง

```cmd
:: PHP: ใส่แค่เลขเวอร์ชัน -> ระบบเติม URL ทางการให้เอง + โหลด + แตกให้
aptstack add php 8.3.36

         เติม URL ทางการให้ (php 8.3.36)
         ---------------------------------------
                https://windows.php.net/downloads/releases/php-8.3.36-Win32-vs16-x64.zip
                https://windows.php.net/downloads/releases/archives/php-8.3.36-Win32-vs16-x64.zip
                คัดลอก URL ข้างบนไว้โหลดเองภายหลังได้ · ไม่มีเน็ต -> docs\OFFLINE-DEPLOY.md

         ดาวน์โหลด https://windows.php.net/downloads/releases/php-8.3.36-Win32-vs16-x64.zip
   [OK]   บันทึกไว้: D:\aptstack\downloads\php-8.3.36-Win32-vs16-x64.zip
   [OK]   ติดตั้ง PHP 8.3.36 เรียบร้อย
```

> 💡 **URL ถูกบันทึกไว้ด้วย** — ดูทีหลังได้ด้วย `aptstack list` (บรรทัด `from:`)
> หรือเปิดไฟล์ `.aptstack-source` ในโฟลเดอร์นั้น อยากโหลดเองภายหลังก็ copy URL ไปได้เลย

```cmd
:: Apache + MySQL (ต้องส่ง URL/path เอง เพราะชื่อไฟล์มีเลข build)
aptstack add apache https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.69-261002-Win64-VS18.zip
aptstack add mysql  11.4.13      :: เติม URL archive.mariadb.org ให้เอง (ถ้า version ถูกต้อง)
```

### ทาง B — ไม่มีเน็ต

ดูฉบับเต็ม → [OFFLINE-DEPLOY.md](OFFLINE-DEPLOY.md) (เตรียม zip บนเครื่องอื่น → copy → `add <path>`)

### ทาง C — เร็วสุด: copy `stack\` จากเครื่องที่พร้อมแล้ว

```cmd
robocopy "C:\เครื่องที่รันได้\aptstack\stack" D:\aptstack\stack /E
```

### แล้วเลือก web mode

```cmd
:: ค่าเริ่มต้น webMode=auto -> ถ้ามี Apache+PHP TS จะใช้ Apache ให้เอง
aptstack use php 8.3.36
aptstack list        :: ดูว่าได้อะไรบ้าง + ที่มา (from:) ของแต่ละตัว
```

---

## 3. เริ่มใช้ครั้งแรก

```cmd
aptstack init          :: สร้างโฟลเดอร์ + ถ้า versions\ ว่าง -> ติดตั้ง "ตัวอย่าง 3 แอป" ให้
aptstack seed          :: สร้าง database ตัวอย่าง (greetings + todo_items)
aptstack start         :: เริ่ม + health probe จริง
aptstack doctor        :: ต้องไม่มี [ERR]
```

ตัวอย่างผล `start`:

```
  [OK]   MariaDB 11.4.13 healthy (ping OK, 2359 ms, port 3307)
  [OK]   Apache 2.4.69 + mod_php (PHP 8.3.36)
  [OK]   health: http  -> 200 OK (2481 ms)  http://127.0.0.1:8077/
  [OK]   health: https -> 200 OK (692 ms)   https://127.0.0.1:8443/
```

> ถ้า `versions\` ยังว่างและไม่ได้รัน `init` → สั่ง **`aptstack samples`** เพื่อลงตัวอย่างภายหลังได้

---

## 4. ตัวอย่าง 3 แอป (มีมาให้ใน `examples\`)

| ชื่อใน `versions\` | ทำอะไร | พิสูจน์ว่า |
|---|---|---|
| **`hello-app`** | โชว์ PHP/SAPI/ini + ตาราง `greetings` จาก DB | web + PHP + DB เชื่อมกัน |
| **`todo-app`** | Todolist CRUD จริง (เพิ่ม/เสร็จ/ลบ) ใช้ตาราง `todo_items` | **ใช้ database ได้จริง** (เขียน-อ่านข้อมูล) |
| **`sysinfo-app`** | inventory เครื่องคร่าว ๆ: hostname, OS, uptime, **IPv4/subnet/gateway/DNS**, CPU, cores/threads, RAM, disk free, PHP/Apache/DB version | อ่านค่าระบบได้ + เปลี่ยนตามเครื่องที่รัน |

```cmd
aptstack samples          :: ติดตั้งทั้ง 3 (ข้ามตัวที่มีแล้ว)
aptstack list             :: เห็น path เต็มของแต่ละตัว
```

เปิดดู:
- `hello-app` → ตาราง "สวัสดี — aptstack + MariaDB ทำงานแล้ว"
- `todo-app` → เพิ่มงานได้จริง (POST เขียนลง DB แล้วแสดงกลับ)
- `sysinfo-app` → ตัวอย่างผลบนเครื่องจริง:
  `Hostname MY-PC / CPU Example-CPU 6 cores 12 threads / RAM 7.9 GB / IPv4 192.168.x.x / Network 192.168.1.0/24 (~254 hosts) / Database MariaDB 11.4.13 (เชื่อมต่อ OK)`

> ⚠️ `sysinfo-app` ใช้ `ipconfig /all` + PowerShell CIM (**ไม่ใช้ `wmic`** — ถูกถอดออกจาก
> Windows 11 24H2 แล้ว) และอ่านค่า **ตอนเรียก request เท่านั้น** ไม่เขียนไฟล์ใด ๆ

---

## 5. สลับแอปไปมา (ฟีเจอร์หลัก)

```cmd
aptstack list
```

```
App versions:
   * todo-app      C:\...\versions\todo-app        <- * = ตัวที่ใช้อยู่
     hello-app     C:\...\versions\hello-app
     sysinfo-app   C:\...\versions\sysinfo-app
     1.1.0         C:\...\versions\1.1.0
PHP:
   * 8.3.36        C:\...\stack\php\8.3.36
     ...
โฟลเดอร์ (วาง/ลบ/จัดการ ได้ที่นี่)
     app versions : C:\...\versions
     ...
```

| อยากทำ | คำสั่ง |
|---|---|
| เลือกตรง ๆ | `aptstack use todo-app` |
| วนดูทีละตัว | `aptstack next` / `aptstack prev` |
| ย้อนกลับตัวเมื่อกี้ | `aptstack use -` |
| เมนู (กดเลข) | `aptstack use` |

**หลักการ:** `www\<appAlias>` เป็น **junction** ชี้ไป `versions\<ตัวที่ active>`
→ สลับ = ย้าย junction + restart web ของเก่าอยู่ครบ ย้อนกลับได้เสมอ

ทดสอบแล้ว: สลับ `todo-app` → เพิ่มงาน (POST) ผ่าน → `use sysinfo-app` → หน้าเปลี่ยนทันที
โดย **database ตัวเดียวกัน** ยังอยู่ (ข้อมูลไม่หายแม้สลับแอป)

---

## 6. ตั้งชื่อ version อย่างไร? (คำถามที่พบบ่อย)

**สั้น ๆ: ตั้งเองได้อิสระ 100% — ชื่อ = ชื่อโฟลเดอร์ใน `versions\` ไม่มี schema บังคับ
และไม่ได้อ่านจาก manifest ที่ไหนเลย**

| หลักการทำงาน | |
|---|---|
| ชื่อมาจากอะไร | **ชื่อโฟลเดอร์** ใน `versions\` เท่านั้น |
| `add app <folder> <ชื่อ>` | กำหนดชื่อเองตอนเพิ่ม |
| `add app <zip>` | ชื่อ = ชื่อไฟล์ zip (ตัด `.zip` ออก) |
| `add app examples\todo-app` | ชื่อ = ชื่อโฟลเดอร์ต้นทาง (`todo-app`) |
| เก็บไว้ไหน | junction + `config\stack.json` (`app` / `appPrev`) — ชื่อตัวอื่นไม่ต้อง register ที่ไหน |
| ใช้ตอนไหน | `aptstack use <ชื่อ>` · `list` · `next`/`prev` |

**ตั้งมั่ว ๆ ได้ไหม?** ได้ แต่ให้ "อ่านรู้เรื่องภายหลัง" — แนะนำ:

| รูปแบบ | ตัวอย่าง | เหมาะกับ |
|---|---|---|
| Semantic version | `1.2.0`, `1.3.1` | release ที่ส่งขึ้น server |
| วันที่/build | `2026-10-22`, `build-1022` | ทดสอบ build รายวัน |
| สถานะ | `uat`, `staging-hotfix` | เทียบ environment |
| ชื่อฟีเจอร์ | `todo-app`, `sysinfo-app` | ตัวอย่าง/โปรเจกต์แยกตัว |

**กติกาที่ควรทำ (ไม่ใช่บังคับแต่พลาดแล้วเจ็บ):**

1. **ไม่เว้นวรรค / ไม่มีอักขระพิเศษ** — ใช้ `-` หรือ `_` แทน (เว้นวรรคทำให้พิมพ์คำสั่งยาก)
2. **อย่าใช้ชื่อซ้ำ** — ของเดิมถูกแทนที่เงียบ ๆ (robocopy ข้ามถ้ามีอยู่แล้วจะแจ้ง "มีอยู่แล้ว")
3. **อย่าเปลี่ยนชื่อตัวที่กำลังใช้อยู่** — ถ้าจะ rename ให้ `use` ไปตัวอื่นก่อน แล้วค่อย rename โฟลเดอร์
4. **prefix สั้นอาจชนกัน** — ถ้ามี `1.2.0` กับ `1.2.1` แล้วสั่ง `use 1.2` → ระบบเอาตัวใหม่สุดที่ตรง
5. ใช้ `aptstack list` ยืนยันเสมอว่า `*` อยู่ที่ตัวที่ตั้งใจ

> สรุป: **ไม่ต้องอ่าน format มาจากที่ไหน** — ชื่อคือ label ของโฟลเดอร์
> ขอแค่ให้ตัวเอง/ทีมอ่านออกเมื่อกลับมาดูภายหลัง

---

## 7. เพิ่มแอปของตัวเอง

```cmd
:: จากโฟลเดอร์ (dev แล้วเอาลง)
aptstack add app C:\src\myapp-build123

:: จากโฟลเดอร์ + ตั้งชื่อเอง
aptstack add app C:\src\myapp myapp-1.3.0

:: จาก zip
aptstack add app C:\deploy\myapp-1.3.0.zip

:: หรือวางเอง:  copy โฟลเดอร์เข้า versions\ ตรง ๆ แล้ว aptstack list
```

แล้วสลับไป: `aptstack use myapp-1.3.0`

> ถ้าแอปผูกกับ path (เช่น CodeIgniter `base_url`) ให้ตรวจว่าชี้ host/port ที่ใช้จริง

---

## 8. เพิ่ม Virtual host + HTTPS (หลายชื่อ host)

`config\vhosts.json`:

```json
[
  { "host": "todo.local",   "app": "todo-app" },
  { "host": "sysinfo.local","app": "sysinfo-app" },
  { "host": "old.local",    "app": "1.1.0", "https": false }
]
```

```cmd
aptstack tls init        :: สร้าง self-signed + trust + เปิด 8443
aptstack restart         :: generate httpd.conf (httpd -t ให้เอง)
aptstack doctor          :: นับ vhost + บอกบรรทัด hosts file ที่ต้องเพิ่ม
```

ใส่ใน `C:\Windows\System32\drivers\etc\hosts`:

```
127.0.0.1   todo.local sysinfo.local old.local
```

แล้ว: `https://todo.local:8443/` → Todolist · `https://sysinfo.local:8443/` → System Info

> ใช้ cert จริง (Let's Encrypt): `aptstack tls import fullchain.pem privkey.pem`
> · รายละเอียด [คู่มือ.md](คู่มือ.md) ข้อ 5a/5b

---

## 9. ติดตั้งเป็น Windows Service (server จริง)

```cmd
:: เปิด cmd ด้วย administrator
aptstack service install
aptstack service start
aptstack service status
```

- compile `service\AptStackService.cs` ด้วย `csc.exe` ที่มากับ Windows → ไม่ต้องโหลด NSSM
- `sc failure` ให้ restart อัตโนมัติถ้าล่ม · ปิด stack แบบ clean (stop-flag)
- เครื่องบูตแล้ว stack ขึ้นเอง (start = auto)

---

## 10. ก่อน/หลังเปลี่ยนเวอร์ชัน (ปลอดภัย)

```cmd
aptstack backup            :: dump ทุก database -> data\dumps\  (ทำก่อนเสมอ)
aptstack add app C:\deploy\myapp-1.3.0.zip
aptstack use myapp-1.3.0   :: สลับ + restart ให้เอง
:: ... เปิดดู ...
aptstack use -             :: มีปัญหา -> ย้อนกลับตัวเดิมทันที
aptstack doctor
```

- โค้ดตัวเก่าอยู่ครบใน `versions\` → rollback เสมอ
- `datadir` แยกต่อ DB version → สลับ MySQL แล้วข้อมูลไม่ปน

---

## 11. Cheat sheet

```cmd
aptstack init | samples            เตรียมโครงสร้าง / ติดตั้งตัวอย่าง 3 แอป
aptstack add php 8.3.36            โหลด+ติดตั้ง PHP จาก URL ทางการ
aptstack add app <path|zip> [name] เพิ่มแอป
aptstack list                      ดูทุกอย่าง + path + ที่มา (from:)
aptstack use [name|-|php <ver>]    สลับ (เมนู / ระบุ / ย้อนกลับ)
aptstack next | prev               วนดูแอป
aptstack start|stop|restart|status เริ่ม/หยุด/สถานะ (+ health probe)
aptstack seed                      สร้าง database ตัวอย่าง
aptstack backup [file]             dump database
aptstack doctor                    ตรวจสุขภาพ + ช่องโหว่
aptstack logs <apache|mysql|php>   ดู log
aptstack tls status|init|import    HTTPS / cert
aptstack service install           Windows Service (admin)
```

> ⚠️ **เรียกด้วย `aptstack.cmd` เสมอ** (หรือ `as.cmd`) — ห้ามเรียก `.ps1` ตรง ๆ
> เพราะ PowerShell `ExecutionPolicy` จะบล็อก

---

## 12. เช็กลิสต์ขึ้น server จริง

- [ ] `aptstack doctor` ไม่มี `[ERR]`
- [ ] PHP เป็นเวอร์ชัน patch + Thread Safe (ถ้าใช้ Apache)
- [ ] เปลี่ยนรหัสผ่าน DB root (ค่าเริ่มต้น `root/root`)
- [ ] `config\stack.json` ตั้ง port/dbMode/webMode ตรง
- [ ] `aptstack backup` ก่อน deploy
- [ ] `aptstack service install` + `start`
- [ ] firewall เปิดเฉพาะที่จำเป็น (ค่าเริ่มต้น bind localhost)
- [ ] server ไม่มีเน็ต? → [OFFLINE-DEPLOY.md](OFFLINE-DEPLOY.md)

---

*ทุกคำสั่งในเอกสารนี้ถูกรันทดสอบจริงบน Windows 11 + Apache 2.4.69 + PHP 8.3.36 + MariaDB 11.4.13*
