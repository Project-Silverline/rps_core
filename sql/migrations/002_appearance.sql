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
