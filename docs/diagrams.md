# ไดอะแกรม ( diagrams ) — ดูภาพรวมระบบได้ง่าย

> GitHub แสดง **SVG** และ **Mermaid** ให้เห็นเป็นภาพในหน้านี้เลย (ไม่ต้องดาวน์โหลด)
> · ไฟล์ SVG อยู่ที่ `docs/diagrams/` (vector — ไฟล์เล็ก เปิดซูมได้คมชัด)

---

## 1. ผังโฟลเดอร์ (อะไร commit ได้ / ห้าม commit)

![bundle layout](diagrams/bundle-layout.svg)

```mermaid
flowchart LR
  subgraph ROOT["D:\\aptstack\\"]
    S["stack\\<br/>binary (ห้าม commit)"]
    V["versions\\<br/>โค้ดแอป"]
    C["config\\<br/>stack.json + ini"]
    D["data\\<br/>datadir + dumps"]
    W["www\\<br/>junction -> versions\\active"]
    T["templates\\ + examples\\ + docs\\<br/>(commit ได้)"]
  end
  T -- "start = สร้าง" --> C
  W -. "ชี้ไป" .-> V
  S -- "รัน" --> W
```

---

## 2. `aptstack start` — ไม่ใช่ "รอแบบเดา"

![lifecycle](diagrams/lifecycle-start.svg)

```mermaid
sequenceDiagram
  participant U as ผู้ใช้
  participant A as aptstack
  participant C as config\*.ini
  participant DB as MariaDB
  participant W as Web (Apache/builtin)
  U->>A: aptstack start
  A->>C: generate php.ini/my.ini/httpd.conf (path จริง)
  A->>DB: start + mariadb-admin ping
  A->>W: start + HTTP GET /
  W-->>A: 200 OK (1655 ms)
  A-->>U: health: http -> 200 OK
```

---

## 3. สลับเวอร์ชันแอป (junction + rollback)

![switch](diagrams/version-switch.svg)

```mermaid
stateDiagram-v2
  [*] --> v10: use todo-1.0
  v10 --> v11: aptstack use todo-1.1
  v11 --> v10: aptstack use - (rollback)
  v10 --> [*]
  v11 --> [*]
```

> หลักการ: `www\app` เป็น **junction** ชี้ไป `versions\<ตัวที่ active>`
> สลับ = ย้าย junction + restart web → ของเก่าอยู่ครบ → ย้อนกลับได้เสมอ

---

## 4. โยกฐานข้อมูลไป engine ใหม่ (migrate)

![migrate](diagrams/lifecycle-start.svg)

```mermaid
flowchart TD
  A[engine เดิม 11.4] --> B[mariadb-dump --all-databases<br/>เก็บที่ data/dumps/]
  B --> C[stop DB]
  C --> D[config.mysql = ตัวใหม่]
  D --> E[start ตัวใหม่<br/>สร้าง datadir ว่าง]
  E --> F[import dump]
  F --> G{สำเร็จ?}
  G -- yes --> H[เสร็จ · ของเดิมยังอยู่]
  G -- no --> I[ใช้ dump เดิม import มือ<br/>หรือ use mysql เก่า + start]
```

---

## 5. dev (notebook) vs production (server)

![dev vs prod](diagrams/dev-vs-prod.svg)

```mermaid
flowchart LR
  subgraph DEV["DEV - Win11 notebook (มีเน็ต)"]
    D1[aptstack add php 8.3.36] --> D2[aptstack use php ...]
    D2 --> D3[aptstack start / run]
    D3 --> D4[aptstack doctor + report]
    D4 --> D5[aptstack dist app]
  end
  subgraph PROD["PROD - Windows Server (มักไม่มีเน็ต)"]
    P1[RDP/share ชุด dist_paste] --> P2[aptstack use app]
    P2 --> P3[aptstack start + doctor]
    P3 --> P4{มั่นใจแล้ว?}
    P4 -- yes --> P5[aptstack service install/start]
    P4 -- no --> P6[aptstack stop / use -]
  end
  D5 -- "copy-paste (ไม่ต้องโหลดจากเน็ต)" --> P1
```

**สำคัญ**
- ไม่ใช้ nginx — มีแค่ **Apache + mod_php** หรือ **PHP built-in server** (`webMode`)
- **dev ไม่ต้อง register service** — ใช้ `start` / `run` ก็พอ
- **production รัน manual ก่อนได้** แล้วค่อย `service install` ทีหลัง

---

## 6. แพ็กเพื่อ copy-paste ขึ้น server (dist)

![deploy](diagrams/deploy-dist.svg)

```mermaid
flowchart LR
  A[aptstack dist todo-1.1] --> B[dist_paste/todo-1.1/<br/>scripts + app + binary<br/>VERSIONS.txt + DEPLOY.txt]
  B --> C[RDP / USB / share]
  C --> D[cd เข้าโฟลเดอร์]
  D --> E[aptstack use todo-1.1]
  E --> F[aptstack start]
  F --> G[aptstack doctor]
  G --> H{ผ่าน?}
  H -- yes --> I[ใช้งานได้ / service install]
  H -- no --> J["aptstack logs apache&#124;mysql&#124;php"]
```

> ชุด deploy **ไม่เอา** `data\` เดิม, `.git`, `logs\` — server สร้างเองตอน start
> มี `VERSIONS.txt` บอก version ทั้งหมด + `DEPLOY.txt` ขั้นตอน

---

## 7. ดูไดอะแกรมเป็นไฟล์ (เปิดซูมได้)

| ไฟล์ | เนื้อหา |
|---|---|
| [bundle-layout.svg](diagrams/bundle-layout.svg) | ผังโฟลเดอร์ + อะไร commit ได้ + ระวัง bundle บวม |
| [lifecycle-start.svg](diagrams/lifecycle-start.svg) | start → generate conf → process → health probe |
| [version-switch.svg](diagrams/version-switch.svg) | junction สลับ + rollback + จัดการเวอร์ชัน |
| [dev-vs-prod.svg](diagrams/dev-vs-prod.svg) | notebook vs server · ไม่ใช้ nginx · service ไม่บังคับ |
| [deploy-dist.svg](diagrams/deploy-dist.svg) | dist → copy-paste → use/start/doctor |

**อัปเดตขนาด/พื้นที่:** `aptstack size` (CLI) · `aptstack report` (HTML พิมพ์ได้)
