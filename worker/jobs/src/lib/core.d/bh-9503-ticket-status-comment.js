// core.d/bh-9503-ticket-status-comment.js — BH-9503 (C1 of #8973): the index
// the status-comment due read needs (routes/ticket-status-comment.js). The
// table exists in the live D1, so this is an ensureColumns statement, not
// schema.d text.
// idx_build_queue_project_updated serves SQL.recent: the project's queue rows
// that changed inside the watch window (WHERE project = ?1 AND updated_at >= ?)
// and are no longer open (status filtered on the index range).
export const ADDED_INDEXES = {
  build_queue: ["CREATE INDEX IF NOT EXISTS idx_build_queue_project_updated ON build_queue(project, updated_at)"],
};
