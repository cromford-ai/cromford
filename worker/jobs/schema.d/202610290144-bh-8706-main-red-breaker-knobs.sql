-- ── BH-8706: the main-red breaker knobs as settings rows ────────────────────
-- Read through lane_env_apply main-red-breaker (bin/main-red-breaker.sh; the
-- skip override also by bin/main-red-detector.sh), row first, then env, then
-- the code fallback (the values below; catalog/lanes.d/main-red-breaker.json
-- is the registry). No table is created here, so no index or RLS applies.
-- The lane's own records are rows in the existing ledgers table (kinds
-- main_red_breaker and main_red_hotfix, keyed reads).
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.main-red-breaker.main_red_breaker_pause_label','merge-queue-paused','BH-8706: the label the breaker puts on queued PRs of a red repo; the Mergify confs exclude it (re-render on change)','seed','2026-10-28T00:00:00Z'),
  ('lane.main-red-breaker.main_red_breaker_max_prs','50','BH-8706: the most PRs one tick pauses or resumes per repo','seed','2026-10-28T00:00:00Z'),
  ('lane.main-red-breaker.main_red_breaker_max_jobs','5','BH-8706: the most failed jobs the hotfix ticket lists','seed','2026-10-28T00:00:00Z'),
  ('lane.main-red-breaker.main_red_breaker_max_annotations','10','BH-8706: the most failure annotations per failed job in the hotfix ticket (0 = none)','seed','2026-10-28T00:00:00Z'),
  ('lane.main-red-breaker.main_red_breaker_max_suspects','20','BH-8706: the most suspect merges the hotfix ticket lists','seed','2026-10-28T00:00:00Z'),
  ('lane.main-red-breaker.main_red_breaker_ticket_labels','ai-build,hotfix','BH-8706: the labels of the hotfix ticket, comma separated','seed','2026-10-28T00:00:00Z'),
  ('lane.main-red-breaker.main_red_breaker_tickets','1','BH-8706: 1 files one hotfix ticket per red episode; 0 = pause and resume only','seed','2026-10-28T00:00:00Z'),
  ('lane.main-red-breaker.main_red_skip_re_overrides','{}','BH-8706: JSON {"owner/repo":"regex"} replacing the global main-red skip regex for that repo; {} = none','seed','2026-10-28T00:00:00Z');
