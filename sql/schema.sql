CREATE TABLE IF NOT EXISTS suimag_dailyquest_progress (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    quest_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    period_kind ENUM('daily', 'weekly') NOT NULL,
    period_start BIGINT UNSIGNED NOT NULL,
    ends_at BIGINT UNSIGNED NOT NULL,
    target INT UNSIGNED NOT NULL,
    progress INT UNSIGNED NOT NULL DEFAULT 0,
    reward_type ENUM('bank', 'cash') NOT NULL,
    reward_amount INT UNSIGNED NOT NULL,
    reward_coin VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    reward_coin_amount TINYINT UNSIGNED NOT NULL DEFAULT 0,
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

CREATE TABLE IF NOT EXISTS suimag_dailyquest_signal_gates (
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    activity VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    last_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
    token VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    PRIMARY KEY (citizenid, activity)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_preferences (
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    exclude_crime TINYINT UNSIGNED NOT NULL,
    exclude_employment TINYINT UNSIGNED NOT NULL,
    updated_at BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_boards (
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    period_kind ENUM('daily', 'weekly') NOT NULL,
    period_start BIGINT UNSIGNED NOT NULL,
    ends_at BIGINT UNSIGNED NOT NULL,
    rerolls_used TINYINT UNSIGNED NOT NULL DEFAULT 0,
    token VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    PRIMARY KEY (citizenid, period_kind, period_start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_assignments (
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    period_kind ENUM('daily', 'weekly') NOT NULL,
    period_start BIGINT UNSIGNED NOT NULL,
    quest_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    slot TINYINT UNSIGNED NOT NULL,
    assigned_at BIGINT UNSIGNED NOT NULL,
    assigned_token VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    active TINYINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (citizenid, period_kind, period_start, quest_id),
    KEY current_slots (citizenid, period_kind, period_start, active, slot),
    KEY assigned_progress (citizenid, quest_id, period_start, active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_bonuses (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    period_start BIGINT UNSIGNED NOT NULL,
    ends_at BIGINT UNSIGNED NOT NULL,
    required_count TINYINT UNSIGNED NOT NULL,
    reward_type ENUM('bank', 'cash') NOT NULL,
    reward_amount INT UNSIGNED NOT NULL,
    status ENUM('active', 'pending', 'claimed') NOT NULL DEFAULT 'active',
    attempted_at BIGINT UNSIGNED NULL,
    claimed_at BIGINT UNSIGNED NULL,
    PRIMARY KEY (id),
    UNIQUE KEY character_day (citizenid, period_start),
    KEY pending_bonuses (status, attempted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_automation (
    id TINYINT UNSIGNED NOT NULL,
    daily_after BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

ALTER TABLE suimag_dailyquest_progress
    ADD COLUMN IF NOT EXISTS reward_coin VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS reward_coin_amount TINYINT UNSIGNED NOT NULL DEFAULT 0;


-- Validation records are separate from assignments and can never be claimed.
CREATE TABLE IF NOT EXISTS suimag_dailyquest_debug_progress (
    citizenid VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    quest_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    target INT UNSIGNED NOT NULL,
    progress INT UNSIGNED NOT NULL DEFAULT 0,
    last_day BIGINT UNSIGNED NULL,
    updated_at BIGINT UNSIGNED NULL,
    PRIMARY KEY (citizenid, quest_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS suimag_dailyquest_pool (
    quest_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    enabled TINYINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (quest_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Existing installations retain the saved entitlement for pending and claimed bonuses.
ALTER TABLE suimag_dailyquest_bonuses
    ADD COLUMN IF NOT EXISTS reward_coin VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS reward_coin_amount TINYINT UNSIGNED NOT NULL DEFAULT 0;
