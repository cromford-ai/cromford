-- BH-6977 (BH-6547.1): ticket dependency edges and HOLD/RESUME comments as
-- rows. Routes: worker/jobs/src/routes/ticket-edges.js. Writers:
-- bin/lib/ticket-edges.sh (bin/run-preplan.sh, bin/run-decompose.sh,
-- bin/dep-verify.sh, bin/lib/wake-class-ticket-holds.sh). Contract:
-- docs/notes/2026-10-15-BH-6977-ticket-edges.md. Additive only.
--
-- ticket_edges: one row per (project, parent, child). parent is the blocker's
-- issue number, child the blocked ticket's. kind and source are the last
-- writer's, except that a planner or decompose write never changes the kind
-- of a row dep-verify has verified.
--
-- Index per query:
--   upsert ON CONFLICT(project,parent,child)          ux_ticket_edges_pc
--   GET WHERE project=? AND parent=?                   ux_ticket_edges_pc (prefix)
--   GET WHERE project=? AND child=?                    idx_ticket_edges_child
--   GET WHERE project=? ORDER BY id                    ux_ticket_edges_pc (prefix)
--   retention WHERE at < ? ORDER BY at LIMIT ?         idx_ticket_edges_at
--
-- Retention: rule ticket_edges.age in worker/jobs/src/routes/retention.js.
-- An edge's `at` moves on every write, so a row untouched for
-- retention.ticket_edges.days (365) belongs to a ticket nobody planned in that
-- time. Coordination rows, not money or history: deleted.
CREATE TABLE IF NOT EXISTS ticket_edges (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  parent TEXT NOT NULL,
  child TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('hard','soft')),
  planned_files TEXT,
  source TEXT NOT NULL CHECK (source IN ('planner','decompose','dep-verify','human')),
  verified_at TEXT,
  at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ticket_edges_pc ON ticket_edges (project, parent, child);
CREATE INDEX IF NOT EXISTS idx_ticket_edges_child ON ticket_edges (project, child);
CREATE INDEX IF NOT EXISTS idx_ticket_edges_at ON ticket_edges (at);

-- ticket_holds: one row per HOLD or RESUME comment by a person, keyed on the
-- GitHub comment id. An edited comment changes its own row. `at` is the
-- comment's created_at.
--
-- Index per query:
--   insert ON CONFLICT(project,ticket,comment_id)                  ux_ticket_holds_comment
--   GET WHERE project=? AND ticket=? ORDER BY at DESC LIMIT ?      idx_ticket_holds_ticket_at
--   retention WHERE at < ? ORDER BY at LIMIT ?                     idx_ticket_holds_at
--
-- Retention: rule ticket_holds.age, window retention.ticket_holds.days (365).
CREATE TABLE IF NOT EXISTS ticket_holds (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  ticket TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('hold','resume')),
  by TEXT NOT NULL,
  at TEXT NOT NULL,
  comment_id TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ticket_holds_comment ON ticket_holds (project, ticket, comment_id);
CREATE INDEX IF NOT EXISTS idx_ticket_holds_ticket_at ON ticket_holds (project, ticket, at);
CREATE INDEX IF NOT EXISTS idx_ticket_holds_at ON ticket_holds (at);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.ticket_edges.days','365','BH-6977: days a ticket_edges row is kept after its last write (0 = off)','seed','2026-10-15T00:00:00Z'),
  ('retention.ticket_holds.days','365','BH-6977: days a ticket_holds row is kept after its comment was written (0 = off)','seed','2026-10-15T00:00:00Z'),
  ('ticket_holds.wake_reads_max','20','BH-6977: issue threads the ticket-holds wake class reads per wake drain (0 = the class does nothing); the code default is 20','seed','2026-10-15T00:00:00Z');
