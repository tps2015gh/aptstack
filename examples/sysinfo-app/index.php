<?php
/**
 * aptstack sample app #3 — System Info (inventory เครื่องแบบคร่าวๆ)
 * ติดตั้งด้วย:  aptstack add app examples\sysinfo-app sysinfo-1.0.0
 *
 * เก็บ/แสดง: hostname, OS, uptime, IP/Subnet/GW/DNS, CPU, RAM, disk,
 *            PHP + web server + database version
 * ทุกอย่างอ่านตอนเรียก request — ไม่มีการเขียนลง disk
 */
declare(strict_types=1);

$root = __DIR__;
for ($i = 0; $i < 6; $i++) {
    if (is_file($root . '/aptstack.ps1') || is_file($root . '/config/stack.json')) { break; }
    $up = dirname($root); if ($up === $root) { break; } $root = $up;
}
$cfg = json_decode(ltrim((string)@file_get_contents($root . '/config/stack.json'), "\xEF\xBB\xBF"), true) ?: [];

/** รันคำสั่งสั้น ๆ แบบปลอดภัย (timeout สั้น, ไม่มี input จากผู้ใช้) */
function sh(string $cmd): string {
    if (!function_exists('shell_exec')) return '';
    $out = @shell_exec($cmd . ' 2>nul');
    return is_string($out) ? trim($out) : '';
}

$info = [];

// --- OS / CPU / RAM ผ่าน PowerShell CIM (wmic ถูกถอดออกจาก Win11 24H2 แล้ว) ---
// เรียนครั้งเดียวเป็น JSON -> เร็วกว่าเรียกหลายคำสั่ง
$ps = 'powershell -NoProfile -Command "$o=[ordered]@{os=(Get-CimInstance Win32_OperatingSystem).Caption;boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString(\'yyyy-MM-dd HH:mm\');ramGB=[math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize/1MB,1);freeGB=[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,1);cpu=(Get-CimInstance Win32_Processor).Name;cores=(Get-CimInstance Win32_Processor).NumberOfCores;threads=(Get-CimInstance Win32_Processor).NumberOfLogicalProcessors};$o|ConvertTo-Json -Compress"';
$w = sh($ps);
$win = $w !== '' ? json_decode($w, true) : null;
$info['Hostname'] = gethostname() ?: '-';
if (is_array($win)) {
    $info['OS'] = (string)($win['os'] ?? php_uname('s'));
    if (!empty($win['boot'])) {
        $info['Boot time'] = $win['boot'];
        try { $info['Uptime'] = (new DateTime())->diff(new DateTime($win['boot']))->days . ' วัน'; } catch (Throwable $e) {}
    }
    if (!empty($win['cpu'])) {
        $info['CPU']   = $win['cpu'];
        $info['Cores'] = (($win['cores'] ?? '') ?: '-') . ' cores / ' . (($win['threads'] ?? '') ?: '-') . ' threads';
    }
    if (!empty($win['ramGB'])) {
        $info['RAM'] = sprintf('%.1f GB (ว่าง %.1f GB)', $win['ramGB'], $win['freeGB'] ?? 0);
    }
} else {
    // fallback ถ้า PowerShell ใช้ไม่ได้
    $info['OS'] = php_uname('s') . ' ' . php_uname('m');
    $info['CPU'] = '(PowerShell CIM ไม่ตอบ — ตรวจสอบด้วย Get-CimInstance Win32_Processor)';
}
if (empty($info['OS'])) { $info['OS'] = php_uname('s') . ' ' . php_uname('m'); }

// --- network: ipconfig /all ---
$ip = sh('ipconfig /all');
$cur = ['adapter' => '', 'ip' => '', 'mask' => '', 'gw' => '', 'dns' => []];
$nics = [];
foreach (preg_split('/\r?\n/', $ip) as $line) {
    if (preg_match('/^\s*adapter\s+(.+?):\s*$/iu', $line, $m)) {
        if ($cur['ip'] !== '') { $nics[] = $cur; }
        $cur = ['adapter' => trim($m[1]), 'ip' => '', 'mask' => '', 'gw' => '', 'dns' => []];
    } elseif (preg_match('/IPv4.*?(\d+\.\d+\.\d+\.\d+)/u', $line, $m)) { $cur['ip'] = $m[1]; }
    elseif (preg_match('/Subnet Mask.*?(\d+\.\d+\.\d+\.\d+)/u', $line, $m)) { $cur['mask'] = $m[1]; }
    elseif (preg_match('/Default Gateway.*?(\d+\.\d+\.\d+\.\d+)/u', $line, $m)) { if ($cur['gw'] === '') $cur['gw'] = $m[1]; }
    elseif (preg_match('/DNS Servers.*?(\d+\.\d+\.\d+\.\d+)/u', $line, $m)) { $cur['dns'][] = $m[1]; }
}
if ($cur['ip'] !== '') { $nics[] = $cur; }
$actives = array_values(array_filter($nics, fn($n) => $n['ip'] !== '' && stripos($n['adapter'], 'Loopback') === false));
foreach ($actives as $k => $n) {
    $info['Adapter #' . ($k + 1)] = $n['adapter'];
    $info['  IPv4']      = $n['ip'];
    $info['  Subnet']    = $n['mask'];
    $info['  Gateway']   = $n['gw'];
    if ($n['dns']) { $info['  DNS'] = implode(', ', $n['dns']); }
}
// network class (คร่าว ๆ) จาก subnet mask
if (!empty($actives[0]['mask'])) {
    $parts = array_map('intval', explode('.', $actives[0]['mask']));
    $bits = 0; foreach ($parts as $p) { $bits += substr_count(decbin($p), '1'); }
    $hostBits = 32 - $bits;
    $hosts = $hostBits < 31 ? (pow(2, $hostBits) - 2) : 0;
    $info['  Network'] = preg_replace('/\.\d+$/', '.0/' . $bits, $actives[0]['ip']) . "  (~{$hosts} hosts)";
}

// --- disk ---
foreach ([['C:\\', 'Disk C:']] as [$p, $label]) {
    if (@disk_total_space($p)) {
        $info[$label] = sprintf('%.0f GB free / %.0f GB',
            @disk_free_space($p) / 1073741824, @disk_total_space($p) / 1073741824);
    }
}

// --- stack / runtime ---
$info['PHP']       = PHP_VERSION . '  (' . php_sapi_name() . ', ZTS=' . (ZEND_THREAD_SAFE ? 'Y' : 'N') . ')';
$info['Web']       = $_SERVER['SERVER_SOFTWARE'] ?? 'php built-in';
$info['App ver']   = basename(__DIR__);
$cfgFile = $root . '/config/stack.json';
if (is_readable($cfgFile)) {
    $info['httpPort'] = (string)($cfg['httpPort'] ?? '-');
    $info['dbPort']   = (string)($cfg['dbPort'] ?? '-');
    $info['webMode']  = (string)($cfg['webMode'] ?? 'auto');
    $info['https']    = (string)($cfg['httpsEnabled'] ?? 'false');
}
try {
    $pdo = new PDO(sprintf('mysql:host=%s;port=%d', $cfg['dbHost'] ?? '127.0.0.1', (int)($cfg['dbPort'] ?? 3307)),
        (string)($cfg['dbUser'] ?? 'root'), (string)($cfg['dbPass'] ?? ''),
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 4]);
    $info['Database'] = 'MariaDB/MySQL ' . $pdo->query('SELECT VERSION()')->fetchColumn() . '  (เชื่อมต่อ OK)';
    $dbs = [];
    foreach ($pdo->query('SHOW DATABASES') as $r) { $dbs[] = $r['Database']; }
    $info['Databases'] = implode(', ', $dbs);
} catch (Throwable $e) {
    $info['Database'] = 'เชื่อมต่อไม่ได้: ' . $e->getMessage();
}
?>
<!DOCTYPE html>
<html lang="th"><head><meta charset="utf-8"><title>aptstack — System Info</title>
<style>
 body{font-family:Consolas,"Leelawadee UI",Tahoma,sans-serif;background:#0f1115;color:#e6e8ee;max-width:860px;margin:40px auto;padding:0 20px;line-height:1.7}
 h1{color:#4cc2ff;font-size:26px;margin-bottom:4px}
 .card{background:#171a21;border:1px solid #262b36;border-radius:10px;padding:16px 20px;margin:16px 0}
 table{border-collapse:collapse;width:100%;font-size:14px}
 th,td{border:1px solid #262b36;padding:6px 10px;vertical-align:top;word-break:break-word}
 th{background:#1b1f28;width:170px;color:#9fe8ff;text-align:left}
 .dim{color:#9aa3b2;font-size:13px} code{background:#1e222b;border:1px solid #262b36;border-radius:4px;padding:1px 6px;color:#9fe8ff}
 a{color:#4cc2ff}
</style></head><body>
<h1>System Info</h1>
<p class="dim">ตัวอย่างแอปที่ 3 — inventory เครื่องแบบคร่าวๆ อ่านตอนเรียก request (ไม่เขียนไฟล์) ·
App: <code><?= htmlspecialchars(basename(__DIR__)) ?></code></p>

<div class="card">
<table>
<?php foreach ($info as $k => $v): ?>
<tr><th><?= htmlspecialchars($k) ?></th><td><?= htmlspecialchars((string)$v) ?></td></tr>
<?php endforeach; ?>
</table>
</div>

<p class="dim">สลับไปแอปอื่น: <code>aptstack next</code> / <code>aptstack prev</code> / <code>aptstack use &lt;name&gt;</code><br>
<a href="/">กลับหน้าทดสอบ</a></p>
</body></html>
