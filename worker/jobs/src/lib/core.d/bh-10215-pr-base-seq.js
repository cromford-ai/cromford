// core.d/bh-10215-pr-base-seq.js — BH-10215: pr_records.mergeable_base_seq,
// the pr_base_seqs.seq of (repo, base_ref) at which the row's mergeable_state
// was read from GitHub. NULL = not known (a webhook or step-off write).
// bin/lib/pr-record-serve.sh serves the row while it equals the current seq
// (GET /api/pr-base-seqs). The PUT takes it (routes/pr-records.js
// VALUE_FIELDS) and stamps fields_at.mergeable_base_seq like any field. No
// query filters on it, so it needs no index.
export const ADDED_COLUMNS = {
  pr_records: [["mergeable_base_seq", "INTEGER"]],
};
