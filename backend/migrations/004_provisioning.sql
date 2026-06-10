-- 004_provisioning.sql — target MailUser provisioning (pre-Phase-4).
-- NOTE: passwords are NEVER stored here (or in logs). They are returned once in the
-- execute API response for the operator to capture, then discarded server-side.

CREATE TABLE IF NOT EXISTS provisioning_runs (
    run_id        TEXT PRIMARY KEY,
    created_utc   TEXT NOT NULL,
    target_domain TEXT,
    created_count INTEGER NOT NULL DEFAULT 0,
    skipped_count INTEGER NOT NULL DEFAULT 0,
    failed_count  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS provisioning_results (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT NOT NULL,
    source_upn  TEXT NOT NULL,
    target_upn  TEXT,
    status      TEXT NOT NULL,   -- created | skipped | failed
    reason      TEXT,
    created_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_prov_results_run ON provisioning_results (run_id);
