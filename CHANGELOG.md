# Changelog

## Unreleased

### Added

- **`aptstack ports`** — ดูพอร์ตของ stack (HTTP/HTTPS/MySQL) พร้อม **เจ้าของ exe** (PID + path + โฟลเดอร์)
  แยก mark `[ours]` / `[bundle]` / `[other]` → รู้ทันทีว่า port โดนจองโดย program ของ bundle ไหน
- **`aptstack stop <port>`** — หยุด process ที่จองพอร์ตนั้น · โชว์ exe path ก่อน ·
  ถ้า **ไม่ใช่ของ bundle นี้** จะถามยืนยันก่อนเสมอ
- `status` + ข้อความเตือนตอน `start`/`doctor` โชว์ path ของ program ที่จอง port ด้วย

## 1.3.0 — 2026-10-23

คำสั่งจัดการ version/ข้อมูล + รายงานสถานะ + พื้นที่ดิสก์ + ไดอะแกรม + เอกสารแกนกลาง

### Added

- **`aptstack run`** — dev console: start + ค้างหน้าจอ กด Ctrl+C หยุด (**ไม่ต้อง register service**)
- **`aptstack size`** — ตารางพื้นที่ทุกโฟลเดอร์ + breakdown รายตัว (versions/stack/data)
  + **เตือน bundle บวม / disk ใกล้เต็ม** (version>200MB, dumps>100MB, downloads/ชุด deploy ค้าง, free<10GB)
- **`aptstack report`** มีหัวข้อ "พื้นที่/การบวมของดิสก์" แบบพิมพ์ได้ (แทน 3 แถวเดิม)
- **`aptstack dist <app> [out] [nostack]`** — สร้างชุด deploy copy-paste
  (`dist_paste\<app>\` มี **VERSIONS.txt** รายงาน version + **DEPLOY.txt** ขั้นตอน)
- **`aptstack git init|status|clear`** — git ของ bundle บน server (track เฉพาะ scripts/docs)
- **app family manifest** — `versions\<name>\.aptstack-version` (family/version)
  → `list`/`size`/`report` แสดง `[todo] todo-app` vs `[todo] todo-1.1` รู้ทันทีว่า app เดียวกัน
  · `clone` สืบทอด family อัตโนมัติ
- **ไดอะแกรม**: `docs/diagrams.md` (Mermaid) + `docs/diagrams/*.svg` 5 ภาพ (vector เล็ก ~5KB)
- **`docs/คู่มือ.md` ข้อ 7b — โหมด dev vs production** (ไม่ใช้ nginx · dev ไม่ต้อง service ·
  production รัน manual ก่อนแล้ว `service install` ทีหลัง)
- แผ่นจำ (cheat sheet) ใน README-TH
- **`aptstack report`** (รุ่นก่อนหน้า) — หน้า HTML สรุปสถานะทั้งหมด (probe, checks ✓/!/✗,
  เวอร์ชัน, config, vhost, พื้นที่) พิมพ์ได้เลย (Ctrl+P A4)
- **`aptstack clone app <จาก> <เป็น>`** — ก้อปปี้โค้ด app (ยังไม่สลับให้ → `use` เอง · DB ใช้ตัวเดิม)
- **`aptstack clone mysql <จาก> <เป็น>`** — คัดลอก datadir (บังคับ `stop` ก่อน + ยืนยัน)
- **`aptstack remove app|php|apache|mysql <ชื่อ> [data]`** — ลบพร้อมแจ้งเตือน+ยืนยัน ·
  ปฏิเสธตัวที่ active · กัน path traversal · datadir ต้องพิมพ์ `DELETE` (2 ชั้น)
- **`aptstack migrate mysql <ใหม่>`** — โยกข้อมูลไป engine ใหม่ (dump → switch → restore)
- **`-h` / `-?` / `--help`** → โชว์ help
- **`aptstack add apache <version>`** — ใส่แค่เลขเวอร์ชัน (เช่น `2.4.69` หรือ `latest`) ระบบไป
  **scrape หน้า Apache Lounge** แล้วเติม URL + โหลด + ติดตั้งให้ในคำสั่งเดียว
  · ข้อจำกัด: Lounge เก็บ **เฉพาะ build ล่าสุด** และชื่อไฟล์มีเลข build
  (`httpd-2.4.69-261002-Win64-VS18.zip`) → เวอร์ชันเก่าที่เลิกแล้วต้องส่ง URL เต็ม/path เอง
- **`aptstack list --available [php|mysql|apache]`** — ดูรายการเวอร์ชันที่ *ยังโหลดได้* จากเว็บทางการ
  (windows.php.net releases+archives · archive.mariadb.org · Apache Lounge) แสดง **ตัวใหม่สุดต่อสาขา**
  พร้อมแท็กผ่าน/ไม่ผ่านช่องโหว่ RCE (ใช้ `Get-PhpRisk` เดิม) + `* มีในเครื่องแล้ว`
  · ไม่มี kind = โชว์ครบทั้ง 3 · รับทั้ง `--available` กับ `available` (ต้อง declare switch ใน param
  เพราะ PS โยน parameter binding error ก่อนถึง dispatch เหมือนเคส `-h`)
- **Web console** `www/aptstack-console/` (localhost only) — start/stop/status/doctor/list/size/
  samples/seed/report/logs + switch app/PHP จากเบราว์เซอร์ · IP gate + CSRF + command whitelist
  · dangerous cmds (remove/clone/migrate/service/tls import) ใช้ CLI เท่านั้น
  · per-app URL aliases `/app/` `/todo-app/` `/sysinfo-app/` บน listener เดียว
  · screenshot: `docs/screenshots/console.png` · เอกสาร: คู่มือ.md §7c, README-TH, README
- เอกสารแกนกลาง: **`ai.md`** · **`concept.md`** · **`soul.md`** · **`review.md`** · **`audit.md`**

### Fixed

- **`Start-Db`: MariaDB datadir init พัง** — เคยเรียก `mysqld --initialize-insecure` ซึ่งเป็น
  ของ MySQL เท่านั้น → MariaDB ตอบ `unknown option` exit 2 (เจอตอน `migrate` ไป engine ใหม่)
  · ตอนนี้ใช้ `mysql_install_db.exe -d<datadir> -p<password>` ถ้ามี (MariaDB) และ fallback
  `--initialize-insecure` เฉพาะ MySQL · datadir ที่ init ค้างจะถูกล้างก่อน
  · **ทดสอบ end-to-end แล้ว**: `migrate mysql 11.4.13 → 10.11.19` dump/restore ครบ
    (`aptstack_demo`: greetings 3 · todo_items 18) แล้ว `use mysql 11.4.13` rollback ได้

- 🔴 **`.cmd`/`.bat` เป็น LF** → cmd พิมพ์ `'-' is not recognized` ทุกครั้ง → แปลงเป็น CRLF
- `report`: nested function ใช้ `$script:` ผิด scope → `op_Addition` error
- `Confirm-Action`: อ่านคำตอบจาก stdin เมื่อ piped (`echo y | ...`) ได้แล้ว
- prompt แสดงก่อนอ่านคำตอบเสมอ
- `dist <app> <outRoot>`: path สัมพัทธ์ถูก resolve จาก CWD (ผิด) → แก้ให้เป็น root ของ bundle
- `git init`: git เขียน warning ลง stderr → EAP=Stop โยน exception → กด EAP Continue
- `service install`: ตรวจพอร์ตถูกจอง (manual ยังรันอยู่) → เตือน/ถามก่อนติดตั้ง
- `size`: drive free ไม่ขึ้น (Get-PSDrive ต้องตัด `:` ออกจาก drive name)
- `add mysql latest` / `add apache latest`: ค่า default `8.3.36` ของ PHP ถูก apply กับ **ทุก kind**
  → สร้าง URL ผิด (`mariadb-8.3.36-...`) · ย้าย default เข้า branch `php` · `latest` ของ MariaDB
  ตอนนี้ตอบกลับชัดเจนว่าต้องระบุเลขเวอร์ชัน
- **ดาวน์โหลดจาก `apachelounge.com` ล้มเหลว** บน PS5.1 (`Invoke-WebRequest` = "Operation is not
  valid due to the current state of the object") → **fallback ไป `curl.exe`** ทั้งตอน fetch หน้า
  และตอนโหลด zip (ไม่มี stream redirection → ไม่ชน NativeCommandError กับ `EAP=Stop`)
- **release zip ไม่มีโฟลเดอร์บนสุด** → แตกแล้วไฟล์กระจายลง drive (แต่คู่มือสอน `tar -xf ... -C D:\`
  ตามด้วย `cd /d D:\aptstack`) → `make-release.ps1` เพิ่ม `--prefix=aptstack/` ให้แตกได้เป็น
  `D:\aptstack\` ตรงตามทุกคู่มือ · อัปเดตชื่อ zip ใน SCENARIO/OFFLINE-DEPLOY เป็น 1.3.0

---

## 1.2.0 — 2026-10-22

ตัวอย่างแอป + คู่มือ scenario + ติดตั้ง PHP อัตโนมัติ

### Added

- **ตัวอย่างแอปเพิ่ม 2 ตัว** (รวม 3) ติดตั้งด้วย `aptstack samples`
  - `todo-app` — Todolist CRUD ใช้ database จริง (ตาราง `todo_items` ใน `examples/seed.sql`)
  - `sysinfo-app` — inventory เครื่องคร่าว ๆ: hostname/OS/uptime, **IPv4/subnet/gateway/DNS**
    (นับ hosts จาก subnet mask), CPU/cores/threads, RAM, disk free, PHP/Apache/DB version
    (ใช้ `ipconfig` + **PowerShell CIM** — ไม่ใช้ `wmic` ที่ถูกถอดออกจาก Win11 24H2)
- **`aptstack add php <version>`** — ใส่แค่เลขเวอร์ชัน (หรือ `latest`) ระบบเติม URL ทางการเอง
  (releases → fallback archives) แล้ว **โหลด + แตก + ติดตั้ง** ให้ในคำสั่งเดียว
  · `add mysql <version>` ทำได้เช่นกัน (archive.mariadb.org)
- **บันทึก + แสดงแหล่งที่มา** — ทุกครั้งที่ `add` จะเขียน `.aptstack-source` ไว้ในโฟลเดอร์นั้น
  แล้ว `aptstack list` แสดงบรรทัด `from: <url>` → copy ไปโหลดเองภายหลังได้
- **`aptstack samples`** — ติดตั้งตัวอย่างทั้งหมดใน `examples\` (ข้ามตัวที่มีแล้ว)
  · `init` เรียกให้อัตโนมัติเมื่อ `versions\` ยังว่าง
- **`docs/SCENARIO.md`** — walkthrough ยาว: แตก ZIP → ใส่ binary → เริ่ม → เล่น 3 แอป
  → สลับแอป → **ตั้งชื่อ version อย่างไร** → เพิ่มแอปตัวเอง → vhost/HTTPS → Service → backup
- **`aptstack list`** แสดง path เต็มของทุก app + section "โฟลเดอร์" (วาง/ลบอะไรตรงไหน)

### Fixed

- **`Start-Db`: MariaDB datadir init พัง** — เคยเรียก `mysqld --initialize-insecure` ซึ่งเป็น
  ของ MySQL เท่านั้น → MariaDB ตอบ `unknown option` exit 2 (เจอตอน `migrate` ไป engine ใหม่)
  · ตอนนี้ใช้ `mysql_install_db.exe -d<datadir> -p<password>` ถ้ามี (MariaDB) และ fallback
  `--initialize-insecure` เฉพาะ MySQL · datadir ที่ init ค้างจะถูกล้างก่อน
  · **ทดสอบ end-to-end แล้ว**: `migrate mysql 11.4.13 → 10.11.19` dump/restore ครบ
    (`aptstack_demo`: greetings 3 · todo_items 18) แล้ว `use mysql 11.4.13` rollback ได้

- `sysinfo-app`: CPU/RAM ไม่แสดงบนเครื่องที่ไม่มี `wmic` → เปลี่ยนเป็น PowerShell CIM
- seed รายงานเลขแถวสุดท้ายผิด label (มี 2 SELECT ในไฟล์เดียว)

### Docs

- `docs/คู่มือ.md` + `.html`, `README-TH.md`, `README.md` — เพิ่มตัวอย่าง 3 แอป,
  การตั้งชื่อ version, `samples`, `add php <version>`, การยืนยันว่าทุกโฟลเดอร์อยู่ใน ZIP

---

## 1.1.0 — 2026-10-22

เพิ่มฟีเจอร์ตาม `prompt02.txt` (รายการที่ devstack ยังไม่มี)

### Added

- **HTTPS / TLS** — `aptstack tls status | init | import | on | off`
  - `tls init` สร้าง self-signed cert ด้วย `openssl.exe` ที่มากับ Apache
    (ใช้ `mkcert` ถ้ามี) อายุ 365 วัน + SAN อัตโนมัติจาก `vhosts.json`
  - **ใส่ cert เข้า Trusted Root ของผู้ใช้ให้** → .NET/browser เชื่อถือ
    (การปลดด้วย `ServerCertificateValidationCallback` ใช้ไม่ได้จริงบน PS 5.1 — ทดสอบแล้ว)
  - `tls import <cert.pem> <key.pem>` รับ **SSL cert จริง** (Let's Encrypt / พาณิชย์)
  - `doctor` เช็ค cert หมดอายุ / private key / trust / probe HTTPS จริง
- **Virtual hosts** — `config\vhosts.json` → generate `<VirtualHost>` (HTTP + HTTPS)
  - ใส่ default vhost ไว้ก่อนเสมอ จึงไม่ทำให้ `http://127.0.0.1:port/` เพี้ยน
  - `doctor` ตรวจนับ + ตรวจว่า app มีอยู่จริง + บอกบรรทัด hosts file
- **`aptstack logs <apache|mysql|php|all> [จำนวนบรรทัด]`** — ดูท้ายไฟล์ + ไฮไลต์ error
- **health probe หลัง start** — แทนการรอแบบ blind:
  HTTP/HTTPS GET จริง (รายงาน 200 + ms) และ `ping` database ผ่าน client
- `examples/vhosts.sample.json`

### Fixed

- **`Start-Db`: MariaDB datadir init พัง** — เคยเรียก `mysqld --initialize-insecure` ซึ่งเป็น
  ของ MySQL เท่านั้น → MariaDB ตอบ `unknown option` exit 2 (เจอตอน `migrate` ไป engine ใหม่)
  · ตอนนี้ใช้ `mysql_install_db.exe -d<datadir> -p<password>` ถ้ามี (MariaDB) และ fallback
  `--initialize-insecure` เฉพาะ MySQL · datadir ที่ init ค้างจะถูกล้างก่อน
  · **ทดสอบ end-to-end แล้ว**: `migrate mysql 11.4.13 → 10.11.19` dump/restore ครบ
    (`aptstack_demo`: greetings 3 · todo_items 18) แล้ว `use mysql 11.4.13` rollback ได้

- 🔴 **extension โหลดไม่ได้ใต้ Apache** (`curl`/`intl`/`sodium`/`sqlite3` …)
  เพราะ Windows หา dependency DLL จาก PATH ของ process ที่โหลด → prepend PATH ของ PHP
  (ตรวจแล้ว extension ครบ 12/12 ใต้ `apache2handler`)
- `openssl.exe` ค้น config ที่ path compile-time (`C:\Apache24\conf`) → ชี้ `OPENSSL_CONF`
- `SSLSessionCache shmcb:` build นี้ฟ้อง `cache size not numerical` ทุกรูปแบบ → ตัดออก
- `doctor` false positives: เช็ค private key ผิด, flag `examples/seed.sql`, แสดงรายการ vhost ว่าง
- `push-github.ps1` สะดุดเมื่อ git เขียน progress ลง stderr (`EAP=Stop`)

### Docs

- `docs/OFFLINE-DEPLOY.md` **(ใหม่)** — แนวทาง deploy แบบ offline/intranet:
  โหลด PHP/Apache/MariaDB บนเครื่องที่มีเน็ต → ย้ายไฟล์ → `add` จาก local path
  (หรือ manual drop-in / internal mirror) + checksum + VC++ runtime + checklist
- `docs/คู่มือ.md` + `.html`: ข้อ 5a (HTTPS) และ 5b (vhosts), คำสั่ง logs/tls,
  หมายเหตุ offline ในข้อ 1 และข้อ 8
- `README.md` (EN), `README-TH.md`, `SECURITY.md`, `docs/ABOUT-TH.md`,
  `docs/เปรียบเทียบ-devstack.md` (ตารางเทียบฟีเจอร์ปรับเป็นของจริงทั้งหมด)
- ตัดชื่อ/URL ของระบบจริงที่ hardcode อยู่ในเอกสารและโค้ด ออกทั้งหมด
  (default `appAlias` เป็น `app` — ไม่มีชื่อระบบเฉพาะเจาะจงเหลือใน package)

---

## 1.0.0 — 2026-10-22

First public release. Portable PHP / MariaDB stack for Windows with
app-version switching and Windows Service install.

### Added

- **App version switching** — `versions\<ver>` + junction ที่ `www\<appAlias>`
  `aptstack use <ver>` / `use -` / `next` / `prev`
- **PHP switching** — `aptstack add php <zip|url>` + `aptstack use php <ver>` (restart ให้เอง)
- **Apache + mod_php** — `aptstack add apache <zip>` + `aptstack use apache <ver>`
  `webMode`: `auto` | `apache` | `builtin`
- **MySQL/MariaDB switching** — `aptstack add mysql <zip>` + `aptstack use mysql <ver>`
  datadir แยกต่อ version (`data\<engine>`) · `dbMode`: `internal` | `external`
  (`external` = ยืม MySQL ของ XAMPP โดยไม่ start/stop/kill ของคนอื่น)
- **Windows Service** — compile เองด้วย `csc.exe` (ไม่ต้องโหลด NSSM/WinSW)
  `aptstack service install|uninstall|start|stop|status`
- **`aptstack doctor`** — ตรวจตาม `security-php.txt` + `security-php2.txt`
  (เกณฑ์ PHP, mitigation คู่ของ PHP2Shell, path ภายใน bundle, git leak, IOC ใน log)
- **`aptstack seed`** + `examples/hello-app` + `examples/seed.sql`
  ตัวอย่างเล็กพอพิสูจน์ว่า web + PHP + database รันได้
- `aptstack backup [file]` → `data\dumps\`
- คู่มือ: `README.md`, `README-TH.md`, `SECURITY.md`, `docs/คู่มือ.md`, `docs/คู่มือ.html`

### Design

- `templates\` = ต้นฉบับ (commit) · `config\` = ค่าจริง + ของ generate (ไม่ commit)
- `stack\` = binary · `versions\` = โค้ดแอป · `data\` = database — แยกจากกัน
- `php.ini`, `my.ini`, `httpd.conf` **generate ใหม่ทุกครั้งที่ start** → copy ไปเครื่องอื่นไม่พัง
- `config/stack.json` เขียนแบบ UTF-8 ไม่มี BOM (PHP `json_decode()` คืน null ถ้ามี BOM)

### Not included (by design)

- โค้ดแอปจริง / datadir จริง / SQL dump จริง / binary (PHP, MariaDB, Apache, phpMyAdmin)
  → `.gitignore` กันไว้ + `doctor` เช็คซ้ำไม่ให้หลุดขึ้น repo สาธารณะ
