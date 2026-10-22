-- Adds owned vehicles, used by ox_inventory for trunks and gloveboxes
-- and by the upcoming garage resource.
CREATE TABLE IF NOT EXISTS `rps_vehicles` (
    `id`      INT         NOT NULL AUTO_INCREMENT,
    `charid`  INT         NOT NULL,
    `plate`   VARCHAR(8)  NOT NULL,
    `model`   VARCHAR(50) NOT NULL,
    `props`   LONGTEXT    NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_rps_vehicles_plate` (`plate`),
    INDEX `idx_rps_vehicles_charid` (`charid`),
    CONSTRAINT `fk_rps_vehicles_character` FOREIGN KEY (`charid`) REFERENCES `characters` (`id`) ON DELETE CASCADE
);
