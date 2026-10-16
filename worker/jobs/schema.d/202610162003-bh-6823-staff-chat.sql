-- ── BH-6823: one chat thread per staff agent ────────────────────────────────
-- staff_chat holds the operator notes sent to a staff agent and the agent's
-- replies (src/routes/staff-chat.js). A note is role 'operator'; a reply is
-- role 'agent', state 'sent', and names the note it answers (reply_to) and the
-- bin/staff.sh tick that wrote it (tick_key, staff_ticks.tick_key).
--
-- A note's lifecycle is its state:
--   pending     sent, waiting for the agent's next tick
--   held        sent while the agent was stopped (a staff-kill-*/staff-off-*
--               pause_flags row, or staff_agents.status not active); kept, and
--               taken on the first tick after the agent resumes
--   taken       claimed by the tick named in tick_key (a lease on updated_at,
--               settings row staff.chat.take_lease_s)
--   read        answered: the same batch wrote its reply row
--   unanswered  the tick's model call ran and gave no reply for it (terminal)
--   failed      taken staff.chat.attempts_max times with no settle (terminal)
-- Steer notes (steer_notes) are not reused: their CHECKs have no 'held' state
-- and no staff mode, and a CHECK cannot change without a DROP.
--
-- INDEXES, one per query (src/routes/staff-chat.js, retention.js):
--   idx_staff_chat_agent_id      the thread page: agent=? AND id<? ORDER BY id
--                                DESC LIMIT ?
--   idx_staff_chat_agent_state   the take's fail sweep and claim: agent=? AND
--                                state IN (...) ORDER BY id
--   idx_staff_chat_reply_to      one reply per note (UNIQUE), and the
--                                retention child delete reply_to IN (...)
--   idx_staff_chat_role_created  the retention id read: role='operator' AND
--                                created_at<? ORDER BY created_at
-- The GET's tick link joins staff_ticks on its UNIQUE tick_key.
--
-- RETENTION (BH-6750 job, src/routes/retention.js, rule staff_chat.age): a
-- read, unanswered or failed note goes with its reply after
-- retention.staff_chat.days (365). A pending, held or taken note never goes.
-- retention.dry_run (seed 1) applies. The exemption is deliberate: an open
-- note is operator work not yet answered. A note to an agent that stays
-- stopped or retired stays `held` for good; one row per operator send caps the
-- growth. If that ever matters, add a held-note age cut with its own settings
-- row (lead review of #7155, finding 4).
--
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS staff_chat (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('operator','agent')),
  text TEXT NOT NULL,
  actor TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending','held','taken','read','unanswered','failed','sent')),
  reply_to INTEGER,
  tick_key TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  stopped_by TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK ((role = 'agent') = (reply_to IS NOT NULL)),
  CHECK (role = 'operator' OR state = 'sent')
);
CREATE INDEX IF NOT EXISTS idx_staff_chat_agent_id ON staff_chat(agent, id);
CREATE INDEX IF NOT EXISTS idx_staff_chat_agent_state ON staff_chat(agent, state, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_chat_reply_to ON staff_chat(reply_to) WHERE reply_to IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_staff_chat_role_created ON staff_chat(role, created_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.chat.attempts_max','2','BH-6823: takes of one operator note (1..10) before it is failed with no further model call.','seed','2026-10-15T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.chat.take_lease_s','1200','BH-6823: seconds a taken operator note stays with its tick (60..86400) before another tick may take it. Above the 600 s tick timeout.','seed','2026-10-15T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.staff_chat.days','365','BH-6823: days a closed staff chat note (read, unanswered, failed) and its reply are kept (0 = off). Open notes never go.','seed','2026-10-15T00:00:00Z');
