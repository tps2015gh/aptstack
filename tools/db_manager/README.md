# db_manager — standalone MariaDB/MySQL tool

ไฟล์เดียว ไม่พึ่ง aptstack (แต่ถ้าเจอ `config/stack.json` จะ auto-ใช้ port/user ของ aptstack)

## Build (ที่ไหนก็ได้ที่มี Go)

```bat
go build -o db_manager.exe db_manager.go
```

ไม่ต้องมี `go.mod` — ใช้เฉพาะ stdlib

## Run

```bat
db_manager.exe
```

## ตรวจอะไรบ้างก่อนใช้งาน

| ขั้น | ทำอะไร |
|------|--------|
| 1 | หา `mysql.exe` / `mysqldump.exe` — **เช็คว่าไฟล์อยู่จริง** (aptstack `stack\mysql\<ver>\bin` → PATH → XAMPP) |
| 2 | **Login จริง** `SELECT 1` — ถ้า fail แสดงข้อความ server เต็ม ๆ แล้ว **ให้ใส่ user/pass ใหม่ได้** |
| 3 | **Encoding** — เช็ค `character_set_*` = utf8mb4 + **round-trip ภาษาไทย** (ส่งทาง stdin กัน Windows ANSI ทำลาย UTF-8) |

## Port

| environment | port | ที่มา |
|-------------|------|------|
| มี aptstack `config/stack.json` | **3307** (หรือค่า `dbPort` ในไฟล์) | auto |
| Server production (ไม่มี stack.json) | **3306** | default |
| override | env `DB_PORT` / `DB_HOST` / `DB_USER` / `DB_PASS` | env |

## เมนู

1. List Databases & Backup → `.sql.zip`
2. Restore from `.sql.zip`
3. List Tables
4. List Tables + Rows/Collation
5. Exit

## หมายเหตุ production (Win Server 2016)

- ใส่ `mysql.exe` / `mysqldump.exe` ไว้ใน PATH ของ server (หรือตอบ path ตอนโปรแกรมถาม)
- dump ใช้ `--single-transaction --default-character-set=utf8mb4`
- ทุก error แสดง **stderr ของ mysqldump/mysql** ไม่ใช่แค่ `exit status 2`
