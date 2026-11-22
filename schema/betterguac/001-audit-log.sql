--
-- BetterGuac schema migration 001: activity log and audit trail.
--
-- Applied by `betterguac-setup migrate` (the .deb runs it on every configure,
-- the Docker image on every start) as the MariaDB root user over the local
-- socket. Every statement is idempotent, so running this file twice is safe;
-- the runner also records it in bg_schema_migration so it is applied once.
--

-- Which BetterGuac migrations this database has had.
CREATE TABLE IF NOT EXISTS bg_schema_migration (
    version         INT          NOT NULL,
    name            VARCHAR(128) NOT NULL,
    checksum        CHAR(64)     NOT NULL,
    package_version VARCHAR(64)  NULL,
    applied_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- One row per thing that happened: sign-ins, failed sign-ins, two-factor
-- steps, sign-outs, admin changes, YAML sync applies, audit settings.
-- Sessions on servers come from Guacamole's own guacamole_connection_history
-- and are merged in when the log is read, so they are not copied here.
CREATE TABLE IF NOT EXISTS bg_audit_event (
    event_id     BIGINT        NOT NULL AUTO_INCREMENT,
    event_time   DATETIME(3)   NOT NULL,
    category     VARCHAR(16)   NOT NULL,   -- auth, mfa, user, server, group, permission, session, sync, audit
    action       VARCHAR(48)   NOT NULL,   -- e.g. auth.login, auth.failed, user.updated
    outcome      VARCHAR(8)    NOT NULL,   -- success, failure, info
    actor        VARCHAR(128)  NULL,       -- who did it (sign-in name), NULL if unknown
    remote_addr  VARCHAR(256)  NULL,       -- where they came from
    target_type  VARCHAR(32)   NULL,       -- user, server, group, folder, session, plan
    target_id    VARCHAR(128)  NULL,
    target_name  VARCHAR(256)  NULL,
    detail       VARCHAR(1024) NULL,
    source       VARCHAR(16)   NOT NULL DEFAULT 'web',  -- web, yaml-sync, cli, system
    PRIMARY KEY (event_id),
    KEY bg_audit_event_time (event_time),
    KEY bg_audit_event_actor (actor, event_time),
    KEY bg_audit_event_category (category, event_time),
    KEY bg_audit_event_target (target_type, target_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Small key/value store for BetterGuac settings that live in the database.
CREATE TABLE IF NOT EXISTS bg_setting (
    name       VARCHAR(64)   NOT NULL,
    value      VARCHAR(1024) NOT NULL,
    updated_at DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    updated_by VARCHAR(128)  NULL,
    PRIMARY KEY (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Defaults: keep activity for a year, keep session history forever
-- (0 = never delete). Existing values are left alone.
INSERT IGNORE INTO bg_setting (name, value) VALUES ('audit.retention-days', '365');
INSERT IGNORE INTO bg_setting (name, value) VALUES ('audit.session-history-retention-days', '0');

-- Session start/end rows are read from guacamole_connection_history, which
-- upstream already indexes on start_date and end_date.
