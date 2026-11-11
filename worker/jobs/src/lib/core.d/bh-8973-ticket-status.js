// core.d/bh-8973-ticket-status.js — BH-8973 (C0): the two indexes the live
// ticket-status read needs (routes/ticket-status.js). Both tables exist in the
// live D1, so these are ensureColumns statements, not schema.d text.
// idx_build_queue_project_ticket_id serves SQL.queue / SQL.edges / SQL.blockers:
//   a ticket named by its issue number (WHERE project = ?1 AND ticket_id IN json_each(?3)).
// idx_pr_records_repo_head serves SQL.prs:
//   the ticket's PRs by branch (WHERE repo = ?1 AND head_ref = 'ticket/<key>'
//   or head_ref in ['ticket/<key>-', 'ticket/<key>.')).
export const ADDED_INDEXES = {
  build_queue: ["CREATE INDEX IF NOT EXISTS idx_build_queue_project_ticket_id ON build_queue(project, ticket_id)"],
  pr_records: ["CREATE INDEX IF NOT EXISTS idx_pr_records_repo_head ON pr_records(repo, head_ref)"],
};
