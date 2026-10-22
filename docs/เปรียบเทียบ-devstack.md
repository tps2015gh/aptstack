# เปรียบเทียบ devstack (Hermes) vs aptstack

> อ้างอิงไฟล์จริง: `devstack-1.1.0-from-hermes.zip`, `devstack-1.2.0-from-hermes.zip`
> และ `APT-Standalone` (ต้นแบบฝั่งแอป ระบบงานของหน่วยงาน)

---

## 1. devstack 1.1.0 → 1.2.0 เปลี่ยนอะไรบ้าง

| เรื่อง | 1.1.0 | 1.2.0 |
|---|---|---|
| `config.json` | `php, phpPrev?, mysql, apache, httpPort, mysqlPort` | เพิ่ม **`phpPrev`** ชัดเจน (จำตัวก่อนหน้า) |
| ทางลัดสั้น | มีแค่ `devstack.cmd` | เพิ่ม **`ds.cmd`** |
| วิธีเรียกสลับ PHP | `devstack php use 8.4.27` | **`devstack use 8.4.27`** (สั้นลง) |
| เมนูเลือก version | ยังไม่มี | เพิ่ม **`Select-PhpInteractive`** (พิมพ์เลข) |
| ย้อนกลับตัวก่อนหน้า | ไม่มี | **`devstack use -`** |
| วน version | ไม่มี | **`devstack next` / `prev`** |
| โค้ด `devstack.ps1` | ~24.7 KB | ~29.2 KB (+154 บรรทัดที่แก้/เพิ่ม) |
| คู่มือ / README / ai.md | สั้นกว่า | ขยาย (`คู่มือ.md` 25.2 → 28.2 KB) |
| `templates\*`, `www\index.php`, `.gitignore` | — | **ไม่เปลี่ยนเลย** (binary เท่ากันเป๊ะ) |

**สรุป:** 1.2.0 คือ 1.1.0 + "สลับเวอร์ชันให้ง่ายขึ้น" (เมนู, `use -`, `next/prev`)
**ยังไม่มี** ทั้งสองเวอร์ชัน: Windows Service, สลับเวอร์ชันแอป, ระบบ security check

---

## 2. APT-Standalone (ของเดิม) vs devstack vs aptstack

| | APT-Standalone | devstack 1.2.0 | **aptstack** |
|---|---|---|---|
| ประเภท | bundle พร้อมโค้ดแอป + DB | tool จัดการ version ล้วน | **tool + bundle** |
| ติดตั้ง | copy แล้วรัน `start-all.bat` | copy แล้ว `add` binary เอง | copy แล้ว `start` |
| PHP ในนั้น | 8.1.34 ตัวเดียว | โหลดเองหลายตัว | **8.3.36 + 8.1.34** หลายตัว |
| Web server | PHP built-in พอร์ต 8077 | Apache + mod_php (8080) | PHP built-in 8077 |
| Database | MariaDB 11.4 (3307) | MySQL/MariaDB หลายตัว | MariaDB หลายตัว **หรือ** ยืมของ XAMPP |
| phpMyAdmin | มี | ไม่มี | **มี** (`/phpmyadmin/`) |
| **สลับเวอร์ชันแอป** | ❌ | ❌ | ✅ **junction → `versions\<ver>`** |
| สลับ PHP | ❌ (ตัวเดียว) | ✅ `use 8.3.36` | ✅ `use php 8.3.36` |
| ย้อนกลับ | ❌ | ✅ `use -` | ✅ **ทั้งแอปและ PHP** |
| **Windows Service** | ❌ | ❌ | ✅ `service install` |
| ตรวจช่องโหว่ PHP | ❌ | ⚠️ เตือนตอน `list`/`use` | ✅ **`doctor` ตรวจ + fail** |
| path ตายตัวใน config | ❌ `my.ini` ชี้ `C:\NoteBook1\...` และ `E:\` → **copy ไปเครื่องอื่นพัง** | ⚠️ generate เฉพาะ `php.ini`/`httpd.conf` | ✅ generate ทั้ง `php.ini` + `my.ini` ทุก start |
| แยก datadir | ❌ อยู่ในโฟลเดอร์ binary | ✅ `data\mysql-<ver>` | ✅ **`data\<engine>` + `data\dumps`** |
| config รวมที่เดียว | ❌ กระจาย | ❌ `config.json` + `runtime\` | ✅ **`config\` ทั้งหมด** |
| ข้อมูลจริงหลุด git | — | — | ✅ `.gitignore` กัน + `doctor` เช็คซ้ำ |

---

## 3. สิ่งที่ aptstack หยิบมาจาก devstack (ให้เครดิต)

- โครงคิด `templates\` = ต้นฉบับ / `config\` (ของ devstack คือ `runtime\`) = generate ใหม่เสมอ
- UX คำสั่ง: `add` / `use` / `list` / `start` / `doctor` / ทางลัด `ds` (`as` ของ aptstack)
- `use -` ย้อนกลับ, `next`/`prev`, เมนูเลือกด้วยเลข
- ตารางเลขเวอร์ชันปลอดภัยของ PHP (8.5.12 / 8.4.27 / 8.3.36 / 8.2.35)
- `devstack.cmd` แบบ `-ExecutionPolicy Bypass` ไม่แก้ policy ถาวร

## 4. สิ่งที่ aptstack เพิ่มเอง

1. **สลับเวอร์ชันแอป** ด้วย junction → rollback ได้ทันที
2. **Windows Service** compile เองด้วย `csc.exe` (ไม่ต้อง NSSM/WinSW)
3. **`dbMode: external`** — ยืม MySQL ของ XAMPP ได้โดยไม่ kill ของคนอื่น
4. **`doctor` แบบ fail ได้** — เช็คตาม `security-php.txt` + `security-php2.txt`
   (patch version, mitigation ครบ, path ใน bundle, git ไม่มีของ sensitive, IOC ใน log)
5. **config รวมที่เดียว** (`config\stack.json`) + **data แยกจาก binary** (`data\`)
6. **phpMyAdmin + router.php** ที่ปรับให้ CodeIgniter รันบน built-in server ได้

---

## 5. ยังไม่รองรับ (เทียบ devstack)

| เรื่อง | devstack | aptstack |
|---|---|---|
| Apache | ✅ มี template ครบ | ❌ ยังใช้ PHP built-in (single-threaded) |
| HTTPS | ❌ (แนะนำ mkcert) | ❌ เหมือนกัน |
| auto virtual-host | ❌ | ❌ |
| โหลด MySQL/Apache ผ่าน URL | ✅ | ⚠️ `add` รับ URL ได้แต่ยังไม่ได้ทดสอบ MySQL/Apache |

> ถ้าต้องขึ้น production → ควรเพิ่ม **Apache + mod_php** (PHP TS ที่โหลดมามี
> `php8apache2_4.dll` อยู่แล้ว) แล้วเอา `httpd.conf.tpl` ของ devstack มาปรับ
