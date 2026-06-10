-- 001_init.sql — foundational schema for the M365 migration tool.
-- Later phases add migrations (mappings, batches, items, SPO move jobs).
-- Each statement uses IF NOT EXISTS so re-running is safe.

CREATE TABLE IF NOT EXISTS schema_version (
    version     INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    applied_utc TEXT    NOT NULL
);

-- One row per logical run (preflight, setup, mailbox batch, file move, etc.).
CREATE TABLE IF NOT EXISTS runs (
    run_id      TEXT PRIMARY KEY,
    kind        TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'started',
    started_utc TEXT NOT NULL,
    ended_utc   TEXT,
    notes       TEXT
);

-- Append-only audit trail of every mutating action (who / when / what).
CREATE TABLE IF NOT EXISTS audit_log (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id         TEXT,
    correlation_id TEXT,
    actor          TEXT,
    action         TEXT NOT NULL,
    target         TEXT,
    detail         TEXT,
    created_utc    TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_audit_run ON audit_log (run_id);
CREATE INDEX IF NOT EXISTS ix_runs_kind ON runs (kind);
