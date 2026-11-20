-- ── BH-9850: the poll bound of the per-isolate single-flight ────────────────
-- Reader: worker/jobs/src/lib/isolate-flight.js (flightKnobs), for
-- ensureTable, ensureColumns (lib/core.js) and settingsRows
-- (lib/settings-cache.js). A request that finds a run in flight polls a plain
-- slot every d1_flight.poll_ms, for at most d1_flight.wait_ms, then runs its
-- own work; it never awaits another request's promise. It reads these rows
-- ONLY from the settings snapshot already in memory (peekSetting), never by a
-- D1 query, because they bound a wait on an overloaded D1. A value that is
-- not a whole number in range (wait 0..7000, poll 5..500) is ignored, never
-- clamped, and the code constants D1_FLIGHT_WAIT_MS (3000) and
-- D1_FLIGHT_POLL_MS (20) apply; the seeds equal them, so a deploy changes
-- nothing. wait 0 turns the join off: every request runs its own work.
-- No table is created here, so no index or RLS applies.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('d1_flight.wait_ms','3000','BH-9850: the longest a jobs-worker request polls for a create or settings read that another request has in flight, before it runs its own (ms, whole number 0..7000; 0 = never join; code default 3000). Read from the in-memory settings snapshot only.','seed','2026-11-20T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('d1_flight.poll_ms','20','BH-9850: how often a jobs-worker request polls a create or settings read that another request has in flight (ms, whole number 5..500; code default 20). Read from the in-memory settings snapshot only.','seed','2026-11-20T00:00:00Z');
