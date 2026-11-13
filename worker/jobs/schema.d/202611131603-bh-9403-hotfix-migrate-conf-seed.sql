-- ── BH-9403: add-only migrations apply before the merge, for normal PRs ─────
-- hotfix_migrate.conf.<project>: one JSON object, read by
-- bin/lib/hotfix-migrate-knobs.sh (hmk_conf) in bin/hotfix-migrate.sh, in the
-- `# >>> hotfix migrate stage` block of bin/lib/rb/result.sh and in the
-- merge-conductor fragment bin/merge-conductor.d/bh-9403-before-merge-proof.sh.
-- A key beats the env-file knob of the same meaning; an absent key leaves it.
-- "before_merge":1 runs the stage for a normal PR whose build verdict is APPROVE.
-- Kill switch: set "before_merge":0, or the row to '{}'.
-- project-6-os: migrate-branch.yml from main, one file per dispatch, the PR
-- branch in the `ref` input, an APPROVED review on the reviewed head first,
-- and "require_word":1 (a green run that names no outcome for OUR file is
-- failed, never applied: on `main` it can be the run of another PR).
-- project-5: "Migrate Manual SQL" (migrate-manual.yml), its `file` input, from
-- the PR branch with the repo path, as today.
-- No table is created here (D1, not Supabase: no RLS, index or retention rule
-- applies). INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('hotfix_migrate.conf.project-6-os','{"before_merge":1,"workflow":"migrate-branch.yml","files_input":"file","max_files":1,"per_file":1,"dispatch_ref":"main","branch_input":"ref","file_form":"basename","glob":"prisma/sql/*.sql","approve_head":1,"needs_quiet":"off","local_gate":"advisory","gate_workflows":"migration-ledger.yml","log_cap_kb":2048,"require_word":1}','BH-9403: the before-merge migration apply of project-6-os (JSON; keys in bin/lib/hotfix-migrate-knobs.sh). Kill switch: "before_merge":0','seed','2026-11-12T19:44:00Z'),
  ('hotfix_migrate.conf.project-5','{"before_merge":1,"workflow":"migrate-manual.yml","files_input":"file","per_file":1}','BH-9403: the before-merge migration apply of project-5 (Migrate Manual SQL; JSON keys in bin/lib/hotfix-migrate-knobs.sh). Kill switch: "before_merge":0','seed','2026-11-12T19:44:00Z');
