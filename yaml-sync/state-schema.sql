-- State tables for betterguac-sync (the YAML -> Guacamole database sync).
-- They live in their own database, never inside Guacamole's tables.
-- Run once as root:  sudo mariadb < state-schema.sql

CREATE DATABASE IF NOT EXISTS guac_yamlsync CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

CREATE TABLE IF NOT EXISTS guac_yamlsync.sync_meta (
  id             TINYINT      NOT NULL PRIMARY KEY,
  instance_id    VARCHAR(64)  NOT NULL,
  schema_version INT          NOT NULL,
  created_at     DATETIME     NOT NULL,
  last_apply_at  DATETIME     NULL,
  last_plan_id   CHAR(64)     NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS guac_yamlsync.managed_object (
  kind       ENUM('user','connection','group') NOT NULL,
  yaml_key   VARCHAR(255) NOT NULL,
  guac_id    INT          NOT NULL,
  guac_name  VARCHAR(128) NOT NULL,
  salt       CHAR(32)     NOT NULL,
  base_json  MEDIUMTEXT   NOT NULL,
  created_at DATETIME     NOT NULL,
  updated_at DATETIME     NOT NULL,
  PRIMARY KEY (kind, yaml_key),
  UNIQUE KEY kind_guac_id (kind, guac_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS guac_yamlsync.apply_log (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  applied_at   DATETIME   NOT NULL,
  plan_id      CHAR(64)   NOT NULL,
  summary_json TEXT       NOT NULL
) ENGINE=InnoDB;
