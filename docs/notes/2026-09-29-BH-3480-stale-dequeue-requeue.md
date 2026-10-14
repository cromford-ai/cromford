# A stale Mergify dequeue is requeued once a fresh verdict binds the new head (BH-3480)

Doc: MERGIFY, MERGE-CONDUCTOR

## Why

On 2026-09-29, Mergify dequeued #3396 for a failing check (payload comment
created 02:03:02Z). A fix was pushed at 03:36 and approved. The PR still carried
`merge-queue`, so its conductor row read QUEUED: `mc_mergify_inqueue` answers
"in queue" for our label plus a row that was QUEUED last tick. Mergify ignores a
plain `@mergifyio queue` on a dequeued PR. Nothing posted `@mergifyio requeue`
until a person did it at 03:45:44, and the PR merged at 04:03.

## What changed

1. **`bin/lib/mc-stale-dequeue.sh`** (new, sourced by the conductor and by
   pipeline-health). It has four pieces:
   - `sdq_payload_last <slug> <num>` reads the PR's comments once (`--paginate`).
     It picks the newest `mergify[bot]` comment that carries a
     `-*- Mergify Payload -*-` block, ordered by `(created_at, id)`, and prints
     `state<TAB>updated_epoch<TAB>id`. It returns rc 1 when there is no such
     comment and rc 2 when the read failed or the payload does not parse.
     - The dequeue time is the chosen comment's `updated_at`.
     - The comment is NOT chosen by `updated_at`. Mergify edits an older status
       comment after a newer one exists: #3396's dequeued comment got its
       "Requeued — continues in" link at 03:45:49.
   - `sdq_head_pushed_epoch` returns the head commit's committer date.
   - `sdq_decide` is pure and prints one of `requeue | resolver | wait | none`.
   - `sdq_arm` is the conductor's arm.
2. **`bin/merge-conductor.sh`** calls `sdq_arm` right after the BH-636 re-entry
   arm. It runs only for a Mergify repo, with no CR hold and
   `MC_QUEUE_REENTRY` ≠ 0, on an OPEN PR whose row is READY or QUEUED, that
   carries `merge-queue` and carries neither `queued` nor `checking`. So a PR
   Mergify visibly holds costs no read.
   - **A fresh verdict** is either of these:
     - a lead/human MERGE or MERGE-WITH-NOTES standing on HEAD
       (`vd_standing`), created after the dequeue time;
     - the conductor's own head-bound approval (`VERDICT=APPROVE`,
       `REVIEWED=HEAD`) on a head committed after it.

     A standing lead BLOCK stops it.
   - **`requeue`** writes the `requeued <key> <head>` mark BEFORE
     `mc_requeue_mergify`. That is BH-636's mark and BH-636's `MC_REQUEUE_CAP`
     tick budget, so the two arms share one requeue per head.
     - Log lines: `STALE_DEQUEUE_REQUEUED`, or `REQUEUE_UNWITNESSED` /
       `REQUEUE_FAILED`.
     - Counter: `staledequeue_requeue`, bumped only on rc 0 or 2.
     - It does not act when merge mode is off (`STALE_DEQUEUE_WOULD_REQUEUE`),
       or when the PR is not MERGEABLE, is DIRTY or CI is red
       (`STALE_DEQUEUE_WAIT`).
   - **`resolver`**: the head was requeued and Mergify's payload was updated
     more than 300 s after that requeue. It writes `reejected <key> <head>` and
     parks the row `BLOCKED_HUMAN queue-ejected-twice`, which the
     blocked-resolver owns. The log line is `STALE_DEQUEUE_RESOLVER`.
     - The 300 s grace exists because Mergify edits the old dequeued comment in
       the same second it takes a requeue.
   - **`wait`**: the row reads `WAIT_CI requeued on <sha>, waiting for Mergify
     to acknowledge — never re-queued twice` instead of claiming QUEUED.
   - Any unreadable payload or verdict read does nothing that tick, and it is
     logged.
3. **`bin/pipeline-health.sh`** gets the `# >>> stale dequeue (BH-3480)` block,
   which pages `staledequeue:<p>:<n>`.
   - It fires for an open PR carrying `merge-queue`, without `queued` or
     `checking`, whose newest payload has said `dequeued` for at least
     `STALE_DEQUEUE_MIN` minutes, with no head committed since.
   - It reads one list per repo and at most 30 PRs per repo; past the 30th it
     pages `staledequeue:<p>:page-cut`.
   - It reads on the repo's own identity (`gh_repo_use_token`, as the stalepr
     block does). A failed read skips that PR or repo.
   - `staledequeue` is in `RETRACT_NS`, so a fixed or merged PR retracts its
     page.
4. **gh identity.** The lib calls `gh` raw on purpose, on the identity its
   caller already armed (the same shape as `bin/lib/block-gate.sh`). It is
   registered in `tests/gh-app-ratchet-by-design/lib/mc-stale-dequeue.sh.txt`
   for the review to accept or refuse.
5. **Settings row** `STALE_DEQUEUE_MIN` on the `pipeline-health` lane (int,
   default 30, min 1). A junk value falls back to 30.

Not done: BH-3348's `lead-verdict` check run is not on main. When it lands,
`sdq_arm`'s freshness input moves to it.

## Operator checks

- `grep -E 'STALE_DEQUEUE_(REQUEUED|RESOLVER|WOULD_REQUEUE|WAIT)' logs/merge-conductor.log`
- `grep staledequeue logs/ALERTS.log`
- `tests/merge-conductor-stale-dequeue.bh-3480-test.sh`,
  `tests/pipeline-health-stale-dequeue.bh-3480-test.sh`
