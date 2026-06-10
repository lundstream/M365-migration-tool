-- 007_app_state.sql — small key/value store for cross-runspace runtime state
-- (e.g. last throttle timestamp surfaced by the monitor).

CREATE TABLE IF NOT EXISTS app_state (
    key         TEXT PRIMARY KEY,
    value       TEXT,
    updated_utc TEXT NOT NULL
);
