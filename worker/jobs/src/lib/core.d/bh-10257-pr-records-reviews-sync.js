// core.d/bh-10257-pr-records-reviews-sync.js — BH-10257 (slice 2): the pr_records
// column that tells the merge conductor its review set is complete.
//   reviews_sync  JSON {head_sha, at, cr}: the conductor's own whole GitHub
//                 reviews read of head_sha (bin/lib/prr-shadow.d/merge-conductor.sh
//                 mc_cr_github), started at `at`; cr 1 when a CHANGES_REQUESTED
//                 stood on it, 0 when none did. NULL = no such read. Only a PUT
//                 writes it (source github); no webhook does. The reader
//                 (mc_cr_record) trusts the set only when no review was delivered
//                 after `at` (fields_at.reviews <= at).
// Read with the row (GET_SQL, ux_pr_records_repo_number): no new index.
export const ADDED_COLUMNS = {
  pr_records: [["reviews_sync", "TEXT"]],
};
