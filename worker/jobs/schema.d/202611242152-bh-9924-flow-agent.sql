-- ── BH-9924 (slice BH-9956): the flow agent's two tables and its knobs ──────
-- Writer and reader: worker/jobs/src/routes/flow-agent.js (the bearer-gated
-- family), called by bin/lib/jobs/flow-agent.sh from bin/flow-agent.sh.
-- Additive only: CREATE ... IF NOT EXISTS and INSERT OR IGNORE, one statement
-- per seed (bin/harness-sync.sh applies statement by statement).
--
-- flow_actions: one row per decision the agent claimed. decision_key (sha256
-- hex of project|KEY|code|episode, plus |would in log mode) is UNIQUE and is
-- the one dedup store: a claim is INSERT ... ON CONFLICT(decision_key) DO
-- NOTHING, and the record is a CAS on outcome='claimed'.
-- Indexes, one per query:
--   claim INSERT, claim read, record CAS  sqlite_autoindex_flow_actions_1 (decision_key UNIQUE)
--   GET /api/flow-agent/count             idx_flow_actions_ticket_created (project, ticket_key, created_at)
--   the panel list (BH-9924.10)           idx_flow_actions_project_id (project, id)
--   the retention rule (BH-9924.2)        idx_flow_actions_created (created_at)
-- Expected rows in 12 months: about 75k before retention (plan BH-9956).
CREATE TABLE IF NOT EXISTS flow_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  decision_key TEXT NOT NULL UNIQUE,
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  code TEXT NOT NULL,
  action TEXT NOT NULL,
  episode TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('claimed','would','done','failed','refused','escalated')),
  before_state TEXT,
  after_state TEXT,
  detail TEXT,
  box TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_flow_actions_ticket_created ON flow_actions(project, ticket_key, created_at);
CREATE INDEX IF NOT EXISTS idx_flow_actions_project_id ON flow_actions(project, id);
CREATE INDEX IF NOT EXISTS idx_flow_actions_created ON flow_actions(created_at);

-- flow_waiting: the snapshot of the waiting tickets of each project, replaced
-- by each pass for its own project only (PUT /api/flow-agent/waiting). Not a
-- dedup store. Bounded by the open tickets of a project (under 5k rows).
--   waiting upsert                 PK (project, ticket_key)
--   waiting delete of one project  PK prefix (project)
--   the panel order (BH-9924.10)   idx_flow_waiting_project_since (project, since)
--   the retention rule (BH-9924.2) idx_flow_waiting_seen (seen_at)
CREATE TABLE IF NOT EXISTS flow_waiting (
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  cause_code TEXT NOT NULL,
  since TEXT NOT NULL,
  episode TEXT NOT NULL,
  evidence TEXT,
  seen_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key)
);
CREATE INDEX IF NOT EXISTS idx_flow_waiting_project_since ON flow_waiting(project, since);
CREATE INDEX IF NOT EXISTS idx_flow_waiting_seen ON flow_waiting(seen_at);

-- The knobs. Each note names its reader and its code fallback.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.enabled','1','BH-9924: 0 stops bin/flow-agent.sh on every project (a missing row also stops it); reader bin/flow-agent.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.project.project-3.mode','act','BH-9924: act or log for project-3; a project with no row runs log; reader fa_mode in bin/lib/jobs/flow-agent.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.action.answered_not_retriaged','1','BH-9924: 1 lets the act mode run this arm, else the outcome is would; reader bin/lib/flow-agent/act.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.action.ready_not_queued','1','BH-9924: 1 lets the act mode run this arm, else the outcome is would; reader bin/lib/flow-agent/act.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.action.row_for_archived_ticket','1','BH-9924: 1 lets the act mode run this arm, else the outcome is would; reader bin/lib/flow-agent/act.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.action.waits_behind_green_pr','1','BH-9924: 1 lets the act mode run this arm, else the outcome is would; reader bin/lib/flow-agent/act.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.action.waits_behind_dead_blocker','1','BH-9924: 1 lets the act mode run this arm, else the outcome is would; reader bin/lib/flow-agent/act.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.action.parent_slices_not_filed','1','BH-9924: 1 lets the act mode run this arm, else the outcome is would; reader bin/lib/flow-agent/act.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.action.pr_conflict','1','BH-9924: 1 lets the act mode run this arm, else the outcome is would; reader bin/lib/flow-agent/act.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.action.pr_red_same_test_as_main','1','BH-9924: 1 lets the act mode run this arm, else the outcome is would; reader bin/lib/flow-agent/act.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.saved_min_default','60','BH-9924: the minutes one done action is counted as saving when no better number is known; reader the digest (BH-9924.2)','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.stall_min','20','BH-9924: minutes a ticket must sit still before it counts as stalled; reader bin/lib/flow-agent/rules/ready_not_queued.sh and cause.sh, code fallback FLOW_AGENT_STALL_MIN then 20','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.count_window_h','24','BH-9924: hours GET /api/flow-agent/count looks back; code fallback COUNT_WINDOW_H_DEFAULT in worker/jobs/src/routes/flow-agent.js','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.waiting_max','500','BH-9924: most rows in one waiting PUT and most records in one pass; code fallbacks WAITING_MAX_DEFAULT (worker) and FA_WAITING_MAX_DEFAULT (bin/lib/flow-agent/collect.sh)','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.evidence_max_chars','2000','BH-9924: the longest evidence text a waiting row stores, and the cut of the before/after/detail text of a flow_actions row; code fallback EVIDENCE_MAX_DEFAULT in worker/jobs/src/routes/flow-agent.js','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.pr_list_pages','3','BH-9924: most 100-row pages of open PRs one pass reads; code fallback FA_PR_LIST_PAGES_DEFAULT in bin/lib/flow-agent/collect.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.issue_list_pages','5','BH-9924: most 100-row pages of open ai-build issues one pass reads; code fallback FA_ISSUE_LIST_PAGES_DEFAULT in bin/lib/flow-agent/collect.sh','seed','2026-11-24T01:50:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('flow_agent.board_timeout_s','30','BH-9924: seconds each in-app board read (curl --max-time) may take; code fallback FA_BOARD_TIMEOUT_S_DEFAULT in bin/lib/flow-agent/collect.sh','seed','2026-11-24T01:50:00Z');
