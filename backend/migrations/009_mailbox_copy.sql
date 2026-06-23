-- 009_mailbox_copy.sql — copy-based (Graph) mailbox migration. Source stays intact.

CREATE TABLE IF NOT EXISTS mailbox_copy_jobs (
    job_id          TEXT PRIMARY KEY,
    source_upn      TEXT NOT NULL,
    target_upn      TEXT NOT NULL,
    scope           TEXT NOT NULL DEFAULT 'mail,calendar,contacts',
    status          TEXT NOT NULL DEFAULT 'created', -- created|running|completed|failed|stopped
    phase           TEXT,                            -- download | upload | done
    mail_total      INTEGER NOT NULL DEFAULT 0,
    mail_done       INTEGER NOT NULL DEFAULT 0,
    events_total    INTEGER NOT NULL DEFAULT 0,
    events_done     INTEGER NOT NULL DEFAULT 0,
    contacts_total  INTEGER NOT NULL DEFAULT 0,
    contacts_done   INTEGER NOT NULL DEFAULT 0,
    error           TEXT,
    created_utc     TEXT NOT NULL,
    updated_utc     TEXT NOT NULL
);
