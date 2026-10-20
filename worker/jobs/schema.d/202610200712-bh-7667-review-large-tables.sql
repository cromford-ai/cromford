-- BH-7667: the large-table list of the migration index lint
-- (bin/lib/migration-index-lint.sh, read through rl_knob as
-- review.large_tables.<project>, then review.large_tables). A plain CREATE INDEX
-- on a listed table is a [BLOCK destructive-migration] in the lead and box
-- review. project-6-os: event (about 12 GB in prod; #1920, #1910, #2016).
-- Names are comma- or space-separated. No row = no lint for that project.
-- Data only: no new table, so no index, no RLS and no retention rule apply
-- (D1 is SQLite). INSERT OR IGNORE keeps an operator's value.
-- Rollback: delete the row; the next review runs no lint for project-6-os.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review.large_tables.project-6-os','event','BH-7667: tables where a plain CREATE INDEX (no CONCURRENTLY) blocks writes in prod; the migration lint BLOCKs it in the lead and box review. Comma-separated','seed','2026-10-20T00:00:00Z');
