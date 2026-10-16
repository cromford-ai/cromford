-- ── BH-5808 (BH-5794.3): measure and retire lessons ──────────────────────────
-- The block-learning loop's third wave (#5794). bin/lesson-measure.sh (hub,
-- daily) records every merged lesson PR or issue of bin/lesson-propose.sh
-- (#5807) here, one row each, and judges it once a week: the BLOCK rate of its
-- category per 100 reviewed PRs in the window_days before and after the merge.
-- Routes: worker/jobs/src/routes/lessons.js. Note:
-- docs/notes/2026-10-16-BH-5808-lesson-measure.md.
--
-- RETENTION. A history table (1 to 5 rows a week, about 260 a year). Rows are
-- kept, never deleted (BH-6730: history rows are archived, never deleted).
-- The weekly tick runs POST /api/lessons/retention, which only COUNTS the
-- judged rows older than lessons.retention_days, and records that count in
-- the week's ledgers row (kind lesson_measure). A delete would let the daily
-- sweep record an old lesson_proposal ledger row again as a new row.
CREATE TABLE IF NOT EXISTS lessons (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category TEXT NOT NULL,          -- block_categories id
  change_type TEXT NOT NULL,       -- plan-lesson | builder-rule | check | harness-bug
  kind TEXT NOT NULL,              -- pr | issue
  repo TEXT NOT NULL,              -- owner/name
  number INTEGER NOT NULL,
  url TEXT,
  title TEXT,
  source TEXT NOT NULL,            -- proposal | escalation
  merged_at TEXT NOT NULL,         -- the PR merge, or the issue close as completed
  status TEXT NOT NULL DEFAULT 'measuring', -- measuring | working | not-working | inconclusive | superseded | removed
  before_blocks INTEGER,
  before_reviewed INTEGER,
  after_blocks INTEGER,
  after_reviewed INTEGER,
  after_end TEXT,
  cut_pct REAL,
  measured_at TEXT,
  escalation_stage TEXT,           -- the stronger stage filed for a not-working row
  escalation_number INTEGER,       -- its ai-build issue
  escalation_url TEXT,
  superseded_by INTEGER,           -- lessons.id of the later check or harness fix
  removal_number INTEGER,          -- the PR that removes the §10 bullet; superseded only after it merges
  removal_url TEXT,
  removal_note TEXT,               -- absent = no bullet to remove, no PR
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(repo, kind, number)
);
-- measure (status = 'measuring'), pending escalate (status = 'not-working').
CREATE INDEX IF NOT EXISTS idx_lessons_status ON lessons(status, merged_at);
-- digest: GROUP BY category, status (covering, removal_number for `removing`).
CREATE INDEX IF NOT EXISTS idx_lessons_cat ON lessons(category, status, merged_at, removal_number);
-- pending retire: change_type IN ('plan-lesson', 'check', 'harness-bug').
CREATE INDEX IF NOT EXISTS idx_lessons_type ON lessons(change_type, category, merged_at);
-- digest list (ORDER BY merged_at DESC), retention (merged_at < cutoff).
CREATE INDEX IF NOT EXISTS idx_lessons_merged ON lessons(merged_at);
-- record (an escalation issue takes its stage), pending escalated_open.
CREATE INDEX IF NOT EXISTS idx_lessons_esc ON lessons(escalation_number);
-- The reviewed-PR counts read verdicts by created_at (measure, digest); the
-- table had only idx_verdicts_pr_head. Additive: the append-only triggers
-- (src/lib/core.js CREATED_TABLES.verdicts) are not touched.
CREATE INDEX IF NOT EXISTS idx_verdicts_created ON verdicts(created_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lessons.window_days','14','BH-5808: days before and after a lesson merge that POST /api/lessons/measure compares','seed','2026-10-16T00:00:00Z'),
  ('lessons.min_reviewed','30','BH-5808: reviewed PRs the after-window must hold before a lesson is judged','seed','2026-10-16T00:00:00Z'),
  ('lessons.min_cut_pct','30','BH-5808: the cut of the category BLOCK rate (percent) that makes a lesson working','seed','2026-10-16T00:00:00Z'),
  ('lessons.max_window_days','42','BH-5808: days the after-window may grow to reach lessons.min_reviewed; past it the lesson is inconclusive','seed','2026-10-16T00:00:00Z'),
  ('lessons.digest_days','7','BH-5808: days GET /api/lessons/digest counts by default','seed','2026-10-16T00:00:00Z'),
  ('lessons.stage_order','plan-lesson,builder-rule,check,harness-bug','BH-5808: the stages from weakest to strongest; a not-working lesson is escalated to the next one','seed','2026-10-16T00:00:00Z'),
  ('lessons.retention_days','730','BH-5808: age (days after merged_at) past which POST /api/lessons/retention counts a judged lessons row; rows are kept','seed','2026-10-16T00:00:00Z'),
  ('lessons.list_limit','100','BH-5808: lessons rows GET /api/lessons/digest returns in its list','seed','2026-10-16T00:00:00Z');
