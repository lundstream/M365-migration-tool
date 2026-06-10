-- 005_mailbox_batches.sql — cross-tenant mailbox batch executor (Phase 5).
-- State is persisted so batches survive a crash/restart and can be reconciled with EXO.

CREATE TABLE IF NOT EXISTS mailbox_batches (
    batch_id               TEXT PRIMARY KEY,    -- our id (mbx-...)
    name                   TEXT NOT NULL,
    exo_batch_name         TEXT NOT NULL,
    status                 TEXT NOT NULL DEFAULT 'created', -- created|syncing|synced|completing|completed|failed|stopped
    source_endpoint        TEXT,
    target_delivery_domain TEXT,
    item_count             INTEGER NOT NULL DEFAULT 0,
    created_utc            TEXT NOT NULL,
    updated_utc            TEXT NOT NULL,
    completed_utc          TEXT,
    notes                  TEXT
);

CREATE TABLE IF NOT EXISTS mailbox_batch_items (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id        TEXT NOT NULL,
    source_upn      TEXT NOT NULL,
    target_upn      TEXT,
    correlation_id  TEXT,
    status          TEXT NOT NULL DEFAULT 'queued', -- queued|syncing|synced|completing|completed|failed|stopped
    exo_status      TEXT,
    percent         INTEGER,
    error           TEXT,
    forwarding_set  INTEGER NOT NULL DEFAULT 0,
    last_status_utc TEXT
);
CREATE INDEX IF NOT EXISTS ix_mbx_items_batch ON mailbox_batch_items (batch_id);
