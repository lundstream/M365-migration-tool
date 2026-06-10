-- 006_file_moves.sql — OneDrive + SharePoint cross-tenant content moves (Phase 6).
-- These moves are ONE-AND-DONE (no incremental/delta passes). The unique index on
-- (type, source) enforces that a given source can only have one move job.

CREATE TABLE IF NOT EXISTS file_move_jobs (
    job_id          TEXT PRIMARY KEY,
    type            TEXT NOT NULL,            -- onedrive | site
    source          TEXT NOT NULL,            -- source UPN (onedrive) or source site URL
    target          TEXT NOT NULL,            -- target UPN or target site URL
    target_host_url TEXT,
    status          TEXT NOT NULL DEFAULT 'created', -- created|validated|scheduled|inprogress|success|failed|stopped
    move_state      TEXT,                     -- raw SPO MoveState
    preferred_begin TEXT,
    preferred_end   TEXT,
    redirect_status TEXT,
    correlation_id  TEXT,
    validation      TEXT,                     -- JSON of last validation result
    created_utc     TEXT NOT NULL,
    updated_utc     TEXT NOT NULL,
    notes           TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_file_move_source_type ON file_move_jobs (type, source);
