# Deploy แบบ Offline / Intranet — โหลด binary เองแล้ว copy เข้า server

> สำหรับ server ที่**ไม่เปิดช่องให้โหลดไฟล์จาก internet** หรืออยู่ใน intranet ล้วน
> · กลับไป [README-TH.md](../README-TH.md) · คู่มือ [คู่มือ.md](คู่มือ.md)

---

## 0. หลักการ (อ่าน 30 วินาที)

- **aptstack เองไม่ต้องใช้เน็ตตอนรัน** — สิ่งเดียวที่ต้องเน็ตคือ "โหลด binary ครั้งแรก"
- คำสั่ง `add` **รับ path ท้องถิ่นอยู่แล้ว** (ไม่ใช่แค่ URL):

  ```cmd
  aptstack add php   C:\staging\php-8.3.36-Win32-vs16-x64.zip
  aptstack add apache C:\staging\httpd-2.4.69-261002-Win64-VS18.zip
  aptstack add mysql  C:\staging\mariadb-11.4.13-winx64.zip
  ```

- หรือจะ **วางไฟล์เองโดยตรง** ใน `stack\` ก็ได้ (manual drop-in) — ดูข้อ 3
- HTTPS ก็ใช้ได้ offline: `aptstack tls init` ใช้ `openssl.exe` ที่มากับ Apache
  ไม่ต้องโหลดอะไรเพิ่ม (ถ้าไม่มี `mkcert` ก็ไม่เป็นไร)

**ขั้นตอนทั้งหมด = 3 ช่วง:** โหลดบนเครื่องที่มีเน็ต → ย้ายไฟล์ → ติดตั้งบน server

---

## 1. บนเครื่องที่มีเน็ต (prep machine) — โหลดอะไรบ้าง

| ตัว | ลิงก์ | เลือกไฟล์อะไร | ~size |
|---|---|---|---|
| **PHP** | https://windows.php.net/downloads/releases/ | `php-8.3.36-Win32-vs16-x64.zip`<br>⚠️ ตัว **Thread Safe** ห้ามเอา `-nts-` | 33 MB |
| PHP เก่า (เทียบโค้ด) | https://windows.php.net/downloads/releases/archives/ | `php-8.1.34-Win32-vs16-x64.zip` | 29 MB |
| **Apache** | https://www.apachelounge.com/download/ | `httpd-2.4.69-261002-Win64-VS18.zip` | 14 MB |
| **MariaDB** | https://archive.mariadb.org/ | `mariadb-x.y.z-winx64.zip` | ~100 MB |
| MySQL (ถ้าใช้) | https://dev.mysql.com/downloads/mysql/ | **ZIP Archive** (ห้ามเอา `.msi`) | ~250 MB |
| VC++ Runtime | https://aka.ms/vs/17/release/vc_redist_x64.exe | เผื่อเครื่อง server ยังไม่มี | ~13 MB |

### 1.1 เวอร์ชัน PHP ที่ปลอดภัย (บังคับ)

| สาย | ต้องใช้อย่างน้อย |
|---|---|
| 8.5 / 8.4 / 8.3 / 8.2 | **8.5.12 / 8.4.27 / 8.3.36 / 8.2.35** |
| ≤ 8.1 | ❌ EOL ไม่มี patch — ห้ามใช้ production |

### 1.2 โหลด checksum ไปด้วย (ตรวจบน server ได้แม้ไม่มีเน็ต)

```cmd
:: ไฟล์เช็คที่มากับเว็บ อย่าลืม save ไปด้วย
windows.php.net/downloads/releases/sha256sum.txt
apachelounge.com  -> มีลิงก์ SHA1-SHA512 Checksums ใต้ชื่อไฟล์
```

**อย่า download ผ่าน browser บน server** — ให้เครื่อง prep โหลดทีเดียวแล้วรวมเป็นชุดเดียวก่อนย้าย

### 1.3 ตรวจก่อนเอาไป (บนเครื่อง prep)

```cmd
:: checksum ต้องตรง
certutil -hashfile php-8.3.36-Win32-vs16-x64.zip SHA256

:: ต้องเป็น TS จริง (มีไฟล์นี้ = ใช้กับ Apache ได้)
tar -tf php-8.3.36-Win32-vs16-x64.zip | findstr php8apache2_4.dll
:: ถ้าไม่มี → เป็น NTS ใช้กับ mod_php ไม่ได้
```

> หมายเหตุ: ถ้า server อยู่หลัง proxy ให้ internal mirror ของตัวเอง
> `add` รองรับ URL ภายในอยู่แล้ว เช่น
> `aptstack add php http://mirror.internal/apt/php-8.3.36-Win32-vs16-x64.zip`

---

## 2. ย้ายไฟล์เข้า server (ไม่ต้องใช้เน็ต)

เลือกได้ตามนโยบาย:

- USB / external disk
- share ใน LAN: `\\fileserver\share\apt\`
- RDP คัดลอก-วาง (copy & paste ผ่าน RDP)
- โอนผ่าน internal transfer tool ของหน่วยงาน

**จัดเตรียม 2 อย่าง:**

1. **zip ของ aptstack** — ดาวน์โหลดจาก GitHub Release บนเครื่อง prep
   (https://github.com/tps2015gh/aptstack/releases) → `aptstack-1.3.0.zip`
   (แตกแล้วได้โฟลเดอร์ `aptstack\` พร้อมใช้)
2. **โฟลเดอร์ staging ของ binary** รวมไฟล์ทั้งหมดในข้อ 1

```
D:\staging\
  aptstack-1.3.0.zip
  php-8.3.36-Win32-vs16-x64.zip
  httpd-2.4.69-261002-Win64-VS18.zip
  mariadb-11.4.13-winx64.zip
  vc_redist_x64.exe            (เผื่อเครื่อง server)
  sha256sum.txt
```

---

## 3. ติดตั้งบน server — ไม่แตะ internet เลย

```cmd
:: 1) แตก aptstack (zip มีโฟลเดอร์บนสุดอยู่แล้ว -> ได้ E:\aptstack\)
tar -xf D:\staging\aptstack-1.3.0.zip -C E:\
cd /d E:\aptstack

:: 2) (ถ้าจำเป็น) ติดตั้ง VC++ runtime
D:\staging\vc_redist_x64.exe /install /quiet /norestart

:: 3) แตก ZIP ของ binary เข้า stack (คำสั่งเดียว ไม่ต้องเน็ต)
aptstack add php    D:\staging\php-8.3.36-Win32-vs16-x64.zip
aptstack add apache D:\staging\httpd-2.4.69-261002-Win64-VS18.zip
aptstack add mysql  D:\staging\mariadb-11.4.13-winx64.zip

:: 4) เลือก + ตรวจ
aptstack use php 8.3.36
aptstack init
aptstack start
aptstack doctor          :: ต้องไม่มี [ERR]
aptstack list
```

เปิด `http://127.0.0.1:8077/app/` → ถ้าเห็นหน้าตัวอย่าง + ตาราง = ผ่าน

### 3.1 ทางเลือก: วางไฟล์เอง (manual drop-in)

ไม่อยากสั่ง `add` ก็ copy ตรงนี้ได้เลย — `list` สแกนหา exe ให้เอง:

```
stack\php\<ชื่อเวอร์ชัน>\php.exe            <- ต้องมีไฟล์นี้
stack\apache\<ชื่อ>\bin\httpd.exe            <- ชั้นลึก 1-2 ชั้นก็เจอ (สแกน recursive)
stack\mysql\<ชื่อ>\bin\mariadbd.exe หรือ mysqld.exe
```

ตัวอย่าง:

```cmd
tar -xf D:\staging\php-8.3.36-Win32-vs16-x64.zip -C stack\php\
ren stack\php\php-8.3.36-Win32-vs16-x64 8.3.36

tar -xf D:\staging\httpd-2.4.69-261002-Win64-VS18.zip -C stack\apache\
:: ได้ stack\apache\Apache24\ -> aptstack ใช้ได้เลย (ServerRoot คิดให้เอง)

tar -xf D:\staging\mariadb-11.4.13-winx64.zip -C stack\mysql\
```

> หมายเหตุ: `tar` มีใน Windows 10/11 อยู่แล้ว · ถ้าไม่มีใช้ `Expand-Archive` ใน PowerShell

---

## 4. เรื่องที่มักพลาดตอนทำ offline

| เรื่อง | รายละเอียด |
|---|---|
| **PHP ผิดตัว** | ลืมดู `TS` vs `NTS` → Apache start ไม่ขึ้น (`php8apache2_4.dll` หาย) → `doctor` จะบอก |
| **VC++ runtime ไม่มี** | Apache Lounge VS18/VS17 ต้องใช้ → เอา `vc_redist_x64.exe` ไปด้วย |
| **เผลอเอา `.msi` ของ MySQL** | ต้องเป็น **ZIP Archive** ถึงแตกลง `stack\mysql\` ได้ |
| **datadir ไม่ต้องเอาไป** | `start` จะสร้าง data dir ให้เอง · ถ้ามี dump เดิมให้เอา `*.sql` ไปแล้ว `mysql < dump` |
| **phpMyAdmin ไม่ได้แถม** | ถ้าต้องการ ให้โหลด `phpMyAdmin-x.y.z-all-languages.zip` บนเครื่อง prep แล้วแตกไป `www\phpmyadmin\` |
| **checksum ไม่ตรง** | อย่าใช้ไฟล์นั้น — โหลดใหม่บนเครื่อง prep |
| **อายุ cert** | `tls init` ได้ 365 วัน · ถ้า server ใช้นานเกินให้รันซ้ำ (offline ได้ เพราะใช้ openssl ใน Apache) |

---

## 5. ถ้ามี internal mirror (แนะนำสำหรับ intranet)

ตั้ง mirror ภายในแล้วใช้ URL ภายในแทน local path:

```cmd
aptstack add php    http://pkg.internal/apt/php-8.3.36-Win32-vs16-x64.zip
aptstack add apache http://pkg.internal/apt/httpd-2.4.69-Win64-VS18.zip
aptstack add mysql  http://pkg.internal/apt/mariadb-11.4.13-winx64.zip
```

- `add` ดาวน์โหลดไป `downloads\` แล้วแตกให้เอง (TLS ภายในถ้ามีก็ใช้ได้)
- ได้ข้อดี: server ไม่ต้องเข้า internet ภายนอก **และ** ไม่ต้องพก USB

---

## 6. Checklist ก่อนส่งขึ้น production (offline)

```cmd
aptstack list               :: เห็น php/apache/mysql ครบ + version ถูก
aptstack doctor             :: ต้องไม่มี [ERR] (เช็ค patch PHP, path, git leak)
aptstack status             :: service/สถานะ
aptstack backup             :: dump ก่อนเสมอ
aptstack service install    :: ลง Windows Service (admin)
aptstack service start
```

- [ ] `vc_redist` ลงแล้ว (ถ้าเครื่องใหม่)
- [ ] PHP เป็นเวอร์ชัน patch + เป็น Thread Safe
- [ ] checksum ตรง
- [ ] เปลี่ยนรหัสผ่าน DB root (ค่าเริ่มต้น `root/root`)
- [ ] `config\stack.json` ตั้ง `dbMode` / port ตรง
- [ ] hosts file ถ้าใช้ vhost
- [ ] firewall เปิดเฉพาะ 8077/8443 (ถ้าจำเป็น) — ค่าเริ่มต้น bind localhost

---

*aptstack ไม่ต้องใช้เน็ตตอนรัน — สิ่งที่ต้องเน็ตมีแค่ตอนเตรียม binary ครั้งแรก*
