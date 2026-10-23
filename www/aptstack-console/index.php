<?php
/**
 * aptstack web console — แผงควบคุมในเบราว์เซอร์ (คล้าย phpMyAdmin/cPanel แบบจิ๋ว)
 *
 * ⛔ เข้าได้ "เฉพาะ localhost" เท่านั้น (127.0.0.1 / ::1) — ห้ามจากภายนอกเด็ดขาด
 * ⛔ ป้องกัน CSRF ด้วย session token (กันเว็บภายนอกแอบสั่งผ่าน browser ของเรา)
 * ⛔ คำสั่งที่สั่งได้ = whitelist เท่านั้น + ตรวจชื่อกับไฟล์จริงบนดิสก์ (ไม่รับ input 任意)
 *
 * ที่ไม่ทำผ่าน web (ให้ใช้ CLI): remove / clone / migrate / service install / tls import
 * (เสี่ยงทำลายข้อมูลหรือต้องสิทธิ์ admin — แสดงคำสั่งให้ copy ไปรันเองแทน)
 */
declare(strict_types=1);

error_reporting(E_ALL & ~E_DEPRECATED);

// ---- หา root ของ bundle ----
$ROOT = __DIR__;
for ($i = 0; $i < 6; $i++) {
    if (is_file($ROOT . '/aptstack.ps1') || is_file($ROOT . '/config/stack.json')) break;
    $up = dirname($ROOT); if ($up === $ROOT) break; $ROOT = $up;
}

// ---- 1) LOCALHOST ONLY: ปิดประตูทันทีถ้าไม่ใช่ loopback ----
$remote = $_SERVER['REMOTE_ADDR'] ?? '';
$okIp = in_array($remote, ['127.0.0.1', '::1'], true);
if (!$okIp) {
    http_response_code(403);
    header('Content-Type: text/plain; charset=utf-8');
    echo "403 Forbidden — aptstack console เข้าได้จาก localhost เท่านั้น\n";
    echo "remote={$remote}\n";
    exit;
}

// ---- 2) session + CSRF token ----
session_save_path($ROOT . '/config/sessions');
session_start();
if (empty($_SESSION['apt_tok'])) {
    $_SESSION['apt_tok'] = bin2hex(random_bytes(16));
}
$TOK = $_SESSION['apt_tok'];

// ---- helpers ----
function h($s) { return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); }

function cfg_read(string $root): array {
    $p = $root . '/config/stack.json';
    if (!is_readable($p)) return [];
    $raw = ltrim((string)file_get_contents($p), "\xEF\xBB\xBF");
    return json_decode($raw, true) ?: [];
}
function list_apps(string $root): array {
    $d = $root . '/versions'; $out = [];
    foreach (glob($d . '/*', GLOB_ONLYDIR) ?: [] as $dir) {
        $name = basename($dir);
        $fam = $name; $ver = $name;
        $mf = $dir . '/.aptstack-version';
        if (is_readable($mf)) {
            foreach (file($mf, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l) {
                if (preg_match('/^\s*family\s*=\s*(.+)$/', $l, $m)) $fam = trim($m[1]);
                if (preg_match('/^\s*version\s*=\s*(.+)$/', $l, $m)) $ver = trim($m[1]);
            }
        } elseif (preg_match('/^(.+?)[-_]v?(\d[\d.]*)$/', $name, $m)) { $fam = $m[1]; $ver = $m[2]; }
        $out[] = ['name' => $name, 'family' => $fam, 'ver' => $ver, 'has_index' => is_file($dir . '/index.php')];
    }
    return $out;
}
function list_phps(string $root): array {
    $d = $root . '/stack/php'; $out = [];
    foreach (glob($d . '/*', GLOB_ONLYDIR) ?: [] as $dir) {
        $n = basename($dir);
        if (is_file($dir . '/php.exe')) $out[] = $n;
    }
    sort($out); return $out;
}

/** รันคำสั่ง CLI —  whitelist เท่านั้น, ทุก arg ผ่าน escapeshellarg */
function apt_run(array $args): string {
    global $ROOT;
    $ps = $ROOT . '/aptstack.ps1';
    if (!is_file($ps)) return 'ไม่พบ aptstack.ps1';
    // บังคับ PowerShell คาย output เป็น UTF-8 — ไม่งั้นภาษาไทยกลายเป็น ????
    // (ค่า default คือ OEM codepage ของ Windows)
    $inner = '& ' . escapeshellarg($ps);
    foreach ($args as $a) { $inner .= ' ' . escapeshellarg((string)$a); }
    $script = '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; ' . $inner;
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -Command ' . escapeshellarg($script);
    $out = shell_exec($cmd . ' 2>&1');
    return is_string($out) ? $out : '';
}

// ---- 3) จัดการ POST (สั่งงาน) ----
$msg = ''; $err = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $tok = (string)($_POST['tok'] ?? '');
    if (!hash_equals($TOK, $tok)) {
        http_response_code(403);
        exit('403 — token ไม่ถูกต้อง (CSRF) · รีเฟรชหน้าแล้วลองใหม่');
    }
    $act = (string)($_POST['act'] ?? '');
    $apps = list_apps($ROOT); $phps = list_phps($ROOT);
    $cfg = cfg_read($ROOT);

    $fixed = ['start', 'stop', 'restart', 'status', 'doctor', 'list', 'size', 'samples', 'seed', 'report'];
    try {
        if (in_array($act, $fixed, true)) {
            $out = apt_run([$act]);
            $msg = "สั่ง: aptstack $act";
            $msg .= "\n\n" . $out;
        } elseif ($act === 'use_app') {
            $name = (string)($_POST['app'] ?? '');
            // ตรวจว่าเป็นชื่อที่มีจริงจริงเท่านั้น (กัน command injection)
            if (!preg_match('/^[\w.\-]+$/', $name)) throw 'ชื่อ app ไม่ถูกต้อง';
            if (!in_array($name, array_column($apps, 'name'), true)) throw 'ไม่พบ app ชื่อนี้';
            $out = apt_run(['use', $name]);
            $msg = "สลับแอป -> $name";
            $msg .= "\n\n" . $out;
        } elseif ($act === 'use_php') {
            $v = (string)($_POST['php'] ?? '');
            if (!preg_match('/^\d+\.\d+\.\d+$/', $v)) throw 'เวอร์ชัน PHP ไม่ถูกต้อง';
            if (!in_array($v, $phps, true)) throw 'ไม่พบ PHP เวอร์ชันนี้';
            $out = apt_run(['use', 'php', $v]);
            $msg = "สลับ PHP -> $v";
            $msg .= "\n\n" . $out;
        } elseif ($act === 'logs') {
            $k = (string)($_POST['kind'] ?? 'all');
            if (!in_array($k, ['apache', 'mysql', 'php', 'all'], true)) throw 'kind ไม่ถูกต้อง';
            $out = apt_run(['logs', $k, '30']);
            $msg = "log ($k):\n\n" . $out;
        } else {
            throw 'ไม่รู้จักคำสั่งนี้';
        }
    } catch (Throwable $e) {
        $err = $e->getMessage();
    }
}

// ---- 4) อ่านสถานะ (อ่านไฟล์/พอร์ต ไม่สั่งอะไร) ----
$cfg = cfg_read($ROOT);
$apps = list_apps($ROOT);
$phps = list_phps($ROOT);
$curApp = (string)($cfg['app'] ?? '');
if ($curApp === '') {
    $link = $ROOT . '/www/' . ($cfg['appAlias'] ?? 'app');
    if (is_dir($link)) { $curApp = basename((string)@readlink($link)); }
}
function port_open(string $host, int $port): bool {
    $e = 0; $es = '';
    $s = @fsockopen($host, $port, $e, $es, 1);
    if ($s) { fclose($s); return true; }
    return false;
}
$httpUp = port_open('127.0.0.1', (int)($cfg['httpPort'] ?? 8077));
$dbUp = port_open('127.0.0.1', (int)($cfg['dbPort'] ?? 3307));
$httpsUp = (($cfg['httpsEnabled'] ?? '') === 'true') && port_open('127.0.0.1', (int)($cfg['httpsPort'] ?? 8443));
$pma = is_dir($ROOT . '/www/phpmyadmin');
$logPhp = $ROOT . '/logs/php-error.log';
$logTail = is_readable($logPhp) ? implode("\n", array_slice(@file($logPhp) ?: [], -12)) : '(ยังไม่มี log)';
?>
<!DOCTYPE html>
<html lang="th"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>aptstack console (localhost เท่านั้น)</title>
<style>
 body{font-family:Consolas,"Leelawadee UI",Tahoma,sans-serif;background:#0f1115;color:#e6e8ee;margin:0;padding:18px}
 h1{font-size:22px;margin:0 0 2px;color:#4cc2ff}
 .sub{color:#9aa3b2;font-size:12.5px;margin-bottom:14px}
 .badge{display:inline-block;border:1px solid #3a4152;border-radius:999px;padding:2px 10px;font-size:12px;margin:0 8px 8px 0}
 .ok{border-color:#38d178;color:#38d178}.bad{border-color:#ff6b6b;color:#ff6b6b}
 .card{background:#171a21;border:1px solid #262b36;border-radius:10px;padding:14px 16px;margin:14px 0}
 h2{font-size:15px;margin:0 0 10px;color:#9fe8ff}
 table{border-collapse:collapse;width:100%;font-size:13px}
 th,td{border:1px solid #262b36;padding:5px 8px;text-align:left}
 th{background:#1b1f28}
 button{background:#2563eb;border:0;color:#fff;padding:7px 14px;border-radius:6px;cursor:pointer;margin-right:6px}
 button.gray{background:#374151} button.red{background:#7f1d1d} button.grn{background:#0f766e}
 select,input[type=text]{background:#1e222b;border:1px solid #3a4152;color:#e6e8ee;padding:6px 8px;border-radius:6px}
 pre{background:#12151b;border:1px solid #262b36;border-radius:8px;padding:10px;white-space:pre-wrap;font-size:12px;color:#cfe3ff;max-height:340px;overflow:auto}
 .warn{color:#ffc857}.err{color:#ff6b6b}.ok{color:#38d178}
 a{color:#4cc2ff}
 .note{color:#9aa3b2;font-size:12px}
</style></head><body>

<h1>aptstack console</h1>
<div class="sub">⛔ เข้าได้จาก <b>localhost เท่านั้น</b> · คำสั่งอันตราย (remove/clone/migrate/service/tls import) ใช้ CLI ·
สถานะตอนนี้: app <b><?= h($curApp ?: '-') ?></b> · PHP <b><?= h($cfg['php'] ?? '-') ?></b></div>

<span class="badge <?= $httpUp ? 'ok' : 'bad' ?>">web : <?= $httpUp ? 'UP' : 'DOWN' ?> :<?= (int)($cfg['httpPort'] ?? 8077) ?></span>
<span class="badge <?= $dbUp ? 'ok' : 'bad' ?>">db  : <?= $dbUp ? 'UP' : 'DOWN' ?> :<?= (int)($cfg['dbPort'] ?? 3307) ?></span>
<?php if ((($cfg['httpsEnabled'] ?? '') === 'true')): ?>
<span class="badge <?= $httpsUp ? 'ok' : 'bad' ?>">https : <?= $httpsUp ? 'UP' : 'DOWN' ?> :<?= (int)($cfg['httpsPort'] ?? 8443) ?></span>
<?php endif; ?>

<div class="card">
<h2>เปิด / ปิด stack</h2>
<form method="post" style="display:inline">
 <input type="hidden" name="tok" value="<?= h($TOK) ?>">
 <button name="act" value="start" class="grn">start</button>
 <button name="act" value="restart">restart</button>
 <button name="act" value="stop" class="red">stop</button>
</form>
</div>

<div class="card">
<h2>สลับแอป (เปลี่ยนที่ <code>/<?= h($cfg['appAlias'] ?? 'app') ?>/</code>)</h2>
<form method="post">
 <input type="hidden" name="tok" value="<?= h($TOK) ?>">
 <input type="hidden" name="act" value="use_app">
 <select name="app">
 <?php foreach ($apps as $a): ?>
  <option value="<?= h($a['name']) ?>" <?= $a['name'] === $curApp ? 'selected' : '' ?>>
    <?= h($a['name']) ?>  [<?= h($a['family']) ?> v<?= h($a['ver']) ?>]<?= $a['has_index'] ? '' : ' (ไม่มี index.php)' ?>
  </option>
 <?php endforeach; ?>
 </select>
 <button>สลับ</button>
</form>
<p class="note">ทุก app เข้าได้หลาย path พร้อมกัน เช่น
<?php foreach ($apps as $a): ?><code>/<?= h($a['name']) ?>/</code> <?php endforeach; ?>
· path หลัก <code>/<?= h($cfg['appAlias'] ?? 'app') ?>/</code></p>
</div>

<div class="card">
<h2>สลับ PHP</h2>
<form method="post">
 <input type="hidden" name="tok" value="<?= h($TOK) ?>">
 <input type="hidden" name="act" value="use_php">
 <select name="php">
 <?php foreach ($phps as $v): ?>
  <option value="<?= h($v) ?>" <?= $v === ($cfg['php'] ?? '') ? 'selected' : '' ?>><?= h($v) ?></option>
 <?php endforeach; ?>
 </select>
 <button>สลับ</button>
</form>
<p class="note">เวอร์ชันปลอดภัย: 8.3.36 / 8.4.27 / 8.5.12 / 8.2.35 (ต่ำกว่านี้ห้ามใช้ production)</p>
</div>

<div class="card">
<h2>ตัวช่วย</h2>
<form method="post" style="display:inline">
 <input type="hidden" name="tok" value="<?= h($TOK) ?>">
 <button name="act" value="samples" class="gray">ติดตั้งตัวอย่าง</button>
 <button name="act" value="seed" class="gray">สร้าง database ตัวอย่าง</button>
 <button name="act" value="doctor" class="gray">ตรวจสุขภาพ</button>
 <button name="act" value="size" class="gray">ดูพื้นที่</button>
 <button name="act" value="report" class="gray">สร้างรายงาน HTML</button>
</form>
<form method="post" style="margin-top:8px">
 <input type="hidden" name="tok" value="<?= h($TOK) ?>">
 <input type="hidden" name="act" value="logs">
 <select name="kind"><option>apache</option><option>mysql</option><option>php</option><option selected>all</option></select>
 <button>ดู log</button>
</form>
</div>

<div class="card">
<h2>ผลลัพธ์คำสั่งล่าสุด</h2>
<?php if ($err): ?><p class="err">✗ <?= h($err) ?></p><?php endif; ?>
<?php if ($msg): ?><p class="ok"><?= h(explode("\n", $msg)[0]) ?></p><pre><?= h($msg) ?></pre>
<?php elseif (!$err): ?><p class="note">ยังไม่ได้สั่งอะไรในรอบนี้ — ปุ่มด้านบนจะแสดงผลที่นี่</p><?php endif; ?>
</div>

<div class="card">
<h2>php-error.log (ท้ายไฟล์)</h2>
<pre><?= h($logTail) ?></pre>
</div>

<div class="card">
<h2>ใช้ CLI สำหรับคำสั่งที่เสี่ยง/ต้อง admin</h2>
<pre>aptstack remove app &lt;ชื่อ&gt;        ลบโค้ด app (ถามยืนยัน)
aptstack clone app &lt;จาก&gt; &lt;เป็น&gt;  ก้อปปี้โค้ด
aptstack migrate mysql &lt;ใหม่&gt;    โยกข้อมูล DB
aptstack service install         ต้อง Run as admin
aptstack tls init | tls import   HTTPS / ใส่ cert จริง</pre>
<p class="note">เพราะสั่งผ่าน web = เสี่ยงทำลายข้อมูล/ต้องสิทธิ์สูง — เจตนาไม่ให้สั่งผ่านหน้าเว็บ</p>
</div>

<div class="card" style="font-size:12.5px">
<b>ลิงก์</b>:
<a href="/">หน้าทดสอบ PHP</a> ·
<a href="/<?= h($cfg['appAlias'] ?? 'app') ?>/">แอปที่ใช้อยู่</a>
<?php if ($pma): ?> · <a href="/phpmyadmin/">phpMyAdmin</a><?php endif; ?>
<?php foreach ($apps as $a): ?> · <a href="/<?= h($a['name']) ?>/"><?= h($a['name']) ?></a><?php endforeach; ?>
</div>

</body></html>
