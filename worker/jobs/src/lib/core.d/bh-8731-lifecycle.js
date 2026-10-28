// core.d/bh-8731-lifecycle.js — BH-8731 (lifecycle 1/6): the four build_queue
// columns that say where a TICKET is in its life, and the index of the stuck
// read. build_queue exists in the live D1, so the columns are ALTERs that
// ensureColumns runs, not schema.d text. All four are nullable and never
// backfilled: NULL phase = no lifecycle writer has moved the row yet.
//   phase        one of lib/lifecycle.js LIFECYCLE_PHASES
//   phase_at     when the phase was set (ISO, the ticket_events row's `at`)
//   phase_actor  the owner that set it (lib/lifecycle.js LIFECYCLE_ACTORS)
//   question     the open question of a plan_blocked row; NULL in any other phase
// idx_build_queue_phase_at serves GET /api/lifecycle/stuck
// (WHERE phase = ?1 AND phase_at < ?2 ORDER BY phase_at LIMIT ?n,
// routes/ticket-lifecycle.js STUCK_SQL and STUCK_PROJECT_SQL).
export const ADDED_COLUMNS = {
  build_queue: [["phase", "TEXT"], ["phase_at", "TEXT"], ["phase_actor", "TEXT"], ["question", "TEXT"]],
};
export const ADDED_INDEXES = {
  build_queue: ["CREATE INDEX IF NOT EXISTS idx_build_queue_phase_at ON build_queue(phase, phase_at)"],
};
