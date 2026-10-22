# Changelog

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
