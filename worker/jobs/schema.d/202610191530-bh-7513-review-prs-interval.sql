-- BH-7513: review-prs tick interval per project, read where the crontab is
-- rendered (bin/lib/cron-lines.sh cron_review_intervals). Allowed 10, 15, 30;
-- no row means 30, the line every project had before. project-6-os moves to 10
-- on 2026-10-19 (the operator approved a higher review limit; its pool moves to Fly in
-- #7505). Data only: no new table, no new index, no retention rule needed.
-- Rollback: set the row to 30 (or delete it) and let the next render run.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.review-prs.project-6-os.review_prs_interval_min','10','BH-7513: project-6-os review-prs runs every 10 minutes (six cron minutes, 10 apart) instead of twice an hour; 10, 15 or 30 (default 30); applied at the next box crontab render','seed','2026-10-19T00:00:00Z');
