-- ── BH-7977 (BH-7939.3): first_run.gate ─────────────────────────────────────
-- 1 = the console's `/` shows the first-run screen while a required fleet
-- account (Claude, GitHub App, Telegram) is missing; 0 = never. Seeded ONCE per
-- database: 0 when `jobs` or `projects` already holds a row at apply time (an
-- existing fleet keeps its Fleet list), else 1 (a new fleet). An operator
-- changes it on /config like any settings row. Code fallback with no row: 0,
-- in src/routes/fleet-first-run.js. Note: docs/notes/2026-10-25-BH-7977-first-run.md.
-- No table, so no index and no retention rule. INSERT OR IGNORE, so a re-apply
-- through bin/harness-sync.sh is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at)
SELECT 'first_run.gate',
  CASE WHEN EXISTS(SELECT 1 FROM jobs) OR EXISTS(SELECT 1 FROM projects) THEN '0' ELSE '1' END,
  'BH-7977: 1 = / shows the first-run screen while a required fleet account is missing; 0 = never. Seeded 0 on a fleet that already had jobs or projects. Code fallback 0 (no row) in worker/jobs/src/routes/fleet-first-run.js',
  'seed', '2026-10-25T05:46:00Z';
