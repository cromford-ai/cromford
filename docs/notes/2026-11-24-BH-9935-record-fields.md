# The PR record holds statuses, the Mergify payload, the head commit time and the file list (BH-9935)

Doc: DB-COORDINATION-SPEC

Wave 3 of 7 of #9926 (BH-9926.3).

What changed:
- `pr_records` has four more JSON columns and two indexes
  (`worker/jobs/src/lib/core.d/bh-9935-pr-records-fields.js`):
  - `statuses`: `{<context>: {state, description, sha, at}}`, at most `CHECKS_MAX` contexts.
  - `mergify_queue`: `{state, code, draft_pr, failing_checks, left_sha, comment_id, at}`.
  - `head_commit`: `{sha, at}`, the commit time of the pushed head.
  - `files`: `{sha, paths}`, the changed paths of head `sha`, sorted and unique.
  - `idx_pr_records_repo_head_sha` serves the status write. `idx_pr_records_repo_head`
    serves the push write.
- The webhook writer (`worker/jobs/src/lib/pr-record-fields.js`, called from
  `pr-record-intake.js`) fills three of them:
  - `status`: one entry per context on every record whose `head_sha` is the status sha.
    An older status never replaces a newer one. A status that arrives before the record
    knows its head is lost.
  - `issue_comment` from exactly `mergify[bot]` with the payload markers: the newest
    payload by (created_at, id), never by updated_at. This is the `fbh_parse` rule of
    `bin/lib/mc-failed-batch.sh`. The comment body is never stored.
  - `push` to a branch that is not the default branch: `head_commit` on the open records
    of that head ref. The order is the push time (`repository.pushed_at`), not the commit
    time, because a rebase can push an older commit.
  - `pull_request` writes no `head_commit`: its payload carries no commit time.
- `PUT /api/pr-records` takes the four fields. `GET /api/pr-records?repo=&number=`
  returns them parsed. The list read does not return them.
- `bin/lib/pr-record.sh` has five readers: `pr_record_statuses`, `pr_record_mergify`,
  `pr_record_head_commit_time`, `pr_record_files` and `pr_record_label_list`. The header
  of the file gives their arguments, return codes and log lines.
  - `pr_record_files` reads `pulls/<n>/files` one time for each head sha. A head sha
    does not change, so a stored list needs no refresh. A list that fills all 30 pages
    (GitHub's 3,000-file cap) can be cut, so it is printed and never stored.
  - `pr_record_put` now passes the fields to jq on stdin. A list of 3,000 paths is
    larger than one argv string can be (128 KB).
- No lane calls the new readers in this wave. Waves 4 to 6 of #9926 move their callers.

Retention: the existing `pr_records` sweeps (closed 14 days, age 90 days) delete whole
rows, so the new columns go with them. There is no new table and no new knob.
