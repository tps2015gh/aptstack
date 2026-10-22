<?php
/**
 * aptstack sample app — ตัวอย่างจิ๋ว ไว้ prove ว่า stack รันได้ + ต่อ database ได้
 * วางอยู่ใน versions\hello-1.0.0\ แล้วถูกชี้ผ่าน www\<appAlias> (junction)
 */

declare(strict_types=1);

header('Content-Type: text/html; charset=utf-8');

// ---- อ่านค่าจาก config จริงของ stack (ไม่ hardcode รหัสผ่าน) ----
// อย่าเดาด้วย dirname(): ผ่าน junction แล้ว PHP คืน path ต่างกันระหว่าง CLI กับ Apache
// ให้เดินขึ้นไปหาโฟลเดอร์ที่มี aptstack.ps1 (=root ของ bundle)
$root = __DIR__;
for ($i = 0; $i < 6; $i++) {
    if (is_file($root . '/aptstack.ps1') || is_file($root . '/config/stack.json')) { break; }
    $up = dirname($root);
    if ($up === $root) { break; }
    $root = $up;
}
$cfgPath = $root . '/config/stack.json';
$cfg = [];
if (is_readable($cfgPath)) {
    // strip BOM ก่อน decode — PowerShell บางคำสั่งเขียนไฟล์แบบมี BOM ได้
    $raw = ltrim((string)file_get_contents($cfgPath), "\xEF\xBB\xBF");
    $cfg = json_decode($raw, true) ?: [];
}
$dbHost = '127.0.0.1';
$dbPort = (int)($cfg['dbPort'] ?? 3307);
$dbUser = (string)($cfg['dbUser'] ?? 'root');
$dbPass = (string)($cfg['dbPass'] ?? '');
$alias  = (string)($cfg['appAlias'] ?? 'app');
$version = basename(__DIR__);                   // ชื่อโฟลเดอร์ = ชื่อเวอร์ชัน

// ---- ทดสอบ database ----
$dbOk   = false;
$dbErr  = '';
$dbRows = [];
try {
    $pdo = new PDO(
        sprintf('mysql:host=%s;port=%d;charset=utf8mb4', $dbHost, $dbPort),
        $dbUser,
        $dbPass,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5]
    );
    $dbOk = true;

    // ถ้า seed แล้ว (aptstack seed) ให้โชว์ข้อมูลจริง
    $has = $pdo->query("SHOW DATABASES LIKE 'aptstack_demo'")->fetch();
    if ($has) {
        foreach ($pdo->query('SELECT id, message, created_at FROM aptstack_demo.greetings ORDER BY id') as $r) {
            $dbRows[] = $r;
        }
    }
} catch (Throwable $e) {
    $dbErr = $e->getMessage();
}
?>
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="utf-8">
<title>aptstack — sample app</title>
<style>
  body{font-family:Consolas,"Leelawadee UI",Tahoma,sans-serif;background:#0f1115;color:#e6e8ee;
       max-width:820px;margin:40px auto;padding:0 20px;line-height:1.7}
  h1{color:#4cc2ff;font-size:26px;margin-bottom:4px}
  .card{background:#171a21;border:1px solid #262b36;border-radius:10px;padding:16px 20px;margin:16px 0}
  .ok{color:#38d178;font-weight:700} .bad{color:#ff6b6b;font-weight:700}
  table{border-collapse:collapse;width:100%;font-size:14px}
  th,td{border:1px solid #262b36;padding:6px 10px;text-align:left}
  th{background:#1b1f28}
  code{background:#1e222b;border:1px solid #262b36;border-radius:4px;padding:1px 6px;color:#9fe8ff}
  a{color:#4cc2ff}
</style>
</head>
<body>

<h1>aptstack ทำงานแล้ว ✅</h1>
<p style="color:#9aa3b2">sample app ตัวอย่าง — ไว้พิสูจน์ว่า web server + PHP + database รันได้จริง</p>

<div class="card">
  <b>Stack</b>
  <table>
    <tr><th>App version</th><td><code><?= htmlspecialchars($version) ?></code></td></tr>
    <tr><th>PHP</th><td><?= htmlspecialchars(PHP_VERSION) ?> (ZTS: <?= ZEND_THREAD_SAFE ? 'YES' : 'NO' ?>)</td></tr>
    <tr><th>SAPI</th><td><?= htmlspecialchars((string)php_sapi_name()) ?></td></tr>
    <tr><th>Loaded ini</th><td><code><?= htmlspecialchars((string)php_ini_loaded_file()) ?></code></td></tr>
    <tr><th>pdo_mysql / mysqli</th>
        <td><?= extension_loaded('pdo_mysql') ? '<span class="ok">pdo_mysql OK</span>' : '<span class="bad">pdo_mysql MISSING</span>' ?>
            /
            <?= extension_loaded('mysqli') ? '<span class="ok">mysqli OK</span>' : '<span class="bad">mysqli MISSING</span>' ?></td></tr>
  </table>
</div>

<div class="card">
  <b>Database 127.0.0.1:<?= (int)$dbPort ?></b>
  <?php if ($dbOk): ?>
    <p class="ok">เชื่อมต่อสำเร็จ (<?= htmlspecialchars($dbUser) ?>)</p>
    <?php if ($dbRows): ?>
      <table>
        <tr><th>#</th><th>message</th><th>created_at</th></tr>
        <?php foreach ($dbRows as $r): ?>
          <tr>
            <td><?= (int)$r['id'] ?></td>
            <td><?= htmlspecialchars((string)$r['message']) ?></td>
            <td><?= htmlspecialchars((string)$r['created_at']) ?></td>
          </tr>
        <?php endforeach; ?>
      </table>
      <p style="color:#9aa3b2;font-size:13px">↑ ข้อมูลจาก <code>aptstack seed</code></p>
    <?php else: ?>
      <p style="color:#ffc857">ยังไม่มีฐานข้อมูล <code>aptstack_demo</code> — รัน:
        <code>aptstack seed</code> แล้ว refresh หน้านี้</p>
    <?php endif; ?>
  <?php else: ?>
    <p class="bad">ต่อ database ไม่ได้</p>
    <p style="font-size:13px;color:#9aa3b2"><?= htmlspecialchars($dbErr) ?></p>
    <p style="font-size:13px;color:#9aa3b2">ตรวจ: <code>aptstack status</code> ·
       ถ้าใช้ MySQL ของ XAMPP ให้ตั้ง <code>"dbMode":"external","dbPort":3306</code></p>
  <?php endif; ?>
</div>

<div class="card" style="font-size:14px">
  ลองต่อ:
  <a href="/<?= htmlspecialchars($alias) ?>/">sample app</a> ·
  <a href="/">หน้าทดสอบ PHP</a>
  <?php if (is_dir($root . '/www/phpmyadmin')): ?>
    · <a href="/phpmyadmin/">phpMyAdmin</a>
  <?php endif; ?>
  <br>
  สลับเวอร์ชัน: <code>aptstack use -</code> · ตรวจสุขภาพ: <code>aptstack doctor</code>
</div>

</body>
</html>
