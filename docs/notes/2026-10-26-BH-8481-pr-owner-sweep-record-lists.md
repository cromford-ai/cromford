# pr-owner-sweep reads its PR lists from the PR record (BH-8481)

Doc: PR-OWNERSHIP

Slice C0 of #8481.

What changed:
- `pr_records` has two more columns, `merged_at` and `reviews`, and the index
  `idx_pr_records_repo_state_created` (`worker/jobs/src/lib/core.d/bh-8481-pr-records-reviews.js`).
  `reviews` is one `{state, commit_id, at}` entry per reviewer, keyed by the bare
  lowercase login. NULL is unknown. `{}` is known and empty.
- The webhook fills them. `pull_request` writes `merged_at`, and `opened` writes
  `reviews` `{}`. `pull_request_review` merges one entry into a known object
  (`REVIEW_MERGE_SQL`). It never turns NULL into a partial object.
- `GET /api/pr-records?repo=&state=&order=created&limit=<n>` answers the newest n
  rows by GitHub's created time: the window `gh pr list --limit n` returns.
- `POST /api/pr-record-lists` takes `state: merged`. A merged list is a window, so
  it marks nothing absent.
- `bin/pr-owner-sweep.sh` has a record tier between its BH-8270 copy and GitHub
  (`po_lists_record`). After each GitHub list read it writes both lists back
  (`pr_record_list_sync_gql`). The open list is written only when the page is
  shorter than `PR_OWNER_PR_LIMIT`.

The tier is used only when all of these hold: the sweep's own last GitHub list
read is no older than `PR_OWNER_LIST_GITHUB_FLOOR_S` (default 3600, 0 = off),
both record lists are trusted by `pr_record_list`, no `pr` wake arrived since the
older stamp, and no open PR with an unknown mergeable_state has a due conflict
clock without the `stale-conflict` label.

Why the floor: the record nulls `mergeable_state` on every base push. A PR that
turns CONFLICTING shows an unknown value in the record until GitHub is read. The
first CONFLICTING sight backdates `dirty_since` to `updatedAt`, so a sight up to
one floor late does not move the stale clock. In record mode an unknown
mergeable keeps its `dirty_since`, and only a CONFLICTING head gets the
`stale-conflict` label.

Logs: `PRR_HIT <slug>#list src=record` on a hit. `PRR_MISS <slug>#list why=`
only just before a GitHub list read. A record miss writes one
`list <repo> miss=<word>` line to `logs/pr-record.log`.
