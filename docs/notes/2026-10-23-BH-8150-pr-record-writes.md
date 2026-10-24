# BH-8150 (slice C1 of BH-8067): the fleet's own writes update the PR record

Doc: DB-COORDINATION-SPEC

What changed:

- New lib `bin/lib/pr-record-write.sh`. `prr_write <repo> <n> <kind>
  <extra-json|-> <cmd...>` runs a GitHub write unchanged (same rc, stdout
  byte for byte, stderr untouched). When the write returns 0, it writes the
  record from GitHub's answer: `labels` (the full label set the issues-labels
  endpoints answer), `comment` (`last_comment_id`), `pull` (the pulls object),
  or `none`, plus a fixed `queue_state` for a queue request. `at` is taken
  before the write, so a webhook for the same event wins.
- `prr_note_push` follows a successful push: `head_sha`, and for a new sha
  also `checks: {}` and `mergeable_state: unknown`.
- Write sites: `bin/lib/mc/queue.sh`, `bin/lib/mc/classify.sh`,
  `bin/lib/mc/rebase.sh`, `bin/merge-queue.sh`, `bin/lib/rb/pr.sh`,
  `bin/lib/rb-pr-labels.sh`, `bin/lib/rb-full-ci-label.sh`. The GitHub
  write in each line is the same as before.
- `queue_state` values the fleet writes: `requested` (`@mergifyio queue`,
  `@mergifyio requeue`, the GitHub-queue enqueue), `dequeue_requested`
  (`@mergifyio dequeue`), `merge_requested` (the direct merge verb). They name
  what the fleet asked for, not what the queue did.
- The record is written only when the caller already loaded the jobs client.
  The conductor, the merge queue and run-build do. A suite that stubs `gh`
  and never loads the client makes no jobs request.
- The conductor shim `bin/lib/merge-conductor-lib.sh` loads the lib before
  the modules. `bin/lib/mc/log.sh` defines pass-through stubs when it is
  absent (rows in `tests/mc/expected-map.d/BH-8150.tsv`), the same pattern as
  `issue_close_shipped`. `mc/queue.sh`, `mc/classify.sh` and `mc/rebase.sh`
  carry the same stubs behind a `type` guard, for a caller that sources one
  module alone. The other site files have a one-line pass-through fallback.
- `tests/gh-app-ratchet-test.sh`: the scanner strips a `prr_write <repo> <n>
  <kind> <extra>` prefix before it looks for `gh` at command position, so a
  wrapped call is still a call to the ratchet (fixture block 1a).
- Knob `PR_RECORD_WRITES` (default 1, 0 = no record writes) in
  `catalog/lanes.d/_lib.pr-record-write.json`.
- A failed record write (not a 4xx) sets a per-process latch file in TMPDIR
  and writes one `logs/pr-record.log` line:
  `write <repo>#<n> <kind> put=failed (<status>): record writes off for pid <pid>`.
  The process then sends no more record writes. A 4xx writes one line and no
  latch.

Not in this slice: webhooks (C2), lane reads of the record (C3+), pushes with
no PR number at the site (`mrt_rebase_pure`, `bin/lib/mc-prequeue.d/`,
`rb/execute.sh`, `rb/review.sh`), and the REST merge rung `gh_pr_merge_rest`.
