-- ── BH-9047 (C0): the disprove pass on a lead review BLOCK ─────────────────
-- bin/lib/review-disprove.sh (called by bin/lead-review.sh after the review
-- level cap) makes ONE bounded model call per BLOCK finding on route
-- review-disprove: "prove this finding wrong from the code, or confirm it with
-- the exact line". shadow records and changes nothing; enforce turns a
-- DISPROVED finding (not a protected class) into a [NOTE] disproved: line.
--   review.disprove.<project>.enabled  exactly 1 = on. The code fallback for
--                            no row, an unreadable row or any other value is 0.
--                            Seeded 1 for cromford only.
--   review.disprove.mode     shadow | enforce, trimmed and lowercased. Any
--                            other value, or no row, is shadow.
--   review.disprove.max_findings       findings checked per review, 1..20; fallback 5.
--   review.disprove.usd_cap_day        the pass's spend per UTC day (stage
--                            disprove), > 0 and <= 50; fallback 2.
--   review.disprove.call_budget_usd    the budget of one call, > 0 and <= 5; fallback 0.50.
--   review.disprove.max_context_bytes  the hunk and the file excerpt are cut
--                            together at this many bytes, 2000..200000; fallback 24000.
--   review.disprove.min_left_s         seconds the review must have left before
--                            each call, 30..3600; fallback 120.
--   review.disprove.list_limit / list_max  GET /api/review-disprove default
--                            and largest limit; fallback 100 and 500.
-- D1 is SQLite, not Supabase: RLS does not apply. INSERT OR IGNORE seeds only,
-- so a re-apply through bin/harness-sync.sh is a no-op and an operator's value
-- is kept.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review.disprove.cromford.enabled','1','BH-9047: 1 = run the disprove pass on a cromford lead review BLOCK. Any other value, or no row for a project, is off (code fallback 0)','seed','2026-11-04T00:00:00Z'),
  ('review.disprove.mode','shadow','BH-9047: shadow | enforce. shadow = run the disprove pass, record the outcome, do not change the verdict; enforce = a DISPROVED finding that is not a protected class becomes a [NOTE] disproved: line. Any other value is shadow (code fallback shadow)','seed','2026-11-04T00:00:00Z'),
  ('review.disprove.max_findings','5','BH-9047: at most this many BLOCK findings get a disprove call per review; the rest count as confirmed (1..20; code fallback 5)','seed','2026-11-04T00:00:00Z'),
  ('review.disprove.usd_cap_day','2','BH-9047: the disprove pass spends at most this many USD per UTC day (stage disprove); a call that would pass it is not made and the finding counts as confirmed (> 0, <= 50; code fallback 2)','seed','2026-11-04T00:00:00Z'),
  ('review.disprove.call_budget_usd','0.50','BH-9047: the budget of one disprove call, USD (> 0, <= 5; code fallback 0.50)','seed','2026-11-04T00:00:00Z'),
  ('review.disprove.max_context_bytes','24000','BH-9047: the diff hunk and the file excerpt in one disprove prompt are cut together at this many bytes (2000..200000; code fallback 24000)','seed','2026-11-04T00:00:00Z'),
  ('review.disprove.min_left_s','120','BH-9047: a disprove call runs only when the lead review has at least this many seconds left (30..3600; code fallback 120)','seed','2026-11-04T00:00:00Z'),
  ('review.disprove.list_limit','100','BH-9047: GET /api/review-disprove answers this many rows when the caller sends no limit (1..review.disprove.list_max; code fallback 100)','seed','2026-11-04T00:00:00Z'),
  ('review.disprove.list_max','500','BH-9047: the largest limit GET /api/review-disprove accepts; a larger limit is 400 (1..5000; code fallback 500)','seed','2026-11-04T00:00:00Z'),
  ('retention.review_disprove_runs.days','90','BH-9047: review_disprove_runs rows older than this are deleted (rule review_disprove_runs.age). The rows are shadow measurement, not money or history (code fallback 90)','seed','2026-11-04T00:00:00Z');
-- review-disprove: the disprove call's route. One rung, a copy of lead.review
-- rung 0, so the check has the same strength as the reviewer it checks. No
-- model literal enters. The NOT EXISTS guards keep an operator's cut: a role
-- with a model_route_changes row is never put back.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'review-disprove', 0, l.model, l.runner, 'seed', '2026-11-04T00:00:00Z'
  FROM model_routes l
  WHERE l.project IS NULL AND l.role = 'lead.review' AND l.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'review-disprove')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'review-disprove');
-- stage.disprove: the BH-2536 rule (every agent-call stage has a rung-0 stage
-- route), copied from stage.execute rung 0 the way stage.break-it is. The call
-- walks review-disprove (AGENT_CALL_ROLE); this row names the stage.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.disprove', 0, m.model, m.runner, 'seed', '2026-11-04T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.disprove')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.disprove');
-- review_disprove_runs: one row per disprove pass (POST /api/review-disprove,
-- worker/jobs/src/routes/review-disprove.js). The natural key makes a retried
-- post a no-op. detail is a JSON array of at most 20 {cls, loc, outcome, reason}.
-- cost_usd is NULL when no call reported its cost (never 0 for unknown).
-- Retention: rule review_disprove_runs.age (src/routes/retention.d/bh-9047-review-disprove.js)
-- deletes rows older than retention.review_disprove_runs.days.
CREATE TABLE IF NOT EXISTS review_disprove_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL,
  review_id TEXT NOT NULL,               -- the lead review request id
  lane TEXT NOT NULL,                    -- lead | conductor
  project TEXT NOT NULL,
  mode TEXT NOT NULL,                    -- shadow | enforce
  verdict_before TEXT NOT NULL,
  verdict_after TEXT NOT NULL,
  findings INTEGER NOT NULL,
  checked INTEGER NOT NULL,
  confirmed INTEGER NOT NULL,
  disproved INTEGER NOT NULL,
  kept_protected INTEGER NOT NULL,
  unchecked INTEGER NOT NULL,
  cost_usd REAL,
  detail TEXT NOT NULL,
  actor TEXT NOT NULL,
  created_at TEXT NOT NULL
);
-- one index per query (BH-6730):
--   dedup:     INSERT OR IGNORE on (repo, pr, head_sha, review_id, lane)      -> idx_review_disprove_runs_key
--   lookup:    WHERE repo=?1 AND pr=?2 AND head_sha=?3 ORDER BY created_at    -> idx_review_disprove_runs_key (prefix)
--   since:     WHERE created_at >= ?1 ORDER BY created_at DESC LIMIT ?2       -> idx_review_disprove_runs_created
--   retention: WHERE created_at < ?1 ORDER BY created_at LIMIT ?2             -> idx_review_disprove_runs_created
CREATE UNIQUE INDEX IF NOT EXISTS idx_review_disprove_runs_key ON review_disprove_runs(repo, pr, head_sha, review_id, lane);
CREATE INDEX IF NOT EXISTS idx_review_disprove_runs_created ON review_disprove_runs(created_at);
