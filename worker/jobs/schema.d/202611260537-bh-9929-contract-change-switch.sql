-- ── BH-9929: the contract-change lane switch, per project ──────────────────
-- Reader: bin/lib/contract-change.sh cc_enabled, through
-- lib_env_apply contract-change <project> (registry:
-- catalog/lanes.d/_lib.contract-change.json; code fallback 0 = off).
-- The ticket: "Per-project switch in the registry. On for project-6 and
-- project-3 first." project-6 = project project-6-os (repo example-org/project-6).
-- No table is created here, so no index or RLS applies.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lib.contract-change.project-6-os.contract_change_enabled','1','BH-9929: 1 = the contract-change lane (expand, migrate, contract) runs for project-6-os; 0 = off','seed','2026-11-24T00:00:00Z'),
  ('lib.contract-change.project-3.contract_change_enabled','1','BH-9929: 1 = the contract-change lane (expand, migrate, contract) runs for project-3; 0 = off','seed','2026-11-24T00:00:00Z');
