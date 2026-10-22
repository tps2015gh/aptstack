# ==========================================================================
# aptstack httpd.conf template
# ถูก generate ใหม่ทุกครั้งที่ start (webMode=apache) -> ห้ามแก้ config\httpd.conf
# แก้ถาวรที่ไฟล์นี้ แล้ว aptstack restart
#
# ตัวแปรที่ถูกแทนที่:
#   {{APACHE_DIR}} {{PHP_DIR}} {{PHP_INI}} {{WWW}} {{LOGS}} {{PORT}}
# ==========================================================================

ServerRoot "{{APACHE_DIR}}"
Listen {{PORT}}
ServerName localhost:{{PORT}}
ServerAdmin admin@localhost

# --- security: ไม่เผยตัวตน server ---
ServerTokens Prod
ServerSignature Off
TraceEnable off

# --- core modules ---
LoadModule access_compat_module "{{APACHE_DIR}}/modules/mod_access_compat.so"
LoadModule actions_module      "{{APACHE_DIR}}/modules/mod_actions.so"
LoadModule alias_module        "{{APACHE_DIR}}/modules/mod_alias.so"
LoadModule authz_core_module   "{{APACHE_DIR}}/modules/mod_authz_core.so"
LoadModule authz_host_module   "{{APACHE_DIR}}/modules/mod_authz_host.so"
LoadModule dir_module          "{{APACHE_DIR}}/modules/mod_dir.so"
LoadModule env_module          "{{APACHE_DIR}}/modules/mod_env.so"
LoadModule filter_module       "{{APACHE_DIR}}/modules/mod_filter.so"
LoadModule headers_module      "{{APACHE_DIR}}/modules/mod_headers.so"
LoadModule log_config_module   "{{APACHE_DIR}}/modules/mod_log_config.so"
LoadModule mime_module         "{{APACHE_DIR}}/modules/mod_mime.so"
LoadModule rewrite_module      "{{APACHE_DIR}}/modules/mod_rewrite.so"
LoadModule setenvif_module     "{{APACHE_DIR}}/modules/mod_setenvif.so"
LoadModule negotiation_module  "{{APACHE_DIR}}/modules/mod_negotiation.so"

# --- PHP (mod_php) : ต้องเป็น Thread Safe build เท่านั้น ---
LoadModule php_module "{{PHP_DIR}}/php8apache2_4.dll"
PHPIniDir "{{PHP_INI}}"
AddType application/x-httpd-php .php

<IfModule dir_module>
    DirectoryIndex index.php index.html index.htm
</IfModule>

DocumentRoot "{{WWW}}"

<Directory "{{WWW}}">
    # FollowSymLinks จำเป็น: www\<app> เป็น junction ชี้ไป versions\<ver>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
    AcceptPathInfo On
</Directory>

<IfModule mime_module>
    TypesConfig conf/mime.types
    AddType application/x-httpd-php .php
</IfModule>

# --- security: ห้ามเข้าถึงไฟล์ที่ไม่ควรโชว์ ---
<FilesMatch "^\.(ht|env|git|svn|ds_store)">
    Require all denied
</FilesMatch>

<FilesMatch "(^#.*#|\.(bak|config|dist|fla|inc|ini|log|psd|sh|sql|sw[op]|pem|key|p12)|~)$">
    Require all denied
</FilesMatch>

# ห้ามเข้า folder ของระบบผ่าน URL โดยตรง
RedirectMatch 404 ^/(config|stack|versions|data|logs|templates|bin)(/|$)

# --- logging ---
ErrorLog "{{LOGS}}/apache-error.log"
LogLevel warn

<IfModule log_config_module>
    LogFormat "%h %l %u %t \"%r\" %>s %b" common
    CustomLog "{{LOGS}}/apache-access.log" common
</IfModule>

# --- server status (เฉพาะ localhost) ---
<Location /server-status>
    SetHandler server-status
    Require local
</Location>

# --- บอกแอปว่าอยู่หลัง http (ถ้าต่อ proxy/TLS ทีหลัง ให้แก้ตรงนี้) ---
<IfModule mod_headers.c>
    Header set X-Content-Type-Options "nosniff"
    Header set X-Frame-Options "SAMEORIGIN"
</IfModule>
