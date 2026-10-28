-- ── BH-8731 (lifecycle 1/6): ticket_events, the per-ticket phase ledger ─────
-- One row per ACCEPTED phase move of a ticket. Append-only: the route
-- POST /api/lifecycle/transition (worker/jobs/src/routes/ticket-lifecycle.js)
-- writes the row and the build_queue phase columns in one batch, under the
-- same `phase IS <read value>` guard, so an event never exists without its
-- phase change. A rejected move (409) writes no row. from_phase is NULL for a
-- ticket's first move. The build_queue phase columns and their index are
-- ensureColumns ALTERs (src/lib/core.d/bh-8731-lifecycle.js), not text here.
-- Retention: rule ticket_events.age (src/routes/retention.d/bh-8731-ticket-events.js)
-- copies rows older than retention.ticket_events.days to the archive D1,
-- then deletes them. Never a bare delete.
CREATE TABLE IF NOT EXISTS ticket_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  from_phase TEXT,                       -- NULL = the ticket had no phase yet
  to_phase TEXT NOT NULL,
  actor TEXT NOT NULL,                   -- triage | pool | conductor | pr-records | resolver | board | lifecycle
  reason TEXT NOT NULL,                  -- at most 500 chars
  pr INTEGER,                            -- the PR number, when the move has one
  at TEXT NOT NULL                       -- ISO; equals build_queue.phase_at of the move
);
-- one index per query (BH-6730):
--   history:   WHERE project=?1 AND ticket_key=?2 ORDER BY id DESC LIMIT ?3
--                                                   -> idx_ticket_events_project_ticket_id
--   retention: WHERE at < ?1 ORDER BY at LIMIT ?2   -> idx_ticket_events_at
CREATE INDEX IF NOT EXISTS idx_ticket_events_project_ticket_id ON ticket_events(project, ticket_key, id);
CREATE INDEX IF NOT EXISTS idx_ticket_events_at ON ticket_events(at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lifecycle.stuck.plan_blocked_min','1440','BH-8731: GET /api/lifecycle/stuck reports a plan_blocked ticket after this many minutes in the phase (whole number >= 0; 0 = at once; any other value = the code default 1440).','seed','2026-10-28T00:00:00Z'),
  ('lifecycle.stuck.ejected_min','30','BH-8731: minutes an ejected ticket may wait before /api/lifecycle/stuck reports it (code default 30).','seed','2026-10-28T00:00:00Z'),
  ('lifecycle.stuck.abandoned_min','0','BH-8731: minutes an abandoned ticket may wait before /api/lifecycle/stuck reports it; 0 = every abandoned ticket (code default 0).','seed','2026-10-28T00:00:00Z'),
  ('lifecycle.stuck.building_min','180','BH-8731: minutes a building ticket may run before /api/lifecycle/stuck reports it (code default 180).','seed','2026-10-28T00:00:00Z'),
  ('lifecycle.stuck.in_queue_min','120','BH-8731: minutes a ticket may sit in the merge queue before /api/lifecycle/stuck reports it (code default 120).','seed','2026-10-28T00:00:00Z'),
  ('lifecycle.stuck.pr_open_min','1440','BH-8731: minutes a ticket may sit with an open PR before /api/lifecycle/stuck reports it (code default 1440).','seed','2026-10-28T00:00:00Z'),
  ('lifecycle.stuck.limit','200','BH-8731: rows per phase one GET /api/lifecycle/stuck returns, oldest first; more sets truncated.<phase> (whole number >= 1; code default 200).','seed','2026-10-28T00:00:00Z'),
  ('lifecycle.history.limit','200','BH-8731: events one GET /api/lifecycle/history returns, newest first; more sets truncated (whole number >= 1; code default 200).','seed','2026-10-28T00:00:00Z'),
  ('retention.ticket_events.days','180','BH-8731: ticket_events rows older than this are copied to the archive D1, then deleted (rule ticket_events.age). Never a bare delete.','seed','2026-10-28T00:00:00Z');
