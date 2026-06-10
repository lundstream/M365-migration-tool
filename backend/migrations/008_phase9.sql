-- 008_phase9.sql — groups, shared-mailbox permissions, and the pre-migration manifest.

-- Source groups (cache) + their target counterpart once created.
CREATE TABLE IF NOT EXISTS groups (
    group_id        TEXT PRIMARY KEY,     -- source group object id
    display_name    TEXT,
    mail_nickname   TEXT,
    mail            TEXT,
    group_kind      TEXT,                 -- security | distribution | m365 | mailSecurity
    member_count    INTEGER DEFAULT 0,
    target_group_id TEXT,
    status          TEXT NOT NULL DEFAULT 'discovered', -- discovered | created | skipped | failed
    detail          TEXT,
    fetched_utc     TEXT
);
CREATE TABLE IF NOT EXISTS group_members (
    group_id   TEXT NOT NULL,
    member_id  TEXT NOT NULL,
    member_upn TEXT,
    PRIMARY KEY (group_id, member_id)
);

-- Shared-mailbox (and any mailbox) delegate permissions captured from source.
CREATE TABLE IF NOT EXISTS mailbox_permissions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    mailbox_upn   TEXT NOT NULL,
    perm_type     TEXT NOT NULL,          -- FullAccess | SendAs | SendOnBehalf
    trustee_upn   TEXT,
    captured_utc  TEXT NOT NULL,
    reapplied     INTEGER NOT NULL DEFAULT 0,
    reapply_error TEXT
);
CREATE INDEX IF NOT EXISTS ix_mbxperm_mbx ON mailbox_permissions (mailbox_upn);

-- Pre-migration manifest: an inventory snapshot (NOT a content backup). The restore path is
-- keeping the source tenant intact; this proves what existed and feeds reconciliation.
CREATE TABLE IF NOT EXISTS manifest_runs (
    manifest_id    TEXT PRIMARY KEY,
    created_utc    TEXT NOT NULL,
    mailbox_count  INTEGER NOT NULL DEFAULT 0,
    onedrive_count INTEGER NOT NULL DEFAULT 0,
    site_count     INTEGER NOT NULL DEFAULT 0,
    notes          TEXT
);
CREATE TABLE IF NOT EXISTS manifest_items (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    manifest_id  TEXT NOT NULL,
    kind         TEXT NOT NULL,           -- mailbox | onedrive | site
    identity     TEXT,                    -- upn or URL
    display_name TEXT,
    size_bytes   INTEGER,
    item_count   INTEGER,
    detail       TEXT,                    -- JSON (template, owner, permissions, ...)
    created_utc  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_manifest_items_run ON manifest_items (manifest_id);
