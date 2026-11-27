// core.d/bh-10213-pr-records-gh-empty.js — BH-10213: one more pr_records
// column, gh_empty, JSON text, NULL = never checked empty. A lane's GitHub
// read after a record miss that found nothing (no commit status for a head,
// no Mergify payload comment) is stored here as an explicit "checked, empty"
// marker, so the next tick is a record hit:
//   {statuses?: {sha, at}, mergify_queue?: {sha, at}}
// sha is the head the answer holds for (the asked head for statuses, the
// row's head_sha for the Mergify payload); at is the time the GitHub read
// started. Writer: POST /api/pr-record-notes (src/routes/pr-record-notes.js).
// Readers: pr_record_statuses and pr_record_mergify (bin/lib/pr-record.sh),
// which serve it for at most PR_RECORD_FIELD_MAX_AGE_S and only when the
// record holds no real value.
// No new index: both marker statements (EMPTY_STATUSES_SQL, EMPTY_MERGIFY_SQL)
// are point UPDATEs on ux_pr_records_repo_number (repo, number). EXPLAIN on
// 5,000 rows: test W8 of test/pr-record-notes.bh-10213.test.js.
export const ADDED_COLUMNS = {
  pr_records: [["gh_empty", "TEXT"]],
};
