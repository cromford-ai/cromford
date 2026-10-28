# BH-8610: a passed prequeue group releases its members (2026-10-27)

## What happened

Group `g1793106162712d` (6 PRs) passed at 13:03Z on main `a43d2f08`. At 13:55Z
none of the 6 PRs had a lead-verdict status or a queue entry. Main moved at
13:49Z. A keyed run at 14:01Z put each PR in a NEW group of one PR.

## Causes found in the code

1. `wpk_done_prs` (`bin/lib/wake-prequeue-keys.sh`) read only
   `prequeue-gate.yml` runs and matched only the per-head title. A completed
   `prequeue-group-gate.yml` run woke no member.
2. The group verdict was read only in a member's own READY arm. A held row does
   not change, so the backstop skipped it after 3 runs (BH-8310).
3. `pq_group_join` joined only a group of the same tick id. Each keyed run has
   its own tick id, so each member opened its own group, and each flush
   abandoned the other runs' groups.

## What changed

- The wake reads `prequeue-group-gate.yml` runs for heads with a `.group`
  sidecar. One completed group run wakes every member. Return codes are
  unchanged.
- `pq_group_release_sweep` (`bin/lib/mc-prequeue.d/group-release.sh`) runs on
  every conductor tick before the flush. It reads each dispatched group's run
  once, removes the members' backstop-unchanged counters and writes
  `<gid>.released`. It does not enqueue. Each member's READY arm still does
  that.
- THE SHARE RULE (`bin/lib/mc-prequeue.d/group.sh`, knob
  `MC_PREQUEUE_GROUP_SHARE_S`, default 300, 0 = the BH-8327 rule). A head can
  join another run's open group that is younger than the knob. A run that
  joined such a group can dispatch it. A run with no member still abandons
  it.

## Not changed

- `MC_PREQUEUE_FRESH_COMMITS` and the BH-6924 impact reuse. The suite pins
  that a grouped verdict goes through them with 0 new dispatches (R1, R2).

## Check on the hub

    grep 'PREQUEUE group-release' logs/merge-conductor.log
    grep 'prequeue main .* finished — woke' logs/wake-loop.log

Test: `HARNESS_TEST_SANDBOX=1 bash tests/prequeue-group-release.bh-8610-test.sh`.
