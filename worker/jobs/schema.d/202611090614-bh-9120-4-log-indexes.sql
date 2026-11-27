-- BH-9308 (BH-9120.4): the indexes of the lane-runs log range, and the CONSOLE_DB apply knob.
--
-- GET /api/lane-runs?from=&to= (routes/lane-runs-metrics.js) reads
-- `enqueued_at >= ? AND enqueued_at < ?`, ORDER BY enqueued_at DESC, id DESC
-- by default, keyset-paged on (enqueued_at, id). Its totals and series reads
-- use the same WHERE.
--   idx_lane_runs_enqueued          the range with no project filter: the
--                                   WHERE, the default ORDER BY and the keyset.
--   idx_lane_runs_project_enqueued  the range with project=?: the same, inside
--                                   one project.
-- EXPLAIN QUERY PLAN at 200,000 lane_runs (60 days, 13 projects, 40 lanes), a
-- 30-day range (worker/jobs/test/log-period.bh-9120-4.test.js LE1):
--   page:                 SEARCH lane_runs USING INDEX idx_lane_runs_enqueued (enqueued_at>? AND enqueued_at<?)
--   page + project:       SEARCH lane_runs USING INDEX idx_lane_runs_project_enqueued (project=? AND enqueued_at>? AND enqueued_at<?)
--   totals:               SEARCH lane_runs USING INDEX idx_lane_runs_enqueued (enqueued_at>? AND enqueued_at<?)
--   totals + project:     SEARCH lane_runs USING INDEX idx_lane_runs_project_enqueued (project=? AND enqueued_at>? AND enqueued_at<?)
-- No new table, so no RLS and no retention rule apply here (lane_runs keeps
-- the retention.lane_runs.days rule of BH-9076).
CREATE INDEX IF NOT EXISTS idx_lane_runs_enqueued ON lane_runs(enqueued_at, id);
CREATE INDEX IF NOT EXISTS idx_lane_runs_project_enqueued ON lane_runs(project, enqueued_at, id);
-- The seconds bin/console-db-schema.sh waits per D1 statement when it applies
-- console-ui/schema.d/ to harness-console-db. INSERT OR IGNORE keeps an
-- operator's value on a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('console_db.schema_apply_timeout_s','30','BH-9308: seconds bin/console-db-schema.sh waits per D1 statement on harness-console-db (1..300); the code fallback is 30','seed','2026-11-26T00:00:00Z');
-- The log screens' row caps (lead BLOCK hardcoded-knob on BH-9308). Read by
-- readPeriodKnobs (src/lib/period.js) and served by GET /api/period/knobs;
-- PERIOD_FALLBACKS holds the same values, so a deleted row changes nothing.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('mc.period.report_top_rows','20','BH-9308: the newest rows a log screen''s period report lists (JOBS, LANES, HISTORY, COMMAND LOG), sent as limit (1..200). Fallback 20.','seed','2026-11-27T00:00:00Z'),
  ('mc.period.filter_chip_cap','30','BH-9308: the most LANE / PROJECT filter chips a log screen draws (1..500). Fallback 30.','seed','2026-11-27T00:00:00Z');
