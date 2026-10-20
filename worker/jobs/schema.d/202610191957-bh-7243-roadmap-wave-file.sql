-- ── BH-7243.4 (BH-7267): roadmap wave approve, file and issue sync knobs ────
-- Settings rows only. No table is created here: every table and index this
-- slice reads and writes is in 202610182038-bh-7243-roadmap-ideas.sql.
-- Reader: src/routes/roadmap-wave-file.js, through settingsRows (one memoized
-- settings read per request). The lanes bin/roadmap-file.sh and
-- bin/roadmap-issue-sync.sh read none of them directly: the routes apply them.
-- Note: docs/notes/2026-10-17-BH-7243.4-roadmap-wave-file.md.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('roadmap.issue_sync_batch','50','BH-7243.4: the most stale issue links GET /api/roadmap/links/stale answers in one call (1..200); a larger ?limit= is lowered to it','seed','2026-10-17T06:02:00Z'),
  ('roadmap.issue_sync_stale_min','30','BH-7243.4: minutes after which a linked issue state is read again by the sync lane (1..10080)','seed','2026-10-17T06:02:00Z'),
  ('roadmap.approve_requires_identity','0','BH-7243.4: 1 also refuses the console fallback actor when a wave is approved (0|1)','seed','2026-10-17T06:02:00Z'),
  ('roadmap.file_retry_min','30','BH-7243.4: minutes before a filing wave whose lane died is claimed again, and before an approved wave that carries an error is retried (1..1440)','seed','2026-10-17T06:02:00Z');
