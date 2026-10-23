# apphistory.md — ประวัติการพัฒนา aptstack (ไทม์ไลน์จริง)

> ฉบับสั้น อ่านรู้เรื่องใน 3 นาที · รายละเอียดเชิงเทคนิค → [CHANGELOG.md](CHANGELOG.md) ·
> บั๊คที่เจอ → [review.md](review.md) · เจตนารมณ์ → [soul.md](soul.md)

---

## 1. ไทม์ไลน์

| วันที่ | เกิดอะไรขึ้น |
|---|---|
| **2026-10-18** | ของเดิม **APT-Standalone** ถูกใช้งานจริง (bundle คล้าย XAMPP: MariaDB 3307 + PHP built-in 8077 + phpMyAdmin) — แต่ hardcode path + PHP 8.1 (EOL) |
| **2026-10-22 (เช้า)** | หยิบ `devstack-1.1.0/1.2.0-from-hermes.zip` มาเทียบ → เก็บแนวคิด: templates→generate, UX `add/use/doctor`, `use -`, ตาราง PHP ปลอดภัย |
| 2026-10-22 | เขียน **aptstack v1.0.0** จากศูนย์: สลับเวอร์ชันด้วย junction · Windows Service (compile `csc.exe`) · Apache+mod_php · ตัดข้อมูลจริงออกจาก repo |
| 2026-10-22 | **ปลดล็อกช่องโหว่ PHP RCE** (security-php.txt / PHP2Shell): เลือก PHP **8.3.36** · `doctor` fail ได้จริง |
| 2026-10-22 ค่ำ | **v1.1.0**: HTTPS (`tls init/import` + Trusted Root) · vhosts · `logs` · health probe จริง · ตัดชื่อระบบจริงออกจาก docs |
| 2026-10-22 ดึก | **rewrite git history** ล้างชื่อระบบจริง/ชื่อหน่วยงาน/IP เครื่อง ออกจากทุก commit + ลบ release ที่มีไฟล์เก่า + ลบทของจริงออกจากโฟลเดอร์ทดสอบ |
| **2026-10-23** | **v1.2.0**: ตัวอย่างแอป 3 ตัว (hello/todo/sysinfo) · `add php 8.3.36` เติม URL เอง · `samples` · `docs/SCENARIO.md` + `OFFLINE-DEPLOY.md` |
| 2026-10-23 (ต่อเนื่อง) | **unreleased**: `report`(HTML พิมพ์ได้) · `size`(เตือนบวม) · `run` · `dist`(copy-paste) · `git` · `clone/remove/migrate` · **web console (localhost เท่านั้น)** · per-app URL (`/todo-app/` `/sysinfo-app/`) · ไดอะแกรม 5 ภาพ · app family manifest |

---

## 2. รุ่นที่เผยแพร่ (release)

| รุ่น | tag | สิ่งสำคัญ | สถานะ |
|---|---|---|---|
| 1.0.0 | `v1.0.0` | ตัวแรก: สลับเวอร์ชัน + Service + Apache | **ถูกลบ** (zip มีชื่อระบบจริง) |
| 1.1.0 | `v1.1.0` | HTTPS + vhosts + logs + health probe | บน GitHub |
| 1.2.0 | `v1.2.0` | ตัวอย่าง 3 แอป + auto-URL + SCENARIO | บน GitHub (asset ยังไม่รวมของหลัง 1.2.0) |
| unreleased | — | report/size/dist/git/run/console/clone/remove/migrate | **push แล้วบน main แต่ยังไม่สร้าง release** |

---

## 3. ที่มาของแต่ละส่วน (ใครให้อะไร)

| ส่วน | มาจาก |
|---|---|
| โค้ดแอปจริง + โครง bundle (PHP-Portable/MariaDB/phpMyAdmin) | **APT-Standalone** (ต้นแบบฝั่งแอป) |
| templates→generate, UX คำสั่ง, `use -`, ตาราง PHP ปลอดภัย | **devstack** (เจ้าของสร้างเองเริ่มจาก 0 ด้วย deepseek-v4.1-flash บน opencode-go/Hermes) |
| ทั้งหมดที่เป็น aptstack (junction app version, service, doctor fail ได้, console, dist, size…) | **MiMo-V2.6-Flash บน MimoCode** |

---

## 4. บทเรียนสำคัญระหว่างทาง (อ่านครั้งเดียว จำไปนาน)

1. **BOM ทำพัง 3 ทาง** — `.ps1` ไม่มี BOM → ไทยพัง · `my.ini` มี BOM → MariaDB start ไม่ขึ้น ·
   `stack.json` มี BOM → `json_decode` = null → รหัสผ่านหาย
2. **PS5.1 `.Count` = null บน object เดียว** → `Resolve-*` คืน null เมื่อมี 1 ตัว
3. **Apache ไม่รู้ PATH ของ PHP** → extension อย่าง curl โหลดไม่ได้
4. **callback ปลด SSL ใช้ไม่ได้จริง** → ต้อง trust cert ใน store
5. **`.cmd` ต้อง CRLF** ไม่งั้น cmd พิมพ์ `'-' is not recognized`
6. **pipe string เข้า process ไทย = ????** → ต้องส่งไฟล์ stdin ตรง ๆ
7. **ของจริงห้ามอยู่ในโฟลเดอร์ทดสอบ/repo** — ทั้งโค้ด, dump, ชื่อระบบ → ต้องลบทั้งต้นไม้ (history rewrite)
8. **syntax check ผ่าน ≠ ใช้ได้** — ต้องรันพิสูจน์ทุกครั้ง

---

## 5. ถ้าจะเริ่มต่อใน session ใหม่

อ่าน **`ai.md` §11 (handoff)** → จะเห็นว่าเหลืออะไร:
- เพิ่มภาพ console ใน README/คู่มือ
- rebuild release asset ให้ตรงกับของหลัง 1.2.0
- ทดสอบ `migrate` end-to-end + auto-verify checksum

---

*จัดทำเพื่อให้เห็น "เดินมาถึงตรงไหน" ได้ในหน้าเดียว — อัปเดตทุกครั้งที่ออก release ใหม่*
