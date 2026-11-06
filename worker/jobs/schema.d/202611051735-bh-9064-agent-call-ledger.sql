-- ── BH-9064: agent_call_ledger ───────────────────────────────────────────────
-- The persisted dedup-before-spend ledger of bin/agent-call.sh
-- (bin/lib/agent-call-ledger.sh). One row per piece of work:
-- (project, guard stage, fingerprint). Before the model call the box asks
-- POST /api/agent-call-ledger/begin; the answer is run, replay (an `ok` answer
-- of a replay stage inside the window) or terminal (`empty`, `failed` at the
-- attempt cap, `running` inside its TTL, `parked`). After the call
-- POST /api/agent-call-ledger/finish settles the row with the stored rc and,
-- for `ok`, the answer body. An answer over the client's byte cap is stored
-- with no body and answer_bytes set, and never replays. answer_ref is the
-- answer reference column the ticket names; no C0 writer sets it.
-- status = running | ok | empty | failed | unbilled | parked | reset.
-- checkpoint is the execute checkpoint (<branch>@<sha>) that slice C1 writes.
-- note carries an operator reset reason.
-- Note: docs/notes/2026-11-05-BH-9064-agent-call-ledger.md.
--
-- INDEXES. Each query and the index that serves it:
--   begin / finish / GET / DELETE  WHERE project=? AND stage=? AND fp=?
--         the primary key (project, stage, fp).
--   retention id read  WHERE last_at < ?1 ORDER BY last_at
--         idx_agent_call_ledger_last (last_at).
--
-- RETENTION (rule agent_call_ledger.age, the hourly bin/d1-retention.sh lane).
-- A row is a dedup key whose value ends with the replay window (1 h) and the
-- K3 window (24 h). Rows older than retention.agent_call_ledger.days (7) are
-- deleted, not archived: the spend itself is in cost_rows.
-- retention.dry_run (seed 1) applies: the first runs only count.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS agent_call_ledger (
  project TEXT NOT NULL,
  stage TEXT NOT NULL,
  fp TEXT NOT NULL,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  rc INTEGER,
  runner TEXT,
  model TEXT,
  box TEXT,
  answer_ref TEXT,
  answer_body TEXT,
  answer_bytes INTEGER,
  checkpoint TEXT,
  note TEXT,
  first_at TEXT NOT NULL,
  last_at TEXT NOT NULL,
  PRIMARY KEY (project, stage, fp)
);
CREATE INDEX IF NOT EXISTS idx_agent_call_ledger_last ON agent_call_ledger(last_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.agent_call_ledger.days','7','BH-9064: days an agent_call_ledger row is kept (0 = off). The replay window is 1 h and the K3 window 24 h, so a week is diagnostic only.','seed','2026-11-05T17:35:00Z');
