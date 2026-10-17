-- BH-6774 C0: the archive store. Cold history moves from this database (the
-- hot store, harness-jobs) to a second D1 database, harness-archive, bound as
-- ARCHIVE (worker/jobs/src/lib/archive.js). The worker creates the archive's
-- tables itself from these tables' columns; nothing here runs on the archive.
--
-- The cost_rows.archive retention rule (worker/jobs/src/routes/retention.js)
-- reads cost rows older than its window oldest first. idx_cost_rows_ts serves
-- that read; 202610141900-bh-6727-d1-read-indexes.sql creates it.

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.cost_rows.archive_days','0','BH-6774: cost rows older than this many days move to the harness-archive D1 (copied, counted back, then deleted here); 0 = off. A value below 60 runs as 60 (the widest hot-only cost_rows reader window; every wider reader reads the archive too). They are never deleted without the copy, and nothing moves while ARCHIVE is unbound.','seed','2026-10-14T00:00:00Z'),
  ('retention.stage_events.archive','0','BH-6774: 1 = the stage_events retention rule copies the events to the harness-archive D1 before it rolls them up and deletes them; 0 = roll up and delete only (BH-6750).','seed','2026-10-14T00:00:00Z');
