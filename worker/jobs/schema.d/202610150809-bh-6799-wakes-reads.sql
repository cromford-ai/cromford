-- BH-6799: the wakes reads. Live on 2026-10-14, POST /api/wakes/claim read
-- 4,557 rows a call for a box 67,159 rows behind, and GET /api/wakes/summary
-- aggregated every wake in its window on every call. Additive only.
--
-- POST /api/wakes/claim: `lower(repo) IN (...) AND id > ? AND id <= ?`. An
-- expression index, so the claim's lower(repo) predicate is a range SEARCH and
-- no writer has to store a lowercased copy.
CREATE INDEX IF NOT EXISTS idx_wakes_repo_lc_id ON wakes(lower(repo), id);
-- POST /api/wakes/claim: `kind IN (...) AND id > ? AND id <= ?` (the hub's
-- all-repo kinds). With the index above, the claim's OR plans as MULTI-INDEX OR.
CREATE INDEX IF NOT EXISTS idx_wakes_kind_id ON wakes(kind, id);
-- One row per repo that ever rang: its newest wake id, newest wake time and
-- every kind it rang with (a JSON array). GET /api/wakes/summary folds
-- the wakes above MAX(last_id) into it and then answers from it alone. It holds
-- tens of rows and grows only when a repo is onboarded, so it has no retention
-- rule; it is a cache of `wakes` and its watermark is its own MAX(last_id).
CREATE TABLE IF NOT EXISTS wake_repo_last (
  repo TEXT PRIMARY KEY,
  last_id INTEGER NOT NULL,
  last_at TEXT NOT NULL,
  kinds TEXT NOT NULL
);
-- The fold's watermark read: SELECT MAX(last_id) FROM wake_repo_last.
CREATE INDEX IF NOT EXISTS idx_wake_repo_last_last_id ON wake_repo_last(last_id);
-- GET /api/wakes/cursor?all=1 marks a box stale when its cursor is more than
-- cursor_lag_alert_rows behind MAX(id) AND it has not moved for
-- cursor_lag_alert_s seconds. bin/doorbell-coverage-check.sh alerts on it.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('wakes.cursor_lag_alert_rows','10000','BH-6799: rows a box cursor may be behind MAX(wakes.id) before GET /api/wakes/cursor?all=1 marks it stale (with cursor_lag_alert_s).','seed','2026-10-15T00:00:00Z'),
  ('wakes.cursor_lag_alert_s','3600','BH-6799: seconds a lagging box cursor may stay unmoved before GET /api/wakes/cursor?all=1 marks it stale.','seed','2026-10-15T00:00:00Z');
