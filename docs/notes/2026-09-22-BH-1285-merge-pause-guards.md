# 2026-09-22 — BH-1285 merge pause / train / stacked guards

## What changed

Box-side merge lanes now honour the pause flags the rest of the fleet already
reads through `flag_active` (the console row, with the flag file as the fallback),
and none of them lands a merge-train PR or a stacked PR into its parent branch.

- `bin/merge-queue.sh`:
  - The kill-switch line keeps BH-1370's shape (`flag_active` decides whenever it
    is defined; the bare file test is only the fallback) and now also stands down
    on `paused-<project>`. Each stand-down logs the flag it honoured.
  - Exports `BASE_BRANCH` (default `main`), the same convention `run-build.sh` uses.
  - Both PR reads (train members and the serial loop) now carry `.base.ref`.
  - Train members: a non-main base or a `train/*` head is left out of the union.
  - Serial loop, AFTER the not-OPEN dequeue (so a stacked PR that merged into its
    parent, or was closed, still leaves the queue): an OPEN `train/*` head is
    dropped with the ledger reason "merge-train PR (train/*) is never eligible for
    the box queue"; an OPEN PR whose base is not main is held and left queued,
    because it can still be retargeted. A null base reads as not main: held.
- `bin/review-prs.sh`:
  - `hold_paused_project` beside `hold_automerge_disabled`. `merge_step` checks it
    and logs; `merge_retry` returns silently on it, like the other switches, so a
    long pause never spends the retry budget or pages "needs a look".
  - `rp_base_hold`, the last hold before the direct `gh pr merge`: it reads
    `.base.ref`, and a base that is unreadable or not main leaves the APPROVE
    unmerged with one log line, no box-queue entry, and `RP_FENCED=1`, so
    `merge_retry` hands the attempt back.
- `bin/run-build.sh`: the tier-1 merge is demoted to tier 2 while
  `automerge-disabled` or `paused-<project>` is active (row or file). A tier-2 PR
  is enqueued at APPROVE (BH-1366) and lands only through the guarded queue.

## Why

On 2026-09-21 four PRs merged out of band. `bin/tier2-merge-sweep.sh`, the
ticket's named culprit, was retired on main by BH-1366, but every box-side merge
writer left on main still had the same gaps: `merge-queue.sh`, `review-prs.sh`
and `run-build.sh` read only `automerge-disabled`, never `paused-<project>`, and
nothing read `.base.ref` or the `train/*` head prefix, so a stacked PR could merge
into its parent branch and a train PR with no build record could land.

## Doc tags

Doc: MERGE-CONDUCTOR, BUILD-CONCURRENCY

## Tests

`tests/merge-gates.bh-1285-test.sh`:

- AT-4, AT-5, AT-11: the queue stands down on `automerge-disabled`, on
  `paused-<project>`, and on a console row with no flag file.
- AT-6, AT-7, AT-13: a stacked PR is held and stays queued. A `train/*` PR is
  dropped with its reason. Neither is merged.
- AT-12: a stacked PR that already MERGED into its parent is dequeued, not held.
- AT-10: a normal main-based PR still lands.
- AT-8, AT-9, AT-8P: `merge_step` stands down on `paused-<project>` and
  `automerge-disabled`. The later holds are stubbed open, and a positive control
  proves the merge is reachable with no flag.
- AT-14: `merge_retry` under the project pause spends no attempt and writes no
  ALERT, and the same APPROVE merges once the pause lifts.
- AT-15: `merge_step` refuses a PR based on `ticket/bh-872`, and `merge_retry`
  refunds that attempt.

AT-1..AT-3 covered the retired `tier2-merge-sweep.sh` and were removed with it.
