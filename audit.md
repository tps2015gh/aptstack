# audit.md — รายงานตรวจความปลอดภัย (security audit)

> ขอบเขต: **ตัว aptstack (runtime/แพ็กเกจ)** — ไม่รวม static review โค้ดแอป (แยกขอบเขต)
> อ้างอิง: `security-php.txt` (PHP RCE CVSS 9.2) และ `security-php2.txt`
> (https://www.aikido.dev/blog/critical-vulnerabilities-in-php-php2shell)
> คู่: [SECURITY.md](SECURITY.md) (คู่มือ) · [review.md](review.md) (ตัวโค้ด)

---

## 1. วิธีตรวจสอบ

| ทำอะไร | อย่างไร |
|---|---|
| ตรวจค่า PHP จริง | `ini_get()` ผ่าน **web SAPI จริง** (`cli-server`/`apache2handler`) ไม่ใช่แค่อ่านไฟล์ |
| ตรวจ version floor | `Get-PhpRisk` เทียบ 8.5.12/8.4.27/8.3.36/8.2.35 (±ฝั่ง fail ทดสอบกับ 8.1.34 ด้วย) |
| ตรวจ path ชี้นอก bundle | regex ทุกค่า `X:\...` ใน `my.ini`/`php.ini` เทียบกับ root |
| ตรวจของ sensitive หลุด git | `git ls-files` + pattern `stack/versions/data/config/*.sql` (+ ยกเว้น `examples/*`) |
| ตรวจชื่อระบบจริงในไฟล์ track | grep ชื่อ/รหัส/ชื่อ DB เดิมของระบบงาน = **0 ผล** |
| ตรวจ TLS | อ่าน cert ด้วย `X509Certificate2` (subject/expiry/private key/trust) + `openssl s_client` handshake จริง + HTTP probe จริง |
| ตรวจ network exposure | `bind-address` ใน my.ini + พอร์ตฟังเฉพาะ localhost ไหม |
| หลัง patch | ตรวจ `logs\php-error.log` หา IOC (memory-limit error) |

---

## 2. ทรัพย์สินและเส้นแบ่งความเชื่อถือ

| ทรัพย์สิน | ความไว | ช่องทางเข้าถึง |
|---|---|---|
| `data\<engine>\` (ฐานข้อมูลจริง) | สูงมาก | localhost:3307 เท่านั้น (ตามค่าตั้งต้น) |
| `data\dumps\*.sql` | สูงมาก | ไฟล์บนดิสก์ · gitignore กัน commit |
| `config\stack.json` (มีรหัสผ่าน DB) | สูง | ใครอ่านโฟลเดอร์ได้ → อ่านได้ (ไม่เข้ารหัส) |
| `config\certs\*-key.pem` | สูง | private key ของ TLS |
| `versions\` (โค้ดแอป) | กลาง | เสิร์ฟผ่าน web root |
| `stack\` (binary ภายนอก) | กลาง (supply chain) | โหลดจากแหล่งทางการ |
| `www\` (docroot) | กลาง | HTTP/HTTPS localhost |

**เส้นขอบ:** ภายนอกเข้าถึงได้เฉพาะ `127.0.0.1:8077/8443` (ถ้าเปิด firewall ออก = เปลี่ยนเป็นสาธารณะ)

---

## 3. Compliance matrix — `security-php.txt`

| ข้อกำหนด | สถานะ | หลักฐาน |
|---|---|---|
| PHP ≥ 8.5.12 / 8.4.27 / 8.3.36 / 8.2.35 | ✅ | active = **8.3.36** (`php -v` จริง) |
| PHP ≤ 8.1 = EOL ห้าม production | ✅ | `Get-PhpRisk` → `doctor` คืน `[ERR]` 2 จุดเมื่อสลับไป 8.1.34 (**ทดสอบแล้ว**) |
| อัปเดตแล้ว restart worker | ✅ | `use php` / `start` / `restart` restart ให้เอง + probe ยืนยัน 200 |
| ยังอัปเดตไม่ได้ → แยกออกจากระบบเสี่ยง | ✅ (ออกแบบ) | web + DB bind `127.0.0.1` |
| แค่หน้า "ปิดปรับปรุง" ไม่พอ | ✅ | ไม่ได้ทำ — patch ที่ runtime |

## 4. Compliance matrix — `security-php2.txt` (PHP2Shell)

| ข้อกำหนด | สถานะ | หลักฐาน |
|---|---|---|
| Update + rebuild/restart | ✅ | 8.3.36 + auto restart + health probe |
| **mod_php = ความเสี่ยงสูงสุด** (ตาม PHP team) | ⚠️ ใช้งาน | ใช้ mod_php **แต่ patch แล้ว**; ยังคงมี `webMode=builtin` ให้เลี่ยงได้ |
| `session.upload_progress.enabled = 0` | ✅ | `Off` ยืนยันผ่าน `ini_get` บน web SAPI |
| `memory_limit = -1` (คู่กัน ถ้า patch ไม่ได้) | ⏸ เงื่อนไข | **patch แล้ว → จงใจไม่ตั้ง** (กัน DoS) `doctor` จะ **[ERR] ถ้าเจอบน PHP ที่ยังไม่ patch** |
| ตั้งค่าให้แอป override ไม่ได้ | ⚠️ บางส่วน | ค่าอยู่ใน `config\php.ini` (ต้นทางเดียว) แต่ `ini_set()` ในแอปยังทำได้ |
| block `multipart` ถ้าไม่ใช้ upload | ❌ | แอปใช้อัปโหลด → ใช้ไม่ได้ |
| low `post_max_size` | ⚠️ 64M | ลดเหลือ 8M ได้ถ้าไม่จำเป็น |
| หลัง patch: ไล่ IOC | ✅ (ครึ่งหนึ่ง) | `doctor` นับ memory-limit error ใน log + checklist มือใน SECURITY.md §8 |
| rotate secret ถ้าเปิดออกเน็ต | ⚠️ manual | ยังไม่ได้ทำ (ยังไม่ได้เปิดออกเน็ต) |

**ค่าจริงที่วัดได้ (web SAPI):**
```
session.upload_progress.enabled = Off   expose_php = Off   allow_url_include = Off
display_errors = Off   log_errors = On   memory_limit = 512M   max_execution_time = 60
PHP 8.3.36 · ZTS · mysqli/pdo_mysql/curl/gd/openssl/mbstring/intl/zip = loaded
```

---

## 5. ควบคุมที่ implement แล้ว (ฝั่ง aptstack)

1. **เครือข่าย** — MariaDB `bind-address=127.0.0.1`, `local_infile=0`, `symbolic-links=0`,
   `skip-name-resolve` · Apache listen 8077/8443 (จำกัด `Require local` ที่ `/server-status`)
2. **PHP hardening** จาก `templates/php-hardening.ini` ( regenerate ทุก start )
3. **Directory protection** ใน `httpd.conf` — บล็อก `.ht/.env/.git`, `.sql/.ini/.log/.pem/.key`
   + `RedirectMatch 404 ^/(config|stack|versions|data|logs|templates|bin)`
4. **headers** — `X-Content-Type-Options`, `X-Frame-Options`, (TLS) `Strict-Transport-Security`
5. **ทำลายข้อมูลต้องยืนยัน** — `Confirm-Action` 2 ชั้น + พิมพ์ `DELETE` สำหรับ datadir +
   กัน path traversal (`Guard-Name`) + เช็ค path อยู่ใน root ของตัวเองก่อน `Remove-Item`
6. **กันของ sensitive หลุด repo** — `.gitignore` + `doctor` + ขั้นตอนก่อน commit
7. **service** — `sc failure` restart อัตโนมัติ, ปิด clean ผ่าน stop-flag
8. **TLS** — `tls init` สร้าง cert `CA:FALSE` + SAN ครบ + **trust เฉพาะผู้ใช้**,
   `tls import` สำหรับ cert จริง, `doctor` เตือนอายุ < 14 วัน

---

## 6. Risk register (สิ่งที่ยังเป็นความเสี่ยง)

| # | ความเสี่ยง | ระดับ | สถานะ / บรรเทา |
|---|---|---|---|
| R1 | **`root/root` ค่าเริ่มต้น** | สูง | ยังไม่แก้ — **บังคับเปลี่ยนก่อนขึ้นจริง** (checklist) |
| R2 | `config\stack.json` มีรหัสผ่าน DB **เปล่า** | สูง | อยู่ในโฟลเดอร์สิทธิ์ผู้ใช้; ห้ามแชร์โฟลเดอร์ / commit |
| R3 | **binary โหลดจากเน็ตไม่ verify checksum อัตโนมัติ** | กลาง-สูง | มีแค่แนะนำให้เทียบ `sha256sum.txt` → **รายการงานค้าง** (review.md §4.4) |
| R4 | service รันเป็น **LocalSystem** | กลาง | ถ้า bundle ถูกแทรก = ได้สิทธิ์สูงสุด → รักษาสิทธิ์โฟลเดอร์, อย่าให้ user ทั่วไปเขียนได้ |
| R5 | ยังไม่มี HTTPS โดยปริยาย | กลาง | ถ้าเปิดออกเน็ตต้อง `tls init/import` + reverse proxy |
| R6 | phpMyAdmin อยู่ใน `www\` (ถ้ามี) | กลาง | เป็นเครื่องมือ admin บน port เดียวกับเว็บ → ควรใส่ auth/จำกัด IP หรือเอาออกบน production |
| R7 | PHP `shell_exec` เปิดใช้งาน (sysinfo ตัวอย่างใช้) | กลาง | ตัวอย่างไม่รับ input จากผู้ใช้; ถ้าแอปจริงไม่ใช้ ให้ใส่ใน `disable_functions` |
| R8 | ข้อมูลจริงอยู่บนดิสก์ (`data\`, dumps) | สูง (ข้อมูล) | gitignore กัน commit แล้ว — แต่**การเข้ารหัสดิสก์/สิทธิ์โฟลเดอร์** ต้องดูแลเอง |
| R9 | `versions\` ถูกเสิร์ฟเป็น docroot (ผ่าน junction) | กลาง | มี `RedirectMatch 404` กันพาธระบบ + `AllowOverride` เปิดให้แอปใช้ `.htaccess` |
| R10 | self-signed trust อยู่ที่ผู้ใช้ปัจจุบันเท่านั้น | ต่ำ | ถ้าย้ายผู้ใช้/เครื่อง ต้อง `tls init` ใหม่ |

---

## 7. Checklist ก่อนเปิดใช้จริง (production gate)

```cmd
aptstack doctor              :: ต้องไม่มี [ERR]
:: เปลี่ยนรหัสผ่าน DB root แล้วแก้ dbPass ใน config\stack.json
:: ตั้ง firewall: เปิดเฉพาะ 8077/8443 (ถ้าจำเป็นจริง) — ค่าเริ่มต้น bind localhost
aptstack tls init            :: หรือ tls import cert จริง (ถ้าเปิดออกเน็ต)
aptstack backup              :: dump ก่อน deploy เสมอ
aptstack service install && aptstack service start
aptstack report              :: เก็บ HTML ไว้เป็นหลักฐานการตรวจ
```

- [ ] PHP patch + Thread Safe (ถ้าใช้ mod_php)
- [ ] รหัสผ่าน DB เปลี่ยนแล้ว
- [ ] checksum ของ binary ตรง (manual จนกว่าจะมี auto-verify)
- [ ] สิทธิ์โฟลเดอร์: เฉพาะ admin อ่าน-เขียน
- [ ] ตรวจ logs หลัง patch หา IOC (memory-limit error, 500 ซ้ำ, PHPSESSID แปลก)
- [ ] rotate secret ถ้าเว็บเคยเปิดออกอินเทอร์เน็ตก่อนหน้านี้

---

## 8. ข้อจำกัดของ audit นี้

- ตรวจ**ตัว stack** ไม่ใช่โค้ดแอป → SQLi/XSS/IDOR ในแอป **ยังไม่ถูกตรวจ**
- ยังไม่ได้ทดสอบการเจาะจริง (penetration test)
- ทดสอบบน Win11 เดียว — พฤติกรรมสิทธิ์/firewall บน Windows Server อาจต่าง
- ไม่ได้ตรวจสอบ supply chain ของ PHP/Apache/MariaDB ระดับ provenance (แค่แนะนำ checksum)

*audit นี้จัดทำจากผลรันจริงระหว่างพัฒนา · อัปเดตล่าสุดพร้อม v1.2.0+*
