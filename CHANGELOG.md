# Changelog

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
