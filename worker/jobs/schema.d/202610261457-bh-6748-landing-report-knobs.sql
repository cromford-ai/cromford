-- ── BH-6748 (wave 5 of #6541): the landing report knobs ─────────────────────
-- Read through ph_knob (bin/lib/pr-health.sh: the row, then env, then the code
-- fallback named beside each read).
--   landing.report.decision_pages  pages of 200 landing_decisions rows read per
--       repo (bin/lib/landing-sources.sh ls_fetch). Env
--       LANDING_REPORT_DECISION_PAGES. Code fallback 10.
--   landing.report.ledger_pages  pages of 1000 merge ledger rows read for the
--       fleet (ls_fetch). Env LANDING_REPORT_LEDGER_PAGES. Code fallback 5.
--   landing.report.gh_pages  pages of 100 closed PRs read from GitHub per repo
--       with landing activity (ls_fetch). Env LANDING_REPORT_GH_PAGES. Code
--       fallback 3.
--   landing.replay.days  the default window of bin/landing-replay.sh (1..90,
--       inside retention.landing_decisions.days). Env LANDING_REPLAY_DAYS.
--       Code fallback 7.
-- No CREATE TABLE: settings rows only, so no index or retention rule is owed.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('landing.report.decision_pages','10','BH-6748: pages of 200 landing_decisions rows bin/lib/landing-sources.sh reads per repo (digest landing block, bin/landing-replay.sh). Code default 10','seed','2026-10-26T14:57:00Z'),
  ('landing.report.ledger_pages','5','BH-6748: pages of 1000 merge ledger rows bin/lib/landing-sources.sh reads for the fleet. Code default 5','seed','2026-10-26T14:57:00Z'),
  ('landing.report.gh_pages','3','BH-6748: pages of 100 closed PRs bin/lib/landing-sources.sh reads from GitHub per repo with landing activity. Code default 3','seed','2026-10-26T14:57:00Z'),
  ('landing.replay.days','7','BH-6748: default window in days of bin/landing-replay.sh (1..90). Code default 7','seed','2026-10-26T14:57:00Z');
