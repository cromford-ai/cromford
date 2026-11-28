-- ── BH-9554 (custody C0): ticket_custody and custody_actions ───────────────
-- ticket_custody: ONE row per (project, ticket). It names the lane that owns
-- the ticket now, the lease that ownership ends at, the next action and its
-- deadline. The only writers are the /api/custody/* routes
-- (worker/jobs/src/routes/custody.js); docs/CUSTODY.md is the contract.
--   state       a LIFECYCLE_PHASES word (src/lib/lifecycle.js); merged and
--               closed only through POST /api/custody/settle
--   owner_lane  a lane id, or 'custodian' when a lane released the ticket
--   due_at      the earlier of deadline_at and lease_expires_at; every write
--               sets it, so the custodian's due read is one index range
--   rev         +1 on every write; every write is a compare-and-set on it
--   settled_at  NOT NULL = the ticket merged or closed; out of every open read
-- custody_actions: append-only. One row per accepted custody write (who did
-- what, why, and the result), written in the same D1 batch as the change and
-- under the same rev guard, so an action row never exists without its change.
-- A refused write (400, 404, 409) writes no row in either table.
-- Retention (src/routes/retention.d/bh-9554-custody.js):
--   ticket_custody.settled  deletes rows settled more than
--                           retention.ticket_custody.settled_days ago (state
--                           rows; custody_actions keeps the history)
--   custody_actions.age     copies rows older than retention.custody_actions.days
--                           to the archive D1, then deletes them. Never a bare delete.
CREATE TABLE IF NOT EXISTS ticket_custody (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  ticket TEXT NOT NULL,
  state TEXT NOT NULL,                   -- a LIFECYCLE_PHASES word
  owner_lane TEXT,                       -- a lane id, or 'custodian' when released; NULL only when settled
  lease_expires_at TEXT,                 -- ISO; NULL = no lease
  next_action TEXT,                      -- reoffer | requeue_build | resolver | retriage | return_todo | wait
  deadline_at TEXT,                      -- ISO
  due_at TEXT,                           -- MIN(deadline_at, lease_expires_at)
  attempt INTEGER NOT NULL DEFAULT 0,
  ladder_rung INTEGER NOT NULL DEFAULT 0,
  last_evidence TEXT,                    -- at most 500 chars
  pr_number INTEGER,
  rev INTEGER NOT NULL DEFAULT 0,
  settled_at TEXT,                       -- ISO; NOT NULL = settled (merged or closed)
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project, ticket)
);
CREATE TABLE IF NOT EXISTS custody_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  ticket TEXT NOT NULL,
  actor TEXT NOT NULL,                   -- the lane, or the custodian
  action TEXT NOT NULL,                  -- claim | renew | release | next | settle, or the custodian's action word
  why TEXT NOT NULL,                     -- at most 500 chars
  result TEXT NOT NULL,                  -- at most 500 chars
  state TEXT,                            -- the row's state after the write
  attempt INTEGER,                       -- the row's attempt after the write
  ladder_rung INTEGER,                   -- the row's ladder_rung after the write
  at TEXT NOT NULL                       -- ISO; equals ticket_custody.updated_at of the write
);
-- one index per query (BH-6730):
--   every write and GET /api/custody/row: WHERE project=?1 AND ticket=?2
--                                -> sqlite_autoindex_ticket_custody_1 (the UNIQUE)
--   due:   WHERE settled_at IS NULL AND due_at < ?1 ORDER BY due_at LIMIT ?2
--                                -> idx_ticket_custody_due
--   gaps:  WHERE settled_at IS NULL AND owner_lane IS NULL   -> idx_ticket_custody_open_owner
--          WHERE settled_at IS NULL AND deadline_at IS NULL  -> idx_ticket_custody_open_deadline
--   retention: WHERE settled_at < ?1 ORDER BY settled_at LIMIT ?2
--                                -> idx_ticket_custody_settled
--   action history: WHERE project=?1 AND ticket=?2 ORDER BY id DESC
--                                -> idx_custody_actions_ticket
--   action retention: WHERE at < ?1 ORDER BY at LIMIT ?2      -> idx_custody_actions_at
CREATE INDEX IF NOT EXISTS idx_ticket_custody_due ON ticket_custody(due_at) WHERE settled_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_ticket_custody_open_owner ON ticket_custody(owner_lane) WHERE settled_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_ticket_custody_open_deadline ON ticket_custody(deadline_at) WHERE settled_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_ticket_custody_settled ON ticket_custody(settled_at) WHERE settled_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_custody_actions_ticket ON custody_actions(project, ticket, id);
CREATE INDEX IF NOT EXISTS idx_custody_actions_at ON custody_actions(at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('custody.lease_s','1800','BH-9554: lease length in seconds when a custody claim or renew names none (whole number >= 1; any other value = the code default 1800).','seed','2026-11-12T00:00:00Z'),
  ('custody.lease_max_s','86400','BH-9554: the longest lease a custody claim or renew may ask for; a longer one is a 400, never clamped (code default 86400).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline.triaged_min','120','BH-9554: default next-action deadline in minutes for a ticket in state triaged (code default 120).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline.planned_min','120','BH-9554: default next-action deadline in minutes for a ticket in state planned (code default 120).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline.plan_blocked_min','1440','BH-9554: default next-action deadline in minutes for a ticket in state plan_blocked (code default 1440).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline.building_min','180','BH-9554: default next-action deadline in minutes for a ticket in state building (code default 180).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline.pr_open_min','1440','BH-9554: default next-action deadline in minutes for a ticket in state pr_open (code default 1440).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline.in_queue_min','120','BH-9554: default next-action deadline in minutes for a ticket in state in_queue (code default 120).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline.ejected_min','30','BH-9554: default next-action deadline in minutes for a ticket in state ejected (code default 30).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline.abandoned_min','60','BH-9554: default next-action deadline in minutes for a ticket in state abandoned (code default 60).','seed','2026-11-12T00:00:00Z'),
  ('custody.deadline_max_min','43200','BH-9554: a custody deadline more than this many minutes after now is a 400, never clamped (code default 43200 = 30 days).','seed','2026-11-12T00:00:00Z'),
  ('custody.due.limit','200','BH-9554: rows one GET /api/custody/due returns, oldest due first; more sets truncated (whole number >= 1; code default 200).','seed','2026-11-12T00:00:00Z'),
  ('retention.ticket_custody.settled_days','7','BH-9554: ticket_custody rows settled more than this many days ago are deleted (rule ticket_custody.settled); custody_actions keeps the history.','seed','2026-11-12T00:00:00Z'),
  ('retention.custody_actions.days','90','BH-9554: custody_actions rows older than this are copied to the archive D1, then deleted (rule custody_actions.age). Never a bare delete.','seed','2026-11-12T00:00:00Z');
