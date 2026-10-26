// core.d/bh-8452-pr-records-list.js — BH-8452 (C0): the six pr_records
// columns the PR list readers use, and the index of the list read.
// pr_records exists (schema.d/202610221947-bh-8067-pr-records.sql), so the
// columns are ALTERs that ensureColumns runs, not schema.sql text. The index
// names an added column, so it lives here too (core.d/0000-added-indexes.js
// says why schema.sql cannot hold it).
//   title, author, body, url   the PR's GitHub values (author = user.login,
//                              url = html_url); NULL = unknown, body "" = empty
//   pr_created_at, pr_updated_at  GitHub's created_at / updated_at. The table's
//                              own created_at is the record's first write.
// idx_pr_records_repo_state_upd serves GET /api/pr-records?repo=&state=
// (WHERE repo, state [, pr_updated_at >=] ORDER BY pr_updated_at DESC) and
// the repo/state prefix of the absent mark in routes/pr-record-lists.js.
export const ADDED_COLUMNS = {
  pr_records: [["title", "TEXT"], ["author", "TEXT"], ["body", "TEXT"],
    ["pr_created_at", "TEXT"], ["url", "TEXT"], ["pr_updated_at", "TEXT"]],
};
export const ADDED_INDEXES = {
  pr_records: ["CREATE INDEX IF NOT EXISTS idx_pr_records_repo_state_upd ON pr_records(repo, state, pr_updated_at)"],
};
