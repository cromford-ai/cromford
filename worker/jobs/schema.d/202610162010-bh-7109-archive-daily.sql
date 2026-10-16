-- ── BH-7109: the stage_events_daily archive rule (Scope 4 of BH-6779) ───────
-- routes/retention.js rule `stage_events_daily.archive` moves daily rollup
-- rows older than this window to the archive D1 (env.ARCHIVE) through
-- lib/archive-daily.js: copy, count back by key and value, then delete here.
-- 0 = off, the seed: ARCHIVE is not bound in prod yet. Additive only.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.stage_events_daily.archive_days','0','BH-7109: stage_events_daily rows older than this many days move to the harness-archive D1 (copied, counted back by key and value, then deleted here); 0 = off. Nothing is deleted while ARCHIVE is unbound.','seed','2026-10-16T00:00:00Z');
