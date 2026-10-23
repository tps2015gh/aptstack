<?php
/**
 * aptstack sample app #2 — Todolist (ใช้ database จริง)
 * ติดตั้งด้วย:  aptstack add app examples\todo-app todo-1.0.0
 * database:     aptstack seed   (สร้างตาราง todo_items ให้)
 *
 * ไม่มี framework — โชว์ว่า stack ต่อ PDO ได้ + CRUD เบื้องต้น
 */
declare(strict_types=1);

$root = __DIR__;
for ($i = 0; $i < 6; $i++) {
    if (is_file($root . '/aptstack.ps1') || is_file($root . '/config/stack.json')) { break; }
    $up = dirname($root); if ($up === $root) { break; } $root = $up;
}
$raw = ltrim((string)@file_get_contents($root . '/config/stack.json'), "\xEF\xBB\xBF");
$cfg = json_decode($raw, true) ?: [];

$dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
    $cfg['dbHost'] ?? '127.0.0.1', (int)($cfg['dbPort'] ?? 3307), ($cfg['dbName'] ?? 'aptstack_demo'));
$dbUser = (string)($cfg['dbUser'] ?? 'root');
$dbPass = (string)($cfg['dbPass'] ?? '');

$pdo = null; $err = '';
try {
    $pdo = new PDO($dsn, $dbUser, $dbPass, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5]);
} catch (Throwable $e) { $err = $e->getMessage(); }

// ---- action ----
$act = $_POST['act'] ?? $_GET['act'] ?? '';
$flash = '';
if ($pdo && $_SERVER['REQUEST_METHOD'] === 'POST') {
    try {
        if ($act === 'add') {
            $t = trim((string)($_POST['title'] ?? ''));
            if ($t !== '') {
                $st = $pdo->prepare('INSERT INTO todo_items (title) VALUES (?)');
                $st->execute([$t]);
                $flash = 'เพิ่มแล้ว: ' . $t;
            }
        } elseif ($act === 'toggle') {
            $st = $pdo->prepare('UPDATE todo_items SET done = 1 - done WHERE id = ?');
            $st->execute([(int)($_POST['id'] ?? 0)]);
            $flash = 'สลับสถานะแล้ว';
        } elseif ($act === 'del') {
            $st = $pdo->prepare('DELETE FROM todo_items WHERE id = ?');
            $st->execute([(int)($_POST['id'] ?? 0)]);
            $flash = 'ลบแล้ว';
        }
    } catch (Throwable $e) { $err = $e->getMessage(); }
}
$items = [];
if ($pdo) {
    try { foreach ($pdo->query('SELECT id, title, done, created_at FROM todo_items ORDER BY done, id DESC') as $r) { $items[] = $r; } }
    catch (Throwable $e) { $err = $e->getMessage(); }
}
$left = count(array_filter($items, fn($r) => !(int)$r['done']));
?>
<!DOCTYPE html>
<html lang="th"><head><meta charset="utf-8"><title>aptstack — Todolist</title>
<style>
 body{font-family:Consolas,"Leelawadee UI",Tahoma,sans-serif;background:#0f1115;color:#e6e8ee;max-width:820px;margin:40px auto;padding:0 20px;line-height:1.7}
 h1{color:#4cc2ff;font-size:26px;margin-bottom:4px}
 .card{background:#171a21;border:1px solid #262b36;border-radius:10px;padding:16px 20px;margin:16px 0}
 .ok{color:#38d178} .bad{color:#ff6b6b} .dim{color:#9aa3b2;font-size:13px}
 table{border-collapse:collapse;width:100%;font-size:14px} th,td{border:1px solid #262b36;padding:6px 10px}
 th{background:#1b1f28} tr.done td{color:#6b7280;text-decoration:line-through}
 input[type=text]{background:#1e222b;border:1px solid #3a4152;color:#e6e8ee;padding:8px 10px;border-radius:6px;width:70%}
 button{background:#2563eb;border:0;color:#fff;padding:8px 14px;border-radius:6px;cursor:pointer}
 button.sm{padding:3px 9px;font-size:12px;background:#374151} button.del{background:#7f1d1d}
 a{color:#4cc2ff}
</style></head><body>
<h1>Todolist</h1>
<p class="dim">ตัวอย่างแอปที่ 2 — ใช้ database จริง (ตาราง <code>todo_items</code>) · เหลือ <b><?= $left ?></b> งาน</p>

<div class="card">
<?php if ($flash): ?><p class="ok">✓ <?= htmlspecialchars($flash) ?></p><?php endif; ?>
<?php if ($err): ?><p class="bad">✗ <?= htmlspecialchars($err) ?></p>
  <p class="dim">ถ้าขึ้น <code>SQLSTATE[HY000] ... Unknown database</code> → รัน <code>aptstack seed</code> ก่อน</p>
<?php endif; ?>

<form method="post">
  <input type="hidden" name="act" value="add">
  <input type="text" name="title" placeholder="เพิ่มงานใหม่..." required maxlength="190">
  <button>เพิ่ม</button>
</form>

<?php if ($items): ?>
<table>
<tr><th style="width:52px">#</th><th>งาน</th><th style="width:90px">สถานะ</th><th style="width:70px">จัดการ</th></tr>
<?php foreach ($items as $r): ?>
<tr class="<?= (int)$r['done'] ? 'done' : '' ?>">
  <td><?= (int)$r['id'] ?></td>
  <td><?= htmlspecialchars((string)$r['title']) ?></td>
  <td><?= (int)$r['done'] ? '<span class="ok">เสร็จ</span>' : 'ยังไม่เสร็จ' ?></td>
  <td>
    <form method="post" style="display:inline"><input type="hidden" name="act" value="toggle"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="sm">✓</button></form>
    <form method="post" style="display:inline"><input type="hidden" name="act" value="del"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>"><button class="sm del">ลบ</button></form>
  </td>
</tr>
<?php endforeach; ?>
</table>
<?php elseif (!$err): ?><p class="dim">ยังไม่มีงาน — พิมพ์ด้านบนแล้วกดเพิ่ม</p><?php endif; ?>
</div>

<p class="dim">App version: <code><?= htmlspecialchars(basename(__DIR__)) ?></code> ·
<a href="/">กลับหน้าทดสอบ</a></p>
</body></html>
