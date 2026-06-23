-- 010_file_copy.sql — copy-based (Graph) OneDrive + SharePoint file migration. Source intact.

CREATE TABLE IF NOT EXISTS file_copy_jobs (
    job_id       TEXT PRIMARY KEY,
    type         TEXT NOT NULL,            -- onedrive | site
    source       TEXT NOT NULL,            -- source UPN (onedrive) or source site URL
    target       TEXT NOT NULL,            -- target UPN or target site URL
    status       TEXT NOT NULL DEFAULT 'created', -- created|running|completed|failed
    phase        TEXT,                     -- download | upload | done
    files_total  INTEGER NOT NULL DEFAULT 0,
    files_done   INTEGER NOT NULL DEFAULT 0,
    bytes_total  INTEGER NOT NULL DEFAULT 0,
    error        TEXT,
    created_utc  TEXT NOT NULL,
    updated_utc  TEXT NOT NULL
);
