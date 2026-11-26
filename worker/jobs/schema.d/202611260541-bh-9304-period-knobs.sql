-- ── BH-9304 (BH-9120.0): the shared period knobs ───────────────────────────
-- mc.period.*: read by readPeriodKnobs (src/lib/period.js) in ONE statement,
-- answered by GET /api/period/knobs, and used by GET /api/jobs?from=&to=
-- (max_range_days) and by the console's default period (default_preset).
--   max_range_days  the longest from/to range a route takes; longer is a 400.
--   csv_row_cap     a CSV export stops here; its last line says so.
--   default_preset  the period a screen shows with no from/to in its URL.
--   max_buckets     the most chart buckets a series route answers.
-- Data only: no new table, so no index, no RLS and no retention rule apply.
-- INSERT OR IGNORE keeps an operator's value on a re-apply.
-- Rollback: edit the rows. The code fallbacks (PERIOD_FALLBACKS) hold the same
-- values, so a deleted row changes nothing.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('mc.period.max_range_days','366','BH-9304: the longest from/to range in days a period route takes; a longer one is a 400. Fallback 366.','seed','2026-11-14T21:41:00Z'),
  ('mc.period.csv_row_cap','100000','BH-9304: the most rows a period CSV export writes; then a "# truncated at <cap>" line. Fallback 100000.','seed','2026-11-14T21:41:00Z'),
  ('mc.period.default_preset','last_7_days','BH-9304: the period a screen shows with no from/to in its URL (today, yesterday, last_7_days, last_30_days, this_month, last_month). Fallback last_7_days.','seed','2026-11-14T21:41:00Z'),
  ('mc.period.max_buckets','2000','BH-9304: the most chart buckets a period series route answers. Fallback 2000.','seed','2026-11-14T21:41:00Z');
