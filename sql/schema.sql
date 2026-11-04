CREATE TABLE IF NOT EXISTS suimag_dailyquest_progress (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    quest_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    period_kind ENUM('daily', 'weekly') NOT NULL,
    period_start BIGINT UNSIGNED NOT NULL,
    ends_at BIGINT UNSIGNED NOT NULL,
    target INT UNSIGNED NOT NULL,
    progress INT UNSIGNED NOT NULL DEFAULT 0,
    reward_type ENUM('bank', 'cash', 'item') NOT NULL,
    reward_name VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    reward_amount INT UNSIGNED NOT NULL,
    status ENUM('active', 'pending', 'claimed') NOT NULL DEFAULT 'active',
    attempted_at BIGINT UNSIGNED NULL,
    claimed_at BIGINT UNSIGNED NULL,
    PRIMARY KEY (id),
    UNIQUE KEY character_quest_period (citizenid, quest_id, period_start),
    KEY pending_claims (status, attempted_at),
    KEY expired_periods (ends_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_visits (
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    day_start BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (citizenid, day_start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_events (
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    activity VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    receipt VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    processed TINYINT UNSIGNED NOT NULL DEFAULT 0,
    created_at BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (citizenid, activity, receipt)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_signal_gates (
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    activity VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    last_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
    token VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    PRIMARY KEY (citizenid, activity)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
