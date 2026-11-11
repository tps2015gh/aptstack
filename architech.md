# architech.md — สถาปัตยกรรม (map สำหรับคน/AI กลับมาแก้ไข)

> เจตนารมณ์ → [soul.md](soul.md) · AI agent → [ai.md](ai.md) ·
> aptstack concept → [concept.md](concept.md) · คู่มือ → [docs/คู่มือ.md](docs/คู่มือ.md)

ชื่อไฟล์จงใจพิมพ์ `architech` (ตามที่ทีมเรียก) — เนื้อหา = architecture map

---

## 1. สองชั้นของ “ระบบ”

| ชั้น | คือ | ที่อยู่ |
|------|-----|--------|
| **A. AptStack** | portable PHP/MariaDB/Apache + สลับเวอร์ชัน | root: `aptstack.ps1`, `templates\`, `stack\`, `versions\`, `config\` |
| **B. Sample App app** | ระบบงานยืนยันตัว (CI3) | `versions\<app>\` active = `my-app_20261025_023201\` |

แก้ “คำสั่ง/เวอร์ชัน stack” → ชั้น A · แก้ “สิทธิ์/หน้าจอ/flow งาน” → ชั้น B

---

## 2. ชั้น B — โครงสร้างสำคัญ (Sample App)

```
application/
  controllers/Adm2.php     ← admin หลัก (manage, brief, update_state, reports…)
  controllers/lostpass.php ← user ลืมรหัสผ่าน (แยก silo)
  models/Adm2_Model.php    ← list/status/query สิทธิ์, pagination
  models/Forms_Model.php   ← submit ฟอร์ม → form_history + form_sum + user_apps
  models/Lostpass_Adm_Model.php
  views/adm2/…             ← manage, brief, list_forms, reports, guidance…
  views/components/ui_display/get_link_top.php  ← เมนูบน
```

### Flow งาน (ภาพรวม)

```
User submit (forms/reg)
  → form_history (form_status=NEW ครั้งเดียว)
  → form_sum (upsert ต่อ iden)
  → user_apps (ต่อ appcode, ผูก form_hash)

Admin request_one_brief
  → ปุ่มจาก status chain → request_one_brief_update_state
  → user_apps.status_code + is_finished (+ history SET_TO_FINISH)

งาน “ฟอร์มจบ” = ทุก user_apps ของ form_hash is_finished=1
  ⚠ form_history.form_status ยัง NEW ไม่ถูกเขียนกลับ (ดู rights_guidance §4)
```

### ตารางสิทธิ์ (4 ชั้น — ใช้จริงต่างกัน)

| ตาราง | บทบาท | gate จริง? |
|-------|--------|-----------|
| `admin_apps` | เห็นระบบไหน | ✅ หน้า brief/คิว |
| `admin_query_status` | กรองงานค้างตามสถานะ | ✅ list งานค้าง |
| `admin_write_status` | “ตั้งใจ” สิทธิ์เขียน | ❌ display only |
| `admin_lost_pass_cmd` | ปุ่ม lostpass | ✅ เฉพาะ lostpass |

---

## 3. เมนู / หน้าเอกสารที่ทีมใช้

| URL ปลายทาง | หน้าที่ |
|-------------|---------|
| `adm2/manage` | หน้าหลัก admin |
| `adm2/list_forms_byname` | รายการฟอร์ม + pagination + ค้น form_hash |
| `adm2/workflow_report` | สิทธิ์ตามขั้นตอน + lostpass + approved bypass |
| `adm2/adm_right_detail` | สิทธิ์รายบุคคล (ปริ้น A4) |
| `adm2/rights_guidance` | แผนปรับปรุง + form_status + เพิ่มระบบใหม่ |
| `adm2/system_info` | ตรวจเช็คระบบ + คำแนะนำ lostpass |
| `adm2/php2shell` | CVE-2024-4577 |

---

## 4. กฎเมื่อกลับมาแก้ (สรุป)

1. อ่าน **ai.md** ก่อน — UTF-8 BOM / PS5.1 / อย่า commit runtime
2. **อย่า** เพิ่มสิทธิ์ชั้นใหม่โดยไม่มีโค้ดเช็ค
3. **อย่า** แตะ `update user_apps` โดยไม่ backup/test golden path
4. เอกสารสิทธิ์ = report หน้า UI — ถ้า behavior เปลี่ยน ต้องอัปเดต
   `workflow_report` / `rights_guidance` / `list_forms_rows_result`
5. form_status: รู้ว่า DB ค้าง NEW — อย่าไว้ใจค่า DB อย่างเดียว
   (list ใช้ badge คำนวณแล้ว)
