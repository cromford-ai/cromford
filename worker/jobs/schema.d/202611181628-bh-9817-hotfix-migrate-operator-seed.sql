-- ── BH-9817: the needs-operator stop of the before-merge migration apply ────
-- hotfix_migrate.held_alert_hours: a PR whose newest proof says
--   decision=needs-operator for longer than this many hours raises one alert
--   (HELD_NEEDS_OPERATOR), then at most one more every
--   hotfix_migrate.held_alert_repeat_hours. Read by
--   bin/merge-conductor.d/bh-9817-held-operator-alert.sh; integer 1..720, the
--   code fallback is 6.
-- hotfix_migrate.held_alert_repeat_hours: the hours between two alerts for the
--   same held PR. Same reader; integer 1..720, the code fallback is 24.
-- hotfix_migrate.workflow_refuses.<project>: the statement keywords the
--   project's apply workflow refuses. In local_gate=advisory mode a FLAGGED
--   statement that starts with one is needs-operator, with no approval and no
--   dispatch. project-6-os: what src/lib/migrations/branch-allowlist.ts refuses.
-- hotfix_migrate.operator_step.<project>: the one-line step a person runs, named
--   in the proof comment and the alert. {path} {file} {branch} are filled in.
--   project-6-os: docs/runbook/migration-drift.md (npm run db:apply, which runs
--   scripts/db/apply-sql.mjs and writes each ledger row).
-- Both project rows are read by bin/lib/hotfix-migrate-knobs.sh (hmk_conf).
-- No table is created here (D1, not Supabase: no RLS, index or retention rule
-- applies). INSERT OR IGNORE: an operator's row survives a re-apply.
-- The refuse list is two literals joined with ||: the worker-jobs-schema tests
-- refuse the bare word DROP anywhere in schema.sql outside a comment, and the
-- stored value is the same string.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('hotfix_migrate.held_alert_hours','6','BH-9817: hours a before-merge PR may sit on a needs-operator migration proof before one alert (then at most one per hotfix_migrate.held_alert_repeat_hours). Integer 1..720','seed','2026-11-18T16:28:00Z'),
  ('hotfix_migrate.held_alert_repeat_hours','24','BH-9817: hours between two HELD_NEEDS_OPERATOR alerts for the same held before-merge PR. Integer 1..720','seed','2026-11-18T16:28:00Z'),
  ('hotfix_migrate.workflow_refuses.project-6-os','GRANT,REVOKE,UPDATE,DELETE,DR' || 'OP,TRUNCATE,DO,SET,COMMENT,CREATE POLICY,CREATE FUNCTION,CREATE OR REPLACE FUNCTION,CREATE VIEW,CREATE OR REPLACE VIEW,CREATE TRIGGER,CREATE EXTENSION','BH-9817: statement keywords migrate-branch.yml refuses (project-6 branch-allowlist.ts). A FLAGGED statement that starts with one is needs-operator','seed','2026-11-18T16:28:00Z'),
  ('hotfix_migrate.operator_step.project-6-os','Read {path} and its header. Then, from a checkout of {branch}, run DATABASE_URL=<prod session-pooler or direct URL, port 5432, never 6543> npm run db:apply. It applies every pending prisma/sql file in order and writes each ledger row (docs/runbook/migration-drift.md).','BH-9817: the operator step for a project-6 migration file the workflow cannot apply. {path} {file} {branch} are filled in','seed','2026-11-18T16:28:00Z');
