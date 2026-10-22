# ==========================================================================
# aptstack HTTPS (TLS) — ถูก append เข้า config\httpd.conf เมื่อ httpsEnabled=true
# สร้างใหม่ทุกครั้งที่ start ห้ามแก้ไฟล์นี้โดยตรง
# เปิด/ปิด/เปลี่ยน cert:  aptstack tls ...  แล้ว aptstack restart
# ==========================================================================

LoadModule ssl_module        "{{APACHE_DIR}}/modules/mod_ssl.so"
LoadModule socache_shmcb_module "{{APACHE_DIR}}/modules/mod_socache_shmcb.so"

Listen {{HTTPS_PORT}}

# หมายเหตุ: ไม่กำหนด SSLSessionCache — build นี้ฟ้อง "cache size not numerical"
# ทุกรูปแบบของ shmcb ปล่อยให้ Apache ใช้ default จะผ่าน syntax และทำงานได้ปกติ
SSLSessionCacheTimeout 300
SSLStrictSNIVHostCheck off

# ---- vhost HTTPS (docroot ตัวเดียวกับ HTTP) ----
<VirtualHost *:{{HTTPS_PORT}}>
    ServerName {{SERVER_NAME}}
    DocumentRoot "{{WWW}}"

    SSLEngine on
    SSLCertificateFile    "{{CERT}}"
    SSLCertificateKeyFile "{{KEY}}"
    # ถ้ามี chain ( intermediary / Let's Encrypt fullchain ) ใส่ไฟล์เดียวกับ CERT ได้เลย

    <Directory "{{WWW}}">
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        AcceptPathInfo On
    </Directory>

    ErrorLog  "{{LOGS}}/apache-ssl-error.log"
    LogLevel  warn
    CustomLog "{{LOGS}}/apache-ssl-access.log" common

    # header ช่วยเรื่องความปลอดภัยพื้นฐาน
    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000"
        Header set X-Content-Type-Options "nosniff"
        Header set X-Frame-Options "SAMEORIGIN"
        Header set Referrer-Policy "same-origin"
    </IfModule>
</VirtualHost>
