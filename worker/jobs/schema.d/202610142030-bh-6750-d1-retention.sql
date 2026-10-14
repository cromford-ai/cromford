-- BH-6750 (slice 2 of BH-6727): scheduled D1 retention. POST /api/retention/run
-- (worker/jobs/src/routes/retention.js), called every hour by the hub lane
-- bin/d1-retention.sh, removes rows that have no further value, in bounded
-- batches, and writes one audit row per rule per run. Rules:
--   wakes.age             any wake older than retention.wakes.days (30)
--   wakes.acked           a wake acked more than retention.wakes.acked_days (3) ago
--   job_heartbeats.closed the beat of a job that is not running (or has no jobs
--                         row), older than retention.job_heartbeats.days (30)
--   stage_events.closed   events of a job that is not running, older than
--                         retention.stage_events.days (90), summed into
--                         stage_events_daily first, in the same D1 batch
--   lane_ticks.stale      a (lane, project, box) whose last tick is older than
--                         retention.lane_ticks.days (30): a retired lane or box
--   retention_runs.age    this table's own rows, older than retention.retention_runs.days (90)
-- cost_rows and ledgers carry money and history and are never deleted here.
-- retention.dry_run=1 (the seed) counts and audits, and removes nothing.

-- One row per rule per run: what the run counted, removed and left.
CREATE TABLE IF NOT EXISTS retention_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,           -- one id per POST /api/retention/run
  rule TEXT NOT NULL,             -- e.g. wakes.age
  tbl TEXT NOT NULL,              -- the table the rule removes from
  dry_run INTEGER NOT NULL,       -- 1 = counted only
  cutoff TEXT,                    -- ISO; rows older than this were eligible
  counted INTEGER NOT NULL,       -- eligible rows seen (capped at retention.count_cap)
  removed INTEGER NOT NULL,       -- rows deleted this run (0 on a dry run)
  rolled_up INTEGER NOT NULL DEFAULT 0, -- rows summed into a daily table before the delete
  backlog INTEGER NOT NULL,       -- 1 = eligible rows remain after this run's budget
  error TEXT,                     -- the D1 error that stopped this rule, if any
  started_at TEXT NOT NULL,
  finished_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_retention_runs_rule ON retention_runs(rule, started_at);
CREATE INDEX IF NOT EXISTS idx_retention_runs_started ON retention_runs(started_at);

-- The daily counts of stage_events rows that retention removed. One row per
-- day x stage x verdict x actor; a later batch for the same key adds to n.
CREATE TABLE IF NOT EXISTS stage_events_daily (
  day TEXT NOT NULL,              -- YYYY-MM-DD of created_at
  stage TEXT NOT NULL,
  verdict TEXT NOT NULL,          -- '' for a NULL verdict
  actor TEXT NOT NULL,
  n INTEGER NOT NULL,
  PRIMARY KEY (day, stage, verdict, actor)
);

-- The cutoff reads. stage_events had (job_id) and (stage, created_at) only;
-- lane_ticks had (lane, last_tick_at) only. Each rule reads oldest first
-- through one of these, never a full scan.
CREATE INDEX IF NOT EXISTS idx_events_created ON stage_events(created_at);
CREATE INDEX IF NOT EXISTS idx_lane_ticks_tick ON lane_ticks(last_tick_at);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.dry_run','1','BH-6750: 1 = POST /api/retention/run counts the eligible rows and writes retention_runs, and deletes nothing; 0 = it deletes. Flip to 0 after reading a dry run.','seed','2026-10-14T00:00:00Z'),
  ('retention.batch','500','BH-6750: rows per DELETE statement (1..2000)','seed','2026-10-14T00:00:00Z'),
  ('retention.max_rows','5000','BH-6750: rows one run may remove per rule (1..100000); a larger backlog drains over the next hourly runs','seed','2026-10-14T00:00:00Z'),
  ('retention.count_cap','250000','BH-6750: the dry-run count stops at this many eligible rows per rule (1..1000000)','seed','2026-10-14T00:00:00Z'),
  ('retention.wakes.days','30','BH-6750: days a wake is kept at all (0 = off). Webhook delivery signals, consumed within minutes.','seed','2026-10-14T00:00:00Z'),
  ('retention.wakes.acked_days','3','BH-6750: days an ACKED wake is kept (0 = off). Other boxes may still read it above their cursor for a while.','seed','2026-10-14T00:00:00Z'),
  ('retention.job_heartbeats.days','30','BH-6750: days the beat of a job that is not running is kept (0 = off)','seed','2026-10-14T00:00:00Z'),
  ('retention.stage_events.days','90','BH-6750: days the events of a job that is not running are kept, before they are summed into stage_events_daily and removed (0 = off)','seed','2026-10-14T00:00:00Z'),
  ('retention.lane_ticks.days','30','BH-6750: days a (lane, project, box) with no tick is kept (0 = off)','seed','2026-10-14T00:00:00Z'),
  ('retention.retention_runs.days','90','BH-6750: days the retention audit rows are kept (0 = off)','seed','2026-10-14T00:00:00Z');
