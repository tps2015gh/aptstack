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
