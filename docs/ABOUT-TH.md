# เกี่ยวกับโปรเจกต์นี้ — ใครสร้าง สร้างด้วยอะไร และความเห็นต่อ repo

> กลับไปหน้าแรก: [README-TH.md](../README-TH.md) · คู่มือ [docs/คู่มือ.md](คู่มือ.md) ·
> เทียบกับ devstack [docs/เปรียบเทียบ-devstack.md](เปรียบเทียบ-devstack.md)

---

## 1. เครดิต: สร้างด้วยอะไร / ที่ไหน

| โปรเจกต์ | Model ที่ใช้สร้าง | รันบน | หมายเหตุ |
|---|---|---|---|
| **aptstack** (repo นี้) | **MiMo-V2.6-Flash** | **MimoCode** | พัฒนาต่อจาก APT-Standalone + ยืมแนวคิดจาก devstack |
| **devstack 1.1.0 / 1.2.0** | **deepseek-v4.1-flash** | **opencode-go** (ทีม Hermes) | ต้นแบบแนวคิด "สลับ version ด้วยคำสั่งเดียว" + ตารางเวอร์ชัน PHP ปลอดภัย |
| **APT-Standalone** | — | — | ต้นแบบฝั่งแอปจริง (bundle คล้าย XAMPP: MariaDB 3307 + PHP built-in 8077 + phpMyAdmin) |

**หลักการที่ยึด:** ให้เครดิตของจริง —
`templates/` แบบ generate-ใหม่-ทุกครั้ง, UX คำสั่ง `add`/`use`/`list`/`doctor`,
`use -` ย้อนกลับ, `next`/`prev`, เมนูเลือกด้วยเลข และตารางเลข version ปลอดภัยของ PHP
**ล้วนมาจากระบบของ devstack (ทีม Hermes)** รายละเอียดเทียบให้ครบใน
[เปรียบเทียบ-devstack.md](เปรียบเทียบ-devstack.md)

ส่วนที่ **aptstack เพิ่มเอง** ดูหัวข้อ 3

---

## 2. ทำไมถึงมี repo นี้

ปัญหาจริงที่เจอจากของเดิม:

1. **`APT-Standalone`** รันได้ แต่ `my.ini` hardcode path เป็น
   `C:\NoteBook1\2569-10-18-...` และ `E:\...` → **copy ไปเครื่องอื่นค้างทันที**
2. **PHP 8.1.34** ที่ติดมา = **EOL** → ชนข้อกำหนด `security-php.txt`
   (RCE ระดับ CVSS 9.2, ไม่มี patch ให้ 8.1)
3. **สลับ version ไม่ได้เลย** — แอปตัวเดียว, PHP ตัวเดียว ทดสอบหลายรุ่นไม่ได้
4. **ไม่มี Windows Service** — ต้อง double-click `start-all.bat` ทุกครั้ง
5. ของเดิม **ไม่มีระบบกันข้อมูลจริงหลุด git** (datadir + dump 81MB อยู่ในโฟลเดอร์เดียวกับโค้ด)

repo นี้แก้ทั้ง 5 ข้อ และตั้งเป็น **ของที่ copy ไป server แล้วใช้ได้จริง**

---

## 3. จุดเด่น (ความเห็นตรง ๆ)

### จุดเด่นอันดับต้น ๆ

1. **Copy-to-deploy จริง ๆ**
   `config\php.ini`, `config\my.ini`, `config\httpd.conf` **generate ใหม่ทุกครั้งที่ start**
   → ไม่มี path ตายตัวค้างอยู่ในไฟล์ config ย้ายเครื่อง/ย้าย drive แล้วไม่พัง
   (`doctor` เช็คให้ด้วยว่าไม่มีไฟล์ไหนชี้ออกจากโฟลเดอร์)

2. **สลับได้ 4 อย่าง ด้วยคำสั่งเดียว แล้ว rollback ทันที**

   ```cmd
   aptstack use 1.2.0        :: app
   aptstack use php 8.3.36   :: PHP
   aptstack use apache 2.4.69
   aptstack use mysql 11.4.13
   aptstack use -            :: ย้อนกลับ
   ```

   แอปเปลี่ยนด้วย **junction** → ของเก่าอยู่ครบ → ย้อนกลับได้เสมอ
   MySQL มี **datadir แยกต่อ version** → สลับแล้วข้อมูลไม่ปน/ไม่ถูก upgrade ผิดตัว

3. **`doctor` ที่ fail ได้ ไม่ใช่แค่เตือน**
   เช็คตาม `security-php.txt` **และ** `security-php2.txt` (PHP2Shell):
   เกณฑ์ version, mitigation คู่ (`session.upload_progress=Off` + `memory_limit=-1`
   *เฉพาะตอนยัง patch ไม่ได้*), path ใน bundle, โค้ด/ dump หลุด git, IOC ใน log
   → ทดสอบแล้วทั้งฝั่งผ่าน (8.3.36) และฝั่ง fail (8.1.34 = 2 [ERR])

4. **Windows Service โดยไม่ต้องพึ่งอะไรเพิ่ม**
   compile `service\AptStackService.cs` ด้วย `csc.exe` ที่มากับ Windows
   → ไม่ต้องโหลด NSSM/WinSW, ปิด stack แบบ clean ผ่าน stop-flag, `sc failure` ให้ restart เอง

5. **ยืม MySQL ของ XAMPP ได้โดยไม่ kill ของคนอื่น**
   `"dbMode": "external"` → aptstack จะไม่ start/stop แตะ port นั้นเลย
   (เหมาะกับเครื่องที่มี XAMPP อยู่แล้ว)

6. **กันข้อมูลจริงออกจาก public repo เป็นระบบ**
   `.gitignore` + `doctor` เช็คซ้ำ + `git archive` ตอน build release
   → release zip มี **26 ไฟล์ / 63KB** (scripts + templates + docs + ตัวอย่าง)
   ไม่มีทางเผลอเอา datadir / dump / โค้ดแอป ขึ้นไปได้เลย

### สิ่งที่ทำให้ใช้ได้จริงภายใน 5 นาที

- `examples/hello-app` + `examples/seed.sql` + `aptstack seed`
  → แตก zip → `init` → `start` → `seed` → เปิดหน้าเว็บ
  **เห็นตาราง greetings จาก database = พิสูจน์ web+PHP+DB รันได้จริง** (ทดสอบแล้ว)

---

## 4. ข้อจำกัดที่ควรรู้ (พูดตรง ๆ)

| ข้อจำกัด | ผลกระทบ | ทางแก้ |
|---|---|---|
| **HTTPS ยังไม่ได้เปิดโดยปริยาย** | ต้องสั่งเอง: `aptstack tls init` (self-signed) หรือ `tls import` (cert จริง) | มีให้แล้วตั้งแต่ 1.1.0 — ใช้ได้กับ `webMode=apache` เท่านั้น |
| **release ไม่ได้แถม binary** | ต้องโหลด PHP/Apache เอง (~50MB) | คู่มือมีลิงก์ + `add php/apache <zip>` |
| **PHP 8.1 ยังอยู่ใน `stack\php\8.1.34`** | ถ้าเผลอ `use php 8.1.34` = ผ่านเกณฑ์ไม่ได้ | `doctor` จะ **[ERR] ทันที** — เก็บไว้เทียบโค้ดเก่าเท่านั้น |
| **โค้ดแอปจริง (CodeIgniter 3) รันบน PHP 8.2+ ไม่ได้ทันที** | deprecation หยุด request | แก้ 1 บรรทัดใน `index.php` (คู่มือข้อ 4) |
| **`root/root` เป็นค่าเริ่มต้น** | อันตรายถ้าขึ้น server จริง | เปลี่ยนรหัสผ่าน + แก้ `config\stack.json` |
| **app ยังไม่ผ่าน static security review** | SQL injection/XSS ฝั่งแอป ไม่เกี่ยวกับตัว stack | ดูรายงานฝั่งแอปแยก |
| **ทดสอบบน Windows เดียว** | ยังไม่ได้ลองบน Server ที่ไม่ใช่ Win11 | ลอง `setup.ps1` + `doctor` ก่อนใช้จริง |

**สิ่งที่ repo นี้ไม่ใช่:** ไม่ใช่ตัวแก้ช่องโหว่ในโค้ดแอป
ไม่ใช่ WAF ไม่ใช่ตัวแทนการแพตช์ — มันคือ **ตัวจัดการ runtime ที่บังคับให้ PHP patch
และสลับเวอร์ชันได้โดยไม่พัง**

---

## 5. เมื่อไหร่ควรใช้ / ไม่ควรใช้

**ควรใช้**

- ต้อง **สลับ PHP / เวอร์ชันแอป บ่อย ๆ** เพื่อเทียบของเก่า-ใหม่
- มี **server ในเครื่องเดียวหลายตัว** (XAMPP อยู่แล้ว + ตัวใหม่) → `dbMode external`
- ต้องการ **rollback ทันที** เมื่อ deploy แล้วมีปัญหา
- อยากได้ **health check ที่ fail ได้** ก่อนขึ้นของจริง (เช็คช่องโหว่ PHP)

**ไม่ควรใช้**

- ต้องการ web server ระดับ production เต็มรูปแบบ (HTTPS, vhost, load balancing)
  → ใช้ตัวนี้เป็น **ฐาน** แล้วต่อ reverse proxy
- เครื่องต้องรันหลายเว็บไซต์พร้อมกันหลายคนมาก ๆ โดยไม่มี proxy →
  ใช้ `webMode=apache` (mod_php) แทน builtin

---

## 6. สรุปหนึ่งบรรทัด

> **aptstack = APT-Standalone ที่ copy ไป server ได้จริง + devstack ที่สลับได้ทั้งแอป/PHP/Apache/MySQL
> + ชั้นความปลอดภัยที่ fail ได้จริง** — ของเดิมดีอยู่แล้วในทาง "รันได้"
> repo นี้ทำให้ "ย้ายได้ สลับได้ ตรวจได้ และไม่เผลอเอาของจริงขึ้น public"

---

*สร้างด้วย MiMo-V2.6-Flash บน MimoCode · ต้นแบบแนวคิดมาจาก devstack ของทีม Hermes
(สร้างด้วย deepseek-v4.1-flash บน opencode-go) · MIT*
