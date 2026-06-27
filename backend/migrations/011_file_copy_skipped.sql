-- 011_file_copy_skipped.sql — record OneNote/package items the file copy intentionally
-- skips (they can't be reconstructed via raw drive copy; need manual .onepkg migration).

ALTER TABLE file_copy_jobs ADD COLUMN skipped_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE file_copy_jobs ADD COLUMN skipped_items TEXT;  -- JSON array of skipped item paths
