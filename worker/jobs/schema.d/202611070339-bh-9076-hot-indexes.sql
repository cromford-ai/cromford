-- BH-9076: indexes for the hot statements whose EXPLAIN QUERY PLAN scanned a
-- hot table on the BH-6727 volume D1 (test/hot-statements-explain.bh-9076.test.js
-- E3, fixture test/fixtures/hot-statements.bh-9076.json). Without this index
-- the GET /api/progress/stamps job read walked all of idx_jobs_project_created
-- (49k rows live) on every call. Additive only: CREATE INDEX IF NOT EXISTS on
-- a base column, so the composed schema.sql applies it before the deploy
-- (bin/harness-sync.sh).
-- serves fixture H15-progress-job-stamps (WHERE updated_at >= ?1 AND status != 'running')
CREATE INDEX IF NOT EXISTS idx_jobs_updated_at ON jobs(updated_at);
