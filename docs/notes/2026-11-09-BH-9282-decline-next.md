# BH-9282 — no dead end after a declined supersede on a red reviewed PR

## Problem

project-6 #3661 (2026-11-08): a lead MERGE-WITH-NOTES verdict, CI red, fix=1/1
on an older head. Rung rebuild-fresh was declined on the verdict, and the
BH-9029 decline mark then skipped the row on every tick. #3608 had the same
shape with a BLOCK verdict (row 5317). No step made a decision after that.

Root cause: `bdm_skip` (bh-9029-decline-mark.sh) returned 0 for any standing
mark and did not ask if an action was available. The BH-7660 per-head reset
runs only inside `br_rebuild_fresh` after the supersede guard, so a verdict
decline never reset the old head's fix-round count for the new head.

## Change

`bin/blocked-resolver.d/bh-9282-decline-next.sh`:

- `bdn_next` (asked by `bdm_skip` before its SKIP line). A fix round runs when
  the reason's action is `ladder`, `mc_ci_state` says `red` on the PR head, and
  the fix rounds on this head are below `br_fix_cap`. When the last counted
  rung ran on another head, `br_head_reset` resets the counters first. There
  is no reset on a legacy record (no `rung_head`), on a head the ladder was
  already reset to, or on the head this lane's own fix round pushed
  (`fix_head`). The last rule stops one paid round per push.
- `bdn_ladder` (one line in `br_one`) turns the ladder's mechanical, regen or
  rebuild-fresh answer into fix-round for the admitted row. It sits in front of
  `br_rung_hold_gate`, so a held ticket spends nothing.
- `bdn_brief` (one line in `br_fix_round`). A BLOCK or CHANGES_REQUESTED head
  gets the newest trusted `<!-- lead-review:` review on that head, framed with
  `BR_LEAD_HDR`, so the BH-2200 lead gate applies. A failed reviews read is
  rc 75: no rung spent.
- `bdn_human`. The budget on this head is spent and CI is still red
  `BR_DECLINE_HUMAN_HOURS` (default 12) after the first sighting: one
  needs-human comment per (ticket, head). The marker is written first. A
  GitHub-issues lane posts on the ticket issue; no ticket key posts on the PR;
  a product board gets one NEEDS_HUMAN lane alert and no board comment. A
  failed post is one lane alert.

Rebuild-fresh stays declined for a reviewed head. `br_supersede_guard` is not
changed.

## Check

`tests/blocked-resolver-decline-next.bh-9282-test.sh`. On the hub:
`grep 'DECLINE NEXT' logs/blocked-resolver.log`.
