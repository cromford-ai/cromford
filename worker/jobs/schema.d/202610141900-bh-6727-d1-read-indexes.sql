-- BH-6727: the harness-jobs D1 read 100-160M rows an hour (2026-10-14) and
-- answered "D1 DB is overloaded" 875 times in 5 hours. Five query shapes read
-- about 80% of those rows because, with no ANALYZE statistics (D1 runs none),
-- SQLite picked a full table scan. Each index below serves one hot read; the
-- test worker/jobs/test/d1-read-indexes.bh-6727.test.js asserts each plan on a
-- D1 seeded at the live row counts. Additive only (IF NOT EXISTS).
--
-- Applied to the live D1 by hand on 2026-10-14 ~17:10Z (operator-a5), so the
-- schema and the database agree:
-- GET/POST wake cursor reads: WHERE id > ? AND repo = ? ORDER BY id.
CREATE INDEX IF NOT EXISTS idx_wakes_repo_id ON wakes(repo, id);
-- GET /api/cost-rows: WHERE ts >= ? AND ts <= ? ORDER BY ts DESC LIMIT ?.
CREATE INDEX IF NOT EXISTS idx_cost_rows_ts ON cost_rows(ts);
-- The daily digest's per-ticket MIN(issue_created_at), joined on (project, ticket_id).
CREATE INDEX IF NOT EXISTS idx_jobs_project_ticket ON jobs(project, ticket_id);
-- The merge window read: kind='merge' AND status='merged' AND created_at in a range.
CREATE INDEX IF NOT EXISTS idx_ledgers_kind_status_created ON ledgers(kind, status, created_at);
--
-- New in this fragment (not yet on the live D1 at 17:10Z):
-- GET /api/jobs (JOBS_SELECT ... ORDER BY j.created_at DESC LIMIT n): with no
-- filter, with ?status=, and with ?project= the newest rows come off the index
-- in order, so a call reads about `limit` rows, not the whole table.
CREATE INDEX IF NOT EXISTS idx_jobs_created ON jobs(created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_status_created ON jobs(status, created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_project_created ON jobs(project, created_at);
-- The same read with ?project= and ?status= or ?ticket_id= (job_ticket_abandoned,
-- the box's open-job reads): the index ends in created_at, so the newest rows
-- of that one project and status or ticket come first, with no sort.
CREATE INDEX IF NOT EXISTS idx_jobs_project_status_created ON jobs(project, status, created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_project_ticket_created ON jobs(project, ticket_id, created_at);
-- GET /api/dora launch read: kind='build' AND first_spawn_at >= ?.
CREATE INDEX IF NOT EXISTS idx_jobs_kind_spawn ON jobs(kind, first_spawn_at);
