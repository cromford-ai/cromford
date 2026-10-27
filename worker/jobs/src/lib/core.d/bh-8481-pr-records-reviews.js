// core.d/bh-8481-pr-records-reviews.js — BH-8481 (C0): the two pr_records
// columns bin/pr-owner-sweep.sh needs to read its lists from the record, and
// the index of the created-time window read.
//   merged_at   GitHub's merged_at (the sweep's `mergedAt`); NULL = not merged or unknown
//   reviews     JSON object, one entry per reviewer keyed by the bare lowercase
//               login: {state, commit_id, at}. NULL = unknown, {} = known, none
//               (only a pull_request.opened delivery or a full list sync knows that)
// idx_pr_records_repo_state_created serves GET /api/pr-records?repo=&state=
// &order=created (WHERE repo, state ORDER BY pr_created_at DESC LIMIT n),
// the window `gh pr list --limit n` returns (routes/pr-records.js LIST_CREATED_SQL).
export const ADDED_COLUMNS = {
  pr_records: [["merged_at", "TEXT"], ["reviews", "TEXT"]],
};
export const ADDED_INDEXES = {
  pr_records: ["CREATE INDEX IF NOT EXISTS idx_pr_records_repo_state_created ON pr_records(repo, state, pr_created_at)"],
};
