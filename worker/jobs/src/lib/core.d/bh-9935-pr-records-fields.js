// core.d/bh-9935-pr-records-fields.js — BH-9935 (BH-9926.3): four more
// pr_records columns, all JSON text, NULL = not seen / unknown. Their format,
// checks and writes are in src/lib/pr-record-fields.js.
//   statuses       {<context>: {state, description, sha, at}} from `status` deliveries
//   mergify_queue  the newest mergify[bot] queue payload {state, code, draft_pr,
//                  failing_checks, left_sha, comment_id, at}
//   head_commit    {sha, at}: the commit time of the pushed head
//   files          {sha, paths}: the changed paths of head sha (bin/lib/pr-record.sh)
// idx_pr_records_repo_head_sha serves STATUS_MERGE_SQL (WHERE repo = ?1 AND
// head_sha = ?2): a status event names a sha, never a PR.
// idx_pr_records_repo_head serves HEAD_PUSH_SQL (WHERE repo = ?1 AND
// head_ref = ?2 AND state = 'open'): a push names a branch, never a PR.
// MERGIFY_SQL upserts on ux_pr_records_repo_number. EXPLAIN on 5,000 rows:
// test X1 of test/pr-record-fields.bh-9935.test.js.
export const ADDED_COLUMNS = {
  pr_records: [["statuses", "TEXT"], ["mergify_queue", "TEXT"], ["head_commit", "TEXT"], ["files", "TEXT"]],
};
export const ADDED_INDEXES = {
  pr_records: [
    "CREATE INDEX IF NOT EXISTS idx_pr_records_repo_head_sha ON pr_records(repo, head_sha)",
  ],
};
