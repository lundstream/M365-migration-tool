-- 012_copy_status.sql — richer live status + resume support for copy jobs.

-- Mailbox copy: download-progress + dedup/skip counters, a human-readable activity line,
-- and a start timestamp for rate/ETA.
ALTER TABLE mailbox_copy_jobs ADD COLUMN mail_downloaded INTEGER NOT NULL DEFAULT 0;
ALTER TABLE mailbox_copy_jobs ADD COLUMN mail_skipped    INTEGER NOT NULL DEFAULT 0;
ALTER TABLE mailbox_copy_jobs ADD COLUMN events_skipped  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE mailbox_copy_jobs ADD COLUMN contacts_skipped INTEGER NOT NULL DEFAULT 0;
ALTER TABLE mailbox_copy_jobs ADD COLUMN detail          TEXT;
ALTER TABLE mailbox_copy_jobs ADD COLUMN started_utc     TEXT;

-- File copy: skipped-existing counter, activity line, start timestamp.
ALTER TABLE file_copy_jobs ADD COLUMN files_skipped INTEGER NOT NULL DEFAULT 0;
ALTER TABLE file_copy_jobs ADD COLUMN detail        TEXT;
ALTER TABLE file_copy_jobs ADD COLUMN started_utc   TEXT;
