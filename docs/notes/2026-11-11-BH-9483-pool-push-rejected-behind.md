# A hub-opened PR on a branch behind main gets a pool rebase at once (BH-9483)

Doc: OPERATING

Slice C1 of #9406, item 3 (project-6 TK-3738). When a pool build reports
"push rejected" and the remote branch already holds the built head, the hub
opens the PR itself (BH-6821). Before this change it never read main. A PR
opened on a stale base waited until the conductor's `land_rebase_arm` saw the
next merge on main.

## What changed

`bin/lib/pool-push-rejected.sh`:

1. `ppr_reap_landed` reads `compare/main...<branch>` once, before the PR
   create, and keeps `behind_by` in `PPR_BEHIND`. It reads it only when the PR
   base is `main` (a stacked PR's base is its parent; the stack lane owns that).
   A read that fails, or gives no integer `behind_by`, keeps the old path: the
   PR opens and no rebase is queued.
2. `ppr_after_reap` calls the new `ppr_rebase_behind` before the lead-review
   hand-off. When the branch is behind and `REBASE_ON_POOL=1` for the project,
   it calls the conductor's `mc_pool_rebase_enqueue` with the new PR url and
   the remote head. That is the same `RB-<pr>-<head8>` row the conductor
   queues, so the queue dedupes the two. The RB-* reap arm and
   `mc_pool_rebase_apply` apply the result, unchanged.

## The knob

`POOL_PUSH_LANDED_REBASE` (fly-pool lane, default 1). 0 = off: no compare of
main and no rebase from this path.

## Evidence on disk

`builds/pool-<project>-<KEY>-*/prepr-rebase.txt`, one line, `<word> <detail>`:

| word | meaning |
|---|---|
| `queued` | `RB-<pr>-<head8> behind_by=<n>`: the row is in the pool queue |
| `not-queued` | `rc=<rc>` or `conductor lib missing`: nothing spent |
| `skipped` | `REBASE_ON_POOL` is off for the project |
| `current` | `behind_by=0` |
| `unknown` | the compare did not read |

The pool log has one line per outcome, for example
`push-rejected <KEY>: <branch> is 3 behind main — pool rebase queued as RB-901-f56eba45 for <url>`.
No outcome writes an ALERTS line: a `not-queued` spent nothing, and
`land_rebase_arm` still owns the PR.

Test: `tests/pool-push-rejected-behind.bh-9483-test.sh` (B1-B9).
