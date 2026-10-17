-- BH-6978 (BH-6547.2): the scheduler computes the ready set in shadow and
-- compares it with what the lanes did in the same tick. Routes:
-- worker/jobs/src/routes/scheduler.js. Writer: bin/scheduler.sh (hub lane,
-- */5). Reader: GET /api/scheduler/agreement for the daily digest. Contract:
-- docs/notes/2026-10-16-BH-6978-scheduler-shadow.md. Additive only.
--
-- sched_ticks: one row per (project, tick). `at` is the lane's tick time.
-- compared/agreed/idle are the compare's counts; partial names the lane
-- inputs that failed (then compared=0).
--
-- Index per query:
--   insert ON CONFLICT(project,at) DO NOTHING                         ux_sched_ticks_pa
--   agreement WHERE at>=? AND at<? [AND project=?] GROUP BY project   idx_sched_ticks_at (INDEXED BY: unhinted, SQLite picks a skip-scan of ux_sched_ticks_pa)
--   retention WHERE at < ? ORDER BY at LIMIT ?                        idx_sched_ticks_at
--
-- Retention: rule sched_ticks.age in worker/jobs/src/routes/retention.js,
-- window retention.sched_ticks.days (30). 288 rows/day/project. Shadow
-- comparison rows, not money or history: deleted.
CREATE TABLE IF NOT EXISTS sched_ticks (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  at TEXT NOT NULL,
  mode TEXT NOT NULL,
  candidates INTEGER NOT NULL,
  ready INTEGER NOT NULL,
  not_ready INTEGER NOT NULL,
  unknown INTEGER NOT NULL,
  in_flight INTEGER NOT NULL,
  compared INTEGER NOT NULL,
  agreed INTEGER NOT NULL,
  idle INTEGER NOT NULL,
  partial TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_sched_ticks_pa ON sched_ticks (project, at);
CREATE INDEX IF NOT EXISTS idx_sched_ticks_at ON sched_ticks (at, project);

-- sched_diffs: one row per disagreeing ticket per tick. reason is the
-- scheduler's reason or the holding lane's own words; reason_class is what
-- the top-5 groups on (parent-open | hold | files-claimed | wip-cap |
-- lanes-held:<lane>). `at` equals sched_ticks.at.
--
-- Index per query:
--   insert ON CONFLICT(project,ticket,at) DO NOTHING                                 ux_sched_diffs_pta
--   agreement top WHERE at>=? AND at<? [AND project=?] GROUP BY project, reason_class idx_sched_diffs_at (INDEXED BY, covering)
--   retention WHERE at < ? ORDER BY at LIMIT ?                                       idx_sched_diffs_at
--
-- Retention: rule sched_diffs.age, window retention.sched_diffs.days (30).
-- Worst case 11,520 rows/day on 40 candidates, under 350k rows in the window.
CREATE TABLE IF NOT EXISTS sched_diffs (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  ticket TEXT NOT NULL,
  scheduler_says TEXT NOT NULL CHECK (scheduler_says IN ('ready','not-ready')),
  lanes_did TEXT NOT NULL,
  reason TEXT NOT NULL,
  reason_class TEXT NOT NULL,
  at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_sched_diffs_pta ON sched_diffs (project, ticket, at);
CREATE INDEX IF NOT EXISTS idx_sched_diffs_at ON sched_diffs (at, project, reason_class);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('scheduler.mode','shadow','BH-6978: scheduler lane mode, shadow or off; any other value runs shadow and logs that it is not built in this wave; the code default is shadow','seed','2026-10-16T00:00:00Z'),
  ('scheduler.projects','cromford','BH-6978: space-separated projects bin/scheduler.sh --all runs; the code default is cromford','seed','2026-10-16T00:00:00Z'),
  ('scheduler.parent_reads_max','20','BH-6978: parent PR/issue fallback reads per scheduler tick; the code default is 20','seed','2026-10-16T00:00:00Z'),
  ('retention.sched_diffs.days','30','BH-6978: days a sched_diffs row is kept after its tick (0 = off)','seed','2026-10-16T00:00:00Z'),
  ('retention.sched_ticks.days','30','BH-6978: days a sched_ticks row is kept after its tick (0 = off)','seed','2026-10-16T00:00:00Z');
