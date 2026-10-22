CREATE TABLE IF NOT EXISTS `users` (
    `license`    VARCHAR(60)  NOT NULL,
    `name`       VARCHAR(255) NULL,
    `group`      VARCHAR(30)  NOT NULL DEFAULT 'user',
    `created_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`license`)
);

CREATE TABLE IF NOT EXISTS `characters` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `license`     VARCHAR(60)  NOT NULL,
    `firstname`   VARCHAR(30)  NOT NULL,
    `lastname`    VARCHAR(30)  NOT NULL,
    `dob`         VARCHAR(10)  NOT NULL,
    `sex`         CHAR(1)      NOT NULL DEFAULT 'm',
    `accounts`    LONGTEXT     NULL,
    `job`         VARCHAR(50)  NOT NULL DEFAULT 'unemployed',
    `job_grade`   INT          NOT NULL DEFAULT 0,
    `position`    LONGTEXT     NULL,
    `metadata`    LONGTEXT     NULL,
    `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_played` TIMESTAMP    NULL DEFAULT NULL,
    PRIMARY KEY (`id`),
    INDEX `idx_characters_license` (`license`),
    CONSTRAINT `fk_characters_user` FOREIGN KEY (`license`) REFERENCES `users` (`license`) ON DELETE CASCADE
);

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

-- Tables used by illenium-appearance. citizenid holds the rps character id.
CREATE TABLE IF NOT EXISTS `playerskins` (
    `id`        INT          NOT NULL AUTO_INCREMENT,
    `citizenid` VARCHAR(255) NOT NULL,
    `model`     VARCHAR(255) NOT NULL,
    `skin`      TEXT         NOT NULL,
    `active`    TINYINT      NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    KEY `citizenid` (`citizenid`),
    KEY `active` (`active`)
);

CREATE TABLE IF NOT EXISTS `player_outfits` (
    `id`         INT           NOT NULL AUTO_INCREMENT,
    `citizenid`  VARCHAR(50)   NULL,
    `outfitname` VARCHAR(50)   NOT NULL DEFAULT '0',
    `model`      VARCHAR(50)   NULL,
    `props`      VARCHAR(1000) NULL,
    `components` VARCHAR(1500) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `citizenid_outfitname_model` (`citizenid`, `outfitname`, `model`),
    KEY `citizenid` (`citizenid`)
);

CREATE TABLE IF NOT EXISTS `player_outfit_codes` (
    `id`       INT         NOT NULL AUTO_INCREMENT,
    `outfitid` INT         NOT NULL,
    `code`     VARCHAR(50) NOT NULL DEFAULT '',
    PRIMARY KEY (`id`),
    KEY `FK_player_outfit_codes_player_outfits` (`outfitid`)
);

CREATE TABLE IF NOT EXISTS `management_outfits` (
    `id`         INT           NOT NULL AUTO_INCREMENT,
    `job_name`   VARCHAR(50)   NOT NULL,
    `type`       VARCHAR(50)   NOT NULL,
    `minrank`    INT           NOT NULL DEFAULT 0,
    `name`       VARCHAR(50)   NOT NULL DEFAULT 'Cool Outfit',
    `gender`     VARCHAR(50)   NOT NULL DEFAULT 'male',
    `model`      VARCHAR(50)   NULL,
    `props`      VARCHAR(1000) NULL,
    `components` VARCHAR(1500) NULL,
    PRIMARY KEY (`id`)
);
