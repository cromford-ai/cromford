# The hub runs a hotfix PR and a READY PR the pool did not land (BH-9198)

Doc: MERGE-CONDUCTOR

## What changed

- With `conductor_workers_on_fly` on, `mc_fly_arm` (bin/lib/mc/fly-workers.sh)
  no longer enqueues a non-draft hotfix PR to the lane-run pool. It logs
  `<slug>#<n> fallback=hotfix — this PR runs on the hub this tick` and the
  hub's own pr_worker runs it. The test is `hotfix_pr_is` (the PR label, or
  the label in its build record), so the hotfix lane switch still applies.
  The tick's hotfix pending marker is kept. The rows of the PR are still read
  first: a machine's `deferred=rereview` still gives `machine-deferred` and
  the lead request (BH-9026).
- `mc_fly_enqueue` has a new answer, rc 9. It gives it when the newest
  `merge-conductor-pr` row of the key is `done`, rc 0 or null, with
  `PROF mc-pr state=READY ... deferred=-` (`mc_fly_ready_undeferred_for`).
  `mc_fly_arm` logs
  `<slug>#<n> fallback=machine-ready-undeferred (<key> READY on the machine with no land deferred; the hub lands it or logs why)`
  and runs the PR on the hub. rc 10 is the hotfix answer above.
- BH-9202 (#9207, merged first) makes `mc_fly_deferred_for` read the same
  row as `deferred=hold`, and that check runs before rc 9. So the live line is
  `<slug>#<n> fallback=machine-deferred (hold)`, and rc 9 is a second guard.

## Why

A machine that reaches READY can stop at one of pr_worker's READY gates
(block gate, prequeue defer, lead-unpinned, MERGE_HELD) before its
machine-defer step. It then defers nothing, and the hub enqueued a new row on
every tick. No one landed the PR, and its reason stayed in the machine's
ready-why file. #9188 was STUCK 299m in this way, and #9148 had rows 89609,
89844 and 90051 with that shape. A pool machine never lands, so a hotfix in
the pool only waited.

There is no per-tick fallback cap. `FLY-ENQUEUE ... fallback=<n>` counts the
PRs sent to the hub.

Test: `tests/conductor-fly-hotfix-hub.bh-9198-test.sh`.
