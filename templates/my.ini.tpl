; ==========================================================================
; aptstack MariaDB template
; ถูก generate ใหม่ทุกครั้งที่ start -> ไม่มี path ค้างจากเครื่องเก่า
; ค่า {{...}} ถูกแทนที่โดย aptstack.ps1 (New-MyIni)
; ==========================================================================

[mysqld]
basedir={{BASEDIR}}
datadir={{DATADIR}}
port={{DBPORT}}

; ---- ความปลอดภัย: รับเฉพาะ localhost ----
bind-address=127.0.0.1
skip-networking=0
skip-name-resolve=1
local_infile=0
symbolic-links=0

; ---- charset ----
character-set-server=utf8mb4
collation-server=utf8mb4_general_ci

; ---- tuning ----
innodb_buffer_pool_size=256M
max_allowed_packet=256M
max_connections=100
sql_mode=NO_ENGINE_SUBSTITUTION

; ---- log (ไปที่ logs\ ของ bundle) ----
log-error={{LOGS}}/mariadb-error.log
tmpdir={{TMP}}

[client]
port={{DBPORT}}
host=127.0.0.1
default-character-set=utf8mb4

[mysql]
default-character-set=utf8mb4
