# The resolver does not close a PR with no rung counted since the head reset (BH-8328)

Doc: MERGE-CONDUCTOR

## Problem

`bin/blocked-resolver.sh` closed example-org/project-6#2606 at 2026-10-25
18:02:58Z as ABANDONED. Its close comment said "Rungs counted since the last
head reset: mechanical 0, regenerate 0, fix round 0 ... Attempts that could not
start (not counted): 0".

The sequence:

1. A person pushed a new head. `br_head_gate` reset the ladder to it.
2. The hub queued a fix round (`head-not-reapproved`). On the owning box,
   `br_fix_round` found nothing to brief. It recorded no attempt and answered
   `FIX_RESULT terminal`.
3. The hub adopted the terminal under the park's current reason,
   `review-changes-requested` (a lead BLOCK now stood on the new head).
4. `br_cap_notes` found an ALWAYS-BLOCK line, so `br_abandon` ran.
5. `br_head_gate` let the close go: the head was the head the ladder was
   already reset to. Its no-real-rung guard needs a `-blocked` attempt, and
   step 2 wrote none.

## What changed

All new logic is in `bin/blocked-resolver.d/bh-8328-zero-rung.sh`. The driver
has two call-site lines, and `br_close_facts` reads the new counter.

1. **Nothing to brief is "could not start".** `br_fix_round`'s
   nothing-to-brief branch calls `zr_nobrief`. It writes one
   `fix-round-blocked` attempt (detail starts `nothing to brief`, head and url
   stamped, no counter). A second one on the same head is not written. On a
   box, the attempt goes back to the hub in `FIX_RECORD`. `FIX_RESULT` is still
   `terminal`.
2. **The zero-rung gate.** `br_abandon` calls `zr_close_gate` before
   `br_head_gate`. For a fix-round park (`review-changes-requested`, and
   `orphaned-child` with `BR_LADDER=0`), the close is refused (rc 5) when the
   per-head fix count is 0, or when the newest real attempt is a
   nothing-to-brief round. The count is `zr_counts`: the record's counters,
   with the fix count from `br_cap_rows` (the count `br_fix_round`'s cap uses).
   The next tick offers the park again, and its fix round reads the newest
   lead review on the head (`br_findings`). The record keeps
   `zero_rung {head, n, alerted}`. After `BR_ZERO_RUNG_REBRIEFS` refusals on
   one head (default 1), the next refusal sends ONE alert,
   `lane-alert.sh --id br-zero-rung:<project>:<cap-key>:<head12>`, that starts
   `NEEDS_HUMAN:`. The PR stays open. A ladder reason (red-twice and kin) is
   not gated here: its rebuild cap is ticket-wide.
3. **The human-push defer.** On a head the ladder was reset to
   (`ladder_reset.to`), with no counted rung on it and not this lane's own fix
   push, `zr_close_gate` reads the head commit once. If its author is not a
   `[bot]` App (or no account is linked) and the committer date is less than
   `BR_HUMAN_PUSH_SETTLE_SECS` ago (default 1800, 0 = off), the close waits
   (rc 5, nothing written). An unreadable date also waits. A failed read is
   rc 75. A head that `br_head_gate` has not reset yet is not read: the gate
   resets it first, as before.
4. **The close comment.** `br_close_facts` prints the `zr_counts` numbers, so
   the comment and the decision use one count.

## Knobs

- `BR_ZERO_RUNG_REBRIEFS` (`catalog/lanes.d/blocked-resolver.knobs.d/`,
  settings row `lane.blocked-resolver.BR_ZERO_RUNG_REBRIEFS`): default 1.
- `BR_HUMAN_PUSH_SETTLE_SECS` (same directory): default 1800 s, 0 = off.

`BR_OPT_OFF=bh-8328-zero-rung` turns all of it off.

## Operator check

`grep -E 'ZERO-RUNG GATE|HUMAN-PUSH DEFER' logs/blocked-resolver.log` on the
hub. A review park with 0 fix rounds counted must have no `ABANDONED` line
after its refusal line.

## Test

`tests/blocked-resolver-zero-rung.bh-8328-test.sh`: the project-6 replay
through a whole hub tick (Z1, Z1n), the box's `--fix-here` record (Z6), two
real rounds still abandon (Z7), an unclaimed round counts nothing (Z8), and
the gate's decision table on the real `bin/lib/br` modules.
