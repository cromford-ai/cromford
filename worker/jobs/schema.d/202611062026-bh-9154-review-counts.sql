-- BH-9154 (Fix 5 of BH-9066): the daily review counter behind GET
-- /api/review-counts (worker/jobs/src/routes/review-counts.js) and the REVIEW
-- COUNTS panel on the console's Lead reviews screen. Additive only.
--
-- One row per (day, project, kind). `kind` is one of the seven review kinds
-- (lens, fix-rereview, lead, conductor, autopilot, rescue, resolver), counted
-- from cost_rows (one row = one model call) through the settings row
-- review_counts.kind_map, plus one `total` row per (day, project) that carries
-- n = every counted review call, merged_prs (the merge ledger) and rebinds
-- (stage_events review-saving REUSED rows). merged_prs and rebinds are NULL on
-- the kind rows: they belong to the day, not to a kind.
-- A summary table on purpose: the dashboard never aggregates cost_rows over
-- all history. The rollup rewrites only the last review_counts.rollup_days days.
--
-- Indexes, one per read:
--   GET all projects  `day >= ? GROUP BY day, kind`        the PRIMARY KEY
--   GET one project   `project = ? AND day >= ?`           idx_review_counts_daily_project
--   rollup rewrite    `DELETE ... WHERE day >= ?`          the PRIMARY KEY
--   retention ids     `day < ? ORDER BY day`               the PRIMARY KEY
-- Retention: rule review_counts_daily.archive (routes/retention.d/
-- bh-9154-review-counts.js) MOVES days older than
-- retention.review_counts_daily.days to the archive D1. History is archived,
-- never only deleted. Off (0) in the seed, like stage_events_daily.archive:
-- set it (180 is the intended window) once the ARCHIVE binding exists. The
-- table grows by about 8 rows per project per day.
CREATE TABLE IF NOT EXISTS review_counts_daily (
  day TEXT NOT NULL,               -- YYYY-MM-DD (UTC) of the source row
  project TEXT NOT NULL,
  kind TEXT NOT NULL,              -- a review kind, or 'total'
  n INTEGER NOT NULL,              -- review model calls (the total row: all kinds)
  merged_prs INTEGER,              -- total row only: PRs merged that day
  rebinds INTEGER,                 -- total row only: review-saving REUSED events that day
  updated_at TEXT NOT NULL,        -- the rollup that wrote the row
  PRIMARY KEY (day, project, kind)
);
CREATE INDEX IF NOT EXISTS idx_review_counts_daily_project ON review_counts_daily(project, day);

-- no-index: review_counts_mark one row per rollup name, read by its PRIMARY KEY
-- When the last rollup ran, so a GET rolls up at most once per
-- review_counts.rollup_every_s. One row ('review-counts'); it does not grow,
-- so it has no retention rule.
CREATE TABLE IF NOT EXISTS review_counts_mark (
  name TEXT PRIMARY KEY,
  rolled_at TEXT NOT NULL
);

-- The knobs. The kind map is a JSON list of rules, first match wins: a cost row
-- whose stage equals `stage` (and whose lane_id equals `lane`, when the rule
-- names one) counts as `kind`. fix-rereview has no rule in the seed: the
-- re-review after a fix round bills the same stage (review) and lane
-- (fly-pool) as the build lenses, so cost_rows cannot tell it apart; the
-- counter shows it as unknown, never 0, until a rule is added here.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review_counts.kind_map','[{"kind":"lead","stage":"lead-review"},{"kind":"conductor","stage":"review","lane":"merge-conductor"},{"kind":"autopilot","stage":"review","lane":"review-autopilot"},{"kind":"rescue","stage":"review","lane":"review-rescue"},{"kind":"resolver","stage":"review","lane":"blocked-resolver"},{"kind":"lens","stage":"review","lane":"fly-pool"}]','BH-9154: cost_rows stage/lane_id to review kind for the daily review counter, a JSON list of {kind, stage, lane?}, first match wins. Kinds: lens fix-rereview lead conductor autopilot rescue resolver. A kind with no rule shows as unknown. fly-pool review rows include the fix re-review calls (same stage and lane).','seed','2026-11-06T00:00:00Z'),
  ('review_counts.max_days','30','BH-9154: the most days GET /api/review-counts returns (1..366); a larger ?days= is 400.','seed','2026-11-06T00:00:00Z'),
  ('review_counts.rollup_days','2','BH-9154: days (today included) each review-counts rollup recomputes from cost_rows, the merge ledger and stage_events (1..14).','seed','2026-11-06T00:00:00Z'),
  ('review_counts.rollup_every_s','3600','BH-9154: a GET /api/review-counts rolls up first when the last rollup is older than this many seconds (0..86400; 0 = every GET).','seed','2026-11-06T00:00:00Z'),
  ('retention.review_counts_daily.days','0','BH-9154: days a review_counts_daily row stays hot (0 = off, the seed; 180 is the intended window once ARCHIVE is bound; a value below 15 runs as 15). Older days move to the archive D1 (copied, counted back, then deleted here); nothing moves while ARCHIVE is unbound.','seed','2026-11-06T00:00:00Z');
