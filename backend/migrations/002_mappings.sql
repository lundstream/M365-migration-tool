-- 002_mappings.sql — identity mapping (Phase 2).

-- Cached directory snapshots pulled from Graph (read-only on the tenants).
CREATE TABLE IF NOT EXISTS directory_users (
    tenant          TEXT NOT NULL,          -- source | target
    user_id         TEXT NOT NULL,
    upn             TEXT,
    display_name    TEXT,
    mail            TEXT,
    proxy_addresses TEXT,                    -- JSON array of lowercased smtp addresses
    account_enabled INTEGER,
    fetched_utc     TEXT NOT NULL,
    PRIMARY KEY (tenant, user_id)
);
CREATE INDEX IF NOT EXISTS ix_dir_users_upn ON directory_users (tenant, upn);

-- The source->target mapping (one row per source user).
CREATE TABLE IF NOT EXISTS mappings (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    source_upn          TEXT NOT NULL UNIQUE,
    source_id           TEXT,
    source_display_name TEXT,
    target_upn          TEXT,
    target_id           TEXT,
    target_display_name TEXT,
    target_exists       INTEGER NOT NULL DEFAULT 0,   -- target_upn found in target directory?
    match_state         TEXT NOT NULL DEFAULT 'unmatched', -- matched | unmatched | conflict
    match_method        TEXT,                          -- upn | proxy | csv | manual
    notes               TEXT,
    updated_utc         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_mappings_state ON mappings (match_state);
