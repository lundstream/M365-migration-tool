-- 003_preflight.sql — preflight validation results (Phase 3).

CREATE TABLE IF NOT EXISTS preflight_runs (
    run_id      TEXT PRIMARY KEY,
    created_utc TEXT NOT NULL,
    pass_count  INTEGER NOT NULL DEFAULT 0,
    warn_count  INTEGER NOT NULL DEFAULT 0,
    block_count INTEGER NOT NULL DEFAULT 0,
    notes       TEXT
);

CREATE TABLE IF NOT EXISTS preflight_results (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT NOT NULL,
    scope       TEXT NOT NULL,   -- tenant | user | site
    subject     TEXT,            -- upn / site url / 'target' etc.
    check_name  TEXT NOT NULL,
    status      TEXT NOT NULL,   -- PASS | WARN | BLOCK
    reason      TEXT,
    created_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_pf_results_run ON preflight_results (run_id);
