-- ── BH-8734: the release cap ────────────────────────────────────────────────
-- Reader: worker/jobs/src/routes/queue.js (releaseAttemptMax), on a PATCH
-- /api/queue with count_attempt:true. The orphan release
-- (bin/lib/pool-orphan-rows.sh) and the jobs-watchdog stale-claim release send
-- it through queue_release_counted (bin/lib/jobs/queue.sh).
-- No table is created here, so no index or RLS applies.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('queue.release_attempt_max','3','BH-8734: a counted queue release (orphan release, watchdog stale-claim release) that would take build_queue.attempt past this value ends the row failed instead of queued (whole number >= 1; code default 3).','seed','2026-11-03T00:00:00Z');
