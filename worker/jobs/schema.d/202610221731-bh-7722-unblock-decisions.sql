-- ── BH-7722 (UNB-0): unblock_decisions, the Tackler decision ledger ─────────
-- One row per decision the unblock lane (bin/unblock.sh tick) makes. The row
-- is CLAIMED before any model call or write (claim before spend, G10): the
-- UNIQUE decision_key is the one dedup store, so a second tick on the same
-- stall stops at the claim. Spec: docs/plan/PR_UNBLOCK_AGENT_PLAN_2026-10-20.html
-- "The decision ledger". Routes: worker/jobs/src/routes/unblock-decisions.js
-- (claim, record, list, answer) and unblock-metrics.js (BH-7728, the reads).
-- answer_command_id is the one column added to the spec DDL: the command id of
-- the answer, so a re-delivered Telegram reply counts once (#7762).
-- Retention: rule unblock_decisions.age (routes/retention.js) archives
-- terminal rows older than retention.unblock_decisions.days. Never a bare delete.
-- Note: docs/notes/2026-10-22-BH-7722-unblock-contract.md.
CREATE TABLE IF NOT EXISTS unblock_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  decision_key TEXT NOT NULL UNIQUE,     -- sha256(key fields + rule id)
  agent TEXT NOT NULL DEFAULT 'tackler',
  project TEXT NOT NULL,
  repo TEXT,                             -- owner/name
  subject_kind TEXT NOT NULL CHECK (subject_kind IN
    ('pr','batch','build','box','lane','setting')),
  subject TEXT NOT NULL,                 -- example-org/cromford#7617, box:project-6-os
  head TEXT,                             -- sha the decision binds to
  stall_class TEXT NOT NULL,             -- the collector's kind
  rule_id TEXT,                          -- NULL only for U12
  rule_cites TEXT NOT NULL,              -- "G1,G12"
  evidence TEXT NOT NULL,                -- JSON, redacted, at most 8 KB
  decision TEXT NOT NULL CHECK (decision IN ('act','escalate','refuse','digest')),
  action TEXT,                           -- requeue, post_block, setting_set ...
  action_args TEXT,                      -- JSON, redacted
  mode TEXT NOT NULL CHECK (mode IN ('shadow','act')),
  outcome TEXT NOT NULL DEFAULT 'claimed' CHECK (outcome IN
    ('claimed','would','done','failed','refused','no-route',
     'escalated','answered','expired')),
  outcome_detail TEXT,
  card TEXT,                             -- JSON: what, options, recommendation, default, deadline_at
  answer TEXT, answered_by TEXT, answered_at TEXT,
  model_calls INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL NOT NULL DEFAULT 0,
  override_by TEXT, override_at TEXT, override_detail TEXT,
  created_at TEXT NOT NULL, acted_at TEXT, resolved_at TEXT,
  answer_command_id TEXT                 -- the answer's command id (dedup)
);
-- one index per query (BH-6730):
--   claim, record:  decision_key = ?1                   -> the UNIQUE autoindex
--   answer:         id = ?1                             -> the rowid
--   per subject:    WHERE subject=?1 ORDER BY id DESC   -> idx_unblock_decisions_subject_id
--   console, list:  WHERE project=?1 ORDER BY id DESC   -> idx_unblock_decisions_project_id
--   cards, outcome: WHERE outcome=?1 [AND project=?2]   -> idx_unblock_decisions_outcome_project
--   metrics, retention: WHERE created_at < ?1 ORDER BY created_at
--                                                       -> idx_unblock_decisions_created
CREATE INDEX IF NOT EXISTS idx_unblock_decisions_subject_id ON unblock_decisions(subject, id);
CREATE INDEX IF NOT EXISTS idx_unblock_decisions_project_id ON unblock_decisions(project, id);
CREATE INDEX IF NOT EXISTS idx_unblock_decisions_outcome_project ON unblock_decisions(outcome, project, id);
CREATE INDEX IF NOT EXISTS idx_unblock_decisions_created ON unblock_decisions(created_at);
-- The knob allowlist row is #7762's (BH-7725) and the other projects' mode
-- and approval rows are #7796's (BH-7727): one writer per row.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.unblock_decisions.days','180','Tackler decisions are history of record: archived to the archive store after this many days, never deleted (BH-6774 pattern).','seed','2026-10-21T00:00:00Z'),
  ('unblock.enabled','1','Master switch for the unblock lane. 0 exits the tick before any read.','seed','2026-10-21T00:00:00Z'),
  ('unblock.project.cromford.mode','shadow','off | shadow | act. Shadow logs WOULD_ rows. Act is the flip the operator makes after the replay.','seed','2026-10-21T00:00:00Z'),
  ('unblock.standing_approval.cromford','1','the operator standing approval 2026-10-18 (G1). Extend per project with a new row.','seed','2026-10-21T00:00:00Z');
-- Tackler on the staff roster: observe mode (automation), capped at autonomy.
INSERT OR IGNORE INTO staff_agents (name, role, accountable, autonomy, cap, status, soul_path, updated_at, note) VALUES
  ('tackler','unblock','operator@example.com','automation','autonomy','active','prompts/staff/tackler-soul.md','2026-10-21T00:00:00Z','BH-7722 seed: observe mode');
INSERT OR IGNORE INTO staff_lanes (agent, lane, created_at) VALUES
  ('tackler','unblock','2026-10-21T00:00:00Z');
-- The classes Tackler's actions count against. infra-restart is delegated
-- from day one (the operator, comment 6294289621 item 2). The never-auto seven are
-- never_delegable: the table CHECK keeps them ask_first.
INSERT OR IGNORE INTO staff_classes (agent, class, cap, never_delegable, state, delegated_at, updated_at, note) VALUES
  ('tackler','queue-requeue','autonomy',0,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed'),
  ('tackler','queue-approve','autonomy',0,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed'),
  ('tackler','review-block','autonomy',0,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed'),
  ('tackler','review-route','autonomy',0,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed'),
  ('tackler','review-rerequest','autonomy',0,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed'),
  ('tackler','fix-round','autonomy',0,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed'),
  ('tackler','infra-knob','autonomy',0,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed'),
  ('tackler','infra-restart','autonomy',0,'delegated','2026-10-21T00:00:00Z','2026-10-21T00:00:00Z','BH-7722 seed: delegated from day one (the operator, comment 6294289621 item 2); inert in shadow mode'),
  ('tackler','spend','autonomy',1,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed: never-auto'),
  ('tackler','production','autonomy',1,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed: never-auto'),
  ('tackler','live-probe','autonomy',1,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed: never-auto'),
  ('tackler','client-board','autonomy',1,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed: never-auto'),
  ('tackler','merge','autonomy',1,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed: never-auto'),
  ('tackler','deploy','autonomy',1,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed: never-auto'),
  ('tackler','governance','autonomy',1,'ask_first',NULL,'2026-10-21T00:00:00Z','BH-7722 seed: never-auto');
-- unblock.judge (bounded judgments): copied from stage.execute rung 0 on the
-- claude runner, as stage.archie is, so no model literal enters. stage.unblock
-- (the U12 card) is BH-7725's row (202610211200-bh-7725-unblock-route.sql): one
-- writer per row. An operator's route or change history is never overwritten.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'unblock.judge', 0, m.model, m.runner, 'seed', '2026-10-21T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'unblock.judge')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'unblock.judge');
