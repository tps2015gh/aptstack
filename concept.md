# concept.md — แนวคิดและสถาปัตยกรรมของ aptstack

> อ่านคู่กับ [concept] ปฏิบัติจริง → [คู่มือ.md](docs/คู่มือ.md) ·
> เจตนารมณ์ → [soul.md](soul.md) · สำหรับ AI → [ai.md](ai.md)

---

## 1. ปัญหาตั้งต้น

| ปัญหาจากของเดิม (APT-Standalone) | ผลจริง |
|---|---|
| `my.ini` hardcode path `C:\NoteBook1\...`, `E:\` | copy ไปเครื่องอื่น → MariaDB start ไม่ขึ้น |
| PHP 8.1.34 ตัวเดียว | EOL — ไม่มี patch ช่องโหว่ RCE (security-php.txt) |
| ไม่มีระบบ version | ทดสอบหลายรุ่นไม่ได้, rollback ไม่ได้ |
| ไม่มี Windows Service | ต้อง double-click bat ทุกครั้ง |
| โค้ด + datadir + dump อยู่รวมกัน | เสี่ยงข้อมูลจริงหลุดขึ้น repo สาธารณะ |

## 2. แนวคิดหลัก 7 ข้อ

### ① Single-folder bundle
ทุกอย่างอยู่ใต้โฟลเดอร์เดียว (`stack\`, `versions\`, `config\`, `data\`, `logs\`)
→ copy = deploy · ถอน = ลบโฟลเดอร์ · backup = zip โฟลเดอร์เดียว
**ข้อยกเว้นเดียว:** `stack\` (binary) ต้องใส่เองตอนแรก เพราะ release ไม่แถม

### ② Config ที่ generate ใหม่เสมอ (templates → runtime)
`config\php.ini`, `config\my.ini`, `config\httpd.conf` **ไม่ใช่ของจริงที่แก้มือ**
แต่ถูกสร้างใหม่ทุกครั้งที่ `start` จาก `templates\` + path ที่รันจริง
→ ไม่มี path ตายตัวค้าง → **copy ไปเครื่องอื่นไม่พัง**
**กฎทอง:** `templates\` = ต้นฉบับ (commit) · `config\` = ค่า generate (ห้ามแก้)

### ③ เวอร์ชัน = ชื่อโฟลเดอร์ (ไม่มี manifest)
```
versions\1.2.0\          โค้ดแอป (ชื่อโฟลเดอร์ = ชื่อเวอร์ชัน อิสระ 100%)
stack\php\8.3.36\        binary ต่อ version
stack\mysql\mariadb-*\   engine ต่อ version
data\<engine>\           datadir "แยกต่อ engine"
```
- **App:** สลับด้วย **junction** `www\<alias>` → `versions\<active>`
  = เปลี่ยน pointer + restart → ของเก่าอยู่ครบ → `use -` rollback ได้เสมอ
- **DB:** datadir แยก → สลับ engine แล้วข้อมูลไม่ปน/ไม่ถูก upgrade ผิดตัว
- โยกระหว่าง engine ด้วย **logical dump → restore** (`migrate`) ไม่ใช่ copy ไฟล์
  (ไฟล์ InnoDB ห้าม copy ขณะเปิด — ถ้าจะ clone datadir ต้อง `stop` ก่อน)

### ④ Config กลางที่เดียว
`config\stack.json` = app ที่ active, PHP ที่ active, port, `webMode`, `dbMode`, TLS
→ **การต่อ DB อยู่กลาง ไม่ผูกกับแอป** → clone แอปใหม่ = เห็น database ชุดเดิมทันที
(ถ้าอยากแยก DB ต่อแอป ค่อยย้ายไป env ของแอปเอง)

### ⑤ Probe ไม่ใช่ Blind-wait
`start` ไม่ใช่ `sleep 5 แล้วเดาว่าขึ้น` — ยิง HTTP จริง + `mariadb-admin ping`
แล้วรายงาน `200 OK (660 ms)` ถ้า fail → บอกให้เปิด `logs\<ชนิด>`

### ⑥ `doctor` ที่ fail ได้
ไม่ใช่แค่พิมพ์คำเตือนสีเหลือง — คืน `[ERR]` เมื่อ:
PHP ยังไม่ patch · mitigation ของ PHP2Shell ไม่ครบ (เฉพาะตอนยัง patch ไม่ได้) ·
path ใน ini ชี้นอก bundle · โค้ด/ dump หลุด git · HTTPS เปิดแต่ probe ไม่ผ่าน
→ **เอาไว้เป็น gate ก่อนขึ้น production**

### ⑦ ปลอดภัยโดยค่าเริ่มต้น + ทำลายได้ต้องยืนยัน
- MariaDB `bind 127.0.0.1`, `local_infile=0` · hardening php.ini จาก template
- command ที่ลบของจริง (`remove`) → `Confirm-Action` + กัน path traversal +
  กันลบตัวที่ active อยู่ + datadir ต้องยืนยัน `DELETE`
- `.gitignore` + `doctor` เช็คซ้ำ → ข้อมูลจริง/ binary ไม่มีทางหลุดขึ้น public repo

## 3. ผังการรัน

```
aptstack.cmd  ──(Bypass)──►  aptstack.ps1
                              ├── Get-Config  ◄── config\stack.json
                              ├── ensure dirs
                              ├── Start-Db   → generate config\my.ini → mariadbd
                              ├── Start-Web  → generate config\php.ini (+httpd.conf)
                              │                 → httpd (webMode=apache) หรือ php -S (builtin)
                              └── Wait-Healthy → HTTP/HTTPS GET + DB ping
```

**`use <app>` (สำคัญสุด):**
```
resolve versions\<x> → stop web → ย้าย junction www\<alias> → save config
→ start web (generate conf ใหม่) → health probe
```

## 4. การตัดสินใจสำคัญ (และทำไม)

| ตัดสินใจ | ทำไม | ทางเลือกที่ทิ้ง |
|---|---|---|
| junction ไม่ใช่ copy | สลับในเสี้ยววินาที + rollback เสมอ | copy ทั้งโฟลเดอร์ (ช้า/เปลือง) |
| config generate ใหม่ทุกครั้ง | แก้ pain point path hardcode | แก้มือทีละเครื่อง (พลาดง่าย) |
| service = compile `csc.exe` เอง | ไม่ต้องดาวน์โหลด NSSM/WinSW (ใช้ได้ตอน offline) | NSSM (ต้องเน็ต), Task Scheduler (ไม่ใช่ service จริง) |
| HTTPS trust เข้า `CurrentUser\Root` | `ServerCertificateValidationCallback` **ใช้ไม่ได้จริง**ใน PS5.1 (ทดสอบแล้ว) | ปลด cert check (แย่กว่าเดิม) |
| default vhost ใส่ไว้ก่อนเสมอ | Apache เอา vhost ตัวแรกของ port เป็น default → ถ้าไม่ใส่ URL จะเพี้ยน | ไม่มี default (เสี่ยง) |
| `webMode=apache|builtin` | builtin=ง่าย/dev แต่ single-threaded; apache=production | บังคับอย่างเดียว |
| PHP built-in ยังอยู่ | ไม่ต้องมี Apache ก็ลองได้ (ของเดิมเป็นแบบนี้) | ตัดออก |
| seed SQL ผ่าน `-RedirectStandardInput` | PS pipe ทำให้ไทยเป็น `???` | `Get-Content | client` |

## 5. แผนที่โฟลเดอร์ (runtime)

```
config\stack.json      ★ ค่าที่แก้ได้ (version/port/mode/TLS)
config\vhosts.json     ★ virtual host
config\certs\          ★ TLS cert/key
config\php.ini|my.ini|httpd.conf   generate (ห้ามแก้)
config\pids\ tmp\ stop.flag        state ของ service
versions\<ชื่อ>\       โค้ดแอป (junction จาก www\<alias>)
stack\php|apache|mysql binary ต่อ version
data\<engine>\         datadir (แยกต่อ engine)
data\dumps\            *.sql (gitignore)
www\                   docroot: router.php + phpmyadmin + junction
logs\                  php/apache/mariadb error log  ← aptstack logs
```

## 6. ข้อจำกัดที่ยอมรับ (รู้ตัว)

- HTTPS/vhost ใช้ได้กับ `webMode=apache` เท่านั้น (builtin ไม่มี TLS)
- ไม่มี ACME auto-renew, rate limit, WAF, load balancing → ใช้เป็นฐานแล้วต่อ reverse proxy
- ไม่ได้ patch PHP ให้ (ต้องอัปเดต binary เอง) · ไม่ได้แก้ช่องโหว่ในโค้ดแอป
- `root/root` เป็นค่าเริ่มต้น → ต้องเปลี่ยนก่อนขึ้นของจริง
- ทดสอบบน Windows 11 ยังไม่ใช่ Windows Server
