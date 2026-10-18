-- BH-6979 (BH-6547.3): the scheduler's ready set, one row per candidate per
-- tick. Writer: POST /api/scheduler/diffs (`verdicts`, in the same D1 batch as
-- its sched_ticks row). Reader: GET /api/scheduler/ready, which reads only the
-- newest tick of a project. Routes: worker/jobs/src/routes/scheduler.js.
-- Gate: bin/lib/sched-gate.sh. Contract:
-- docs/notes/2026-10-17-BH-6979-scheduler-enforce.md. Additive only.
--
-- ready: yes | no | unknown | in-flight. reason is empty only on yes.
-- `at` equals sched_ticks.at; a set is complete when its row count equals
-- sched_ticks.candidates.
--
-- Index per query:
--   insert ON CONFLICT(project,at,ticket) DO NOTHING          ux_sched_ready_pat
--   ready read WHERE project=? AND at=? (the newest tick)     ux_sched_ready_pat
--   retention WHERE at < ? ORDER BY at LIMIT ?                idx_sched_ready_at
--
-- Retention: rule sched_ready.age in worker/jobs/src/routes/retention.js,
-- window retention.sched_ready.days (3). Only the newest tick is ever read;
-- 3 days is a debug window, about 35k rows at 40 candidates. Decision rows,
-- not money or history: deleted.
CREATE TABLE IF NOT EXISTS sched_ready (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  at TEXT NOT NULL,
  ticket TEXT NOT NULL,
  ready TEXT NOT NULL CHECK (ready IN ('yes','no','unknown','in-flight')),
  reason TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_sched_ready_pat ON sched_ready (project, at, ticket);
CREATE INDEX IF NOT EXISTS idx_sched_ready_at ON sched_ready (at);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('scheduler.ready_max_age_s','900','BH-6979: in scheduler.mode=enforce, a ready set older than this many seconds is stale and dispatch falls back to sibling-serial/overlap-schedule/stack-wait; the code default is 900','seed','2026-10-17T00:00:00Z'),
  ('scheduler.sibling_checks_max','20','BH-6979: bin/sibling-serial.sh check calls per scheduler tick in enforce; a part past it is unknown (sibling check cap); the code default is 20','seed','2026-10-17T00:00:00Z'),
  ('retention.sched_ready.days','3','BH-6979: days a sched_ready row is kept after its tick (0 = off)','seed','2026-10-17T00:00:00Z');
