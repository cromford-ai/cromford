-- ── BH-9890: the main-red PR-pair operator-wait and freeze-age knobs ───────
-- Read through lane_env_apply main-red-pr-pair (bin/main-red-pr-pair.sh), row
-- first, then env, then the code fallback ({} and 21600; the registry is
-- catalog/lanes.d/main-red-pr-pair.knobs.d/<ENV>.json). No table is created here, so no
-- index or RLS applies.
-- main_red_pair_operator_wait_jobs: JSON {"owner/repo":"job[,job...]"}. A job
-- named here never forms a PR pair. project-6's migration-ledger "gate" fails
-- until an operator applies the PR's SQL to prod; on 2026-11-20 two PRs that
-- waited for that step froze project-6 merges for 2,240 minutes.
-- main_red_pair_freeze_max_age_s: a freeze of this lane older than this, with
-- main not red, forces a re-read of every named head and a warn alert.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.main-red-pr-pair.main_red_pair_operator_wait_jobs','{"example-org/project-6":"gate"}','BH-9890: JSON {"owner/repo":"job[,job...]"} of jobs that fail until a person acts; they never form a PR pair; {} = none','seed','2026-11-22T00:00:00Z'),
  ('lane.main-red-pr-pair.main_red_pair_freeze_max_age_s','21600','BH-9890: seconds before a PR-pair freeze with main not red forces a re-read of every named head and a warn alert; 0 = off','seed','2026-11-22T00:00:00Z');
