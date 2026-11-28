-- ── BH-9929: contract_changes, the contract-change step ledger ───────────────
-- A non-additive schema change runs as 3 ordered PRs per parent ticket: the
-- steps expand, migrate and contract. Each step PR records one row here. The
-- writer is POST /api/contract-changes (src/routes/contract-changes.js), called
-- by cc_record in bin/lib/contract-change-record.sh. The readers are
-- GET /api/contract-changes: the console project page (section "CONTRACT
-- CHANGES", console-ui/src/screens/ContractChangesPanel.js) and
-- bin/migration-autopilot.sh (one row by project + parent_ticket + step).
-- One row per (project, parent_ticket, step): a re-POST is an upsert, and an
-- empty or absent optional field never overwrites a stored value.
-- step has no CHECK constraint: the route validates it against
-- expand | migrate | contract (400 otherwise), so a 4th step is a code change,
-- not a table rebuild. id is AUTOINCREMENT so an archived id is never reused
-- (the archive copy is INSERT OR IGNORE on id).
--
-- INDEXES. Each read and the index that serves it:
--   upsert / one step row            WHERE project=? AND parent_ticket=?
--                                    AND step=?  UNIQUE autoindex
--   the list of one project          WHERE project=? ORDER BY updated_at DESC
--                                    idx_contract_changes_project_updated
--   retention ids                    WHERE updated_at < ? ORDER BY updated_at
--                                    idx_contract_changes_updated
--   archive history of one ticket    WHERE project=? AND parent_ticket=?
--                                    idx_contract_changes_archive_ticket
-- 12-month rows: about 3 per contract-change ticket, about 1,000 in total.
--
-- RETENTION (retention.d/bh-9929-contract-changes.js, the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies, so a run counts first):
-- these are history rows (who approved which step), so they are archived,
-- never silently deleted. A row not updated for retention.contract_changes.days
-- (730) is copied to contract_changes_archive and then deleted from
-- contract_changes in the same D1 batch. contract_changes_archive has no rule:
-- it is the history and keeps forever.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS contract_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  parent_ticket INTEGER NOT NULL,
  step TEXT NOT NULL,
  pr_url TEXT,
  head_sha TEXT,
  classes TEXT,
  backup_ref TEXT,
  restore_ref TEXT,
  verdict TEXT,
  approved_by TEXT,
  created_at TEXT,
  updated_at TEXT,
  UNIQUE (project, parent_ticket, step)
);
CREATE INDEX IF NOT EXISTS idx_contract_changes_project_updated ON contract_changes(project, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_contract_changes_updated ON contract_changes(updated_at);

-- no-retention: contract_changes_archive keeps forever by design; it is the history of archived contract_changes rows (about 1k rows a year)
-- id is the hot row's id, kept, so a copy is idempotent (INSERT OR IGNORE on
-- the primary key).
CREATE TABLE IF NOT EXISTS contract_changes_archive (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  parent_ticket INTEGER NOT NULL,
  step TEXT NOT NULL,
  pr_url TEXT,
  head_sha TEXT,
  classes TEXT,
  backup_ref TEXT,
  restore_ref TEXT,
  verdict TEXT,
  approved_by TEXT,
  created_at TEXT,
  updated_at TEXT,
  archived_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_contract_changes_archive_ticket ON contract_changes_archive(project, parent_ticket);

-- Knobs. INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('retention.contract_changes.days','730','BH-9929: days a contract_changes row stays hot after its last update before it moves to contract_changes_archive. Reader: retention.d/bh-9929-contract-changes.js (0 = rule off, fallback 730).','seed','2026-11-24T00:00:00Z'),
  ('lib.contract-change.contract_changes_list_max','100','BH-9929: the most rows GET /api/contract-changes returns (registry knob CONTRACT_CHANGES_LIST_MAX). Reader: routes/contract-changes.js (integer 1..500, fallback 100).','seed','2026-11-24T00:00:00Z');
