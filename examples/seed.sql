-- ==========================================================================
-- aptstack demo seed — database จำลองตัวเล็ก ไว้พิสูจน์ว่าใช้ DB ได้
-- รันด้วย:  aptstack seed
-- ปลอดภัย:  สร้างเฉพาะฐานชื่อ aptstack_demo ไม่แตะฐานอื่น
-- ==========================================================================

-- บังคับ charset ตั้งแต่แรก ไม่งั้นตัวหนังสือไทยถูกเก็บเป็น ???
SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS `aptstack_demo`
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

USE `aptstack_demo`;

CREATE TABLE IF NOT EXISTS `greetings` (
  `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `message`    VARCHAR(190) NOT NULL,
  `created_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `greetings` (`id`, `message`) VALUES
  (1, 'สวัสดี — aptstack + MariaDB ทำงานแล้ว'),
  (2, 'sample row 2: ใช้ PDO/mysql client ได้จริง'),
  (3, 'sample row 3: เปลี่ยนเวอร์ชันด้วย aptstack use <ver>')
ON DUPLICATE KEY UPDATE `message` = VALUES(`message`);

-- ตรวจนับหลัง import (จะโชว์ในผลลัพธ์ของ aptstack seed)
SELECT COUNT(*) AS greetings_rows FROM `greetings`;

-- --------------------------------------------------------------------------
-- ตารางสำหรับตัวอย่างแอป #2 (Todolist) — aptstack add app examples\todo-app todo-1.0.0
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `todo_items` (
  `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `title`      VARCHAR(190) NOT NULL,
  `done`       TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_done` (`done`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `todo_items` (`title`, `done`) VALUES
  ('เพิ่มตัวอย่าง todolist ลง stack', 1),
  ('รัน aptstack seed ให้เสร็จ', 1),
  ('ลองสลับเวอร์ชันแอปด้วย aptstack next', 0),
  ('เปิด https://127.0.0.1:8443/ ดู (ถ้าเปิด TLS แล้ว)', 0)
ON DUPLICATE KEY UPDATE `title` = VALUES(`title`);

SELECT COUNT(*) AS todo_rows FROM `todo_items`;
