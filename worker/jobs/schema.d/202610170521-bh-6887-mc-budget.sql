-- BH-6887 (BH-6881.3): the merge conductor's daily budget counters. One row
-- per (project, UTC day, kind): how many units of that kind the project spent
-- that day. The first kind is `rereview`, the operator-set daily re-review cap
-- (MC_REREVIEW_DAILY_CAP). Routes: worker/jobs/src/routes/mc-budget.js.
-- Contract: docs/notes/2026-10-17-BH-6887-mc-lease-budget.md. Additive only.
--
-- Retention: rows older than retention.mc_budget.days (seed 30) are deleted
-- hourly by the mc_budget.age rule (the d1-retention lane calls POST
-- /api/retention/run). A counter is not money or history, so it is deleted,
-- not archived. A past day's row has no reader: the cap reads today's row only.
CREATE TABLE IF NOT EXISTS mc_budget (
  project TEXT NOT NULL,
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  spent INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (project, day, kind)
);
-- no-index: mc_budget the seed, the spend and the give are WHERE project=? AND day=? AND kind=?, served by the PRIMARY KEY (tests/mc-budget.bh-6887-test.sh case B5); the hourly retention read scans at most projects x 31 days x kinds rows (about 500)
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.mc_budget.days','30','BH-6887: days a merge-conductor daily budget counter row is kept (0 = off)','seed','2026-10-17T00:00:00Z');
