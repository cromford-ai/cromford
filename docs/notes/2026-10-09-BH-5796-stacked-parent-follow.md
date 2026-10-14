# A stacked child follows its moving parent; a conflicting head is not reviewed (BH-5796)

Doc: MERGE-CONDUCTOR

## What happened

- 14 review BLOCKs: a parent ticket branch was rebuilt or fixed while its stacked
  child waited, and the child kept the old parent commits (#5535, #5097, #4761, #4747).
  BH-5519 merged the parent into a child only when GitHub listed the child DIRTY.
- 8 review BLOCKs: main rewrote lines a PR also changed, the PR went DIRTY, and the
  lead review was requested anyway (#5693, #5395, #5140, #5138).

## What changed

1. **The conductor follows a moving parent.** In the stacked block's OPEN-parent arm,
   `mc_stack_parent_moved` (bin/lib/mc/rebase.sh) fetches the parent and child
   branches and asks whether the parent's tip is in the child's history. When it is
   not, the BH-5519 parent merge runs (`mc_rebase ... <parent-branch>`), DIRTY or not,
   once per (child head, parent tip), on the rebase budget. Log line:
   `STACK_PARENT_MOVED <new8>: merged the new tip <tip8> of <parent>`.
   Knob `MC_STACK_PARENT_FOLLOW` (1). `MC_STACK_PARENT_MERGE=0` still turns every
   parent merge off.
2. **A conflict is a fix round.** A parent merge that conflicts parks the child
   `conflict-unresolvable: stacked child of <parent> ...`. It used to stay STACKED_WAIT.
3. **The resolver merges the stacked base.** For a PR whose base is not main, the
   mechanical rung and the fix round merge `origin/<base>`, not `origin/main`, and the
   round's own-commit set excludes the base's commits (guard, noop and author gates).
4. **The fix round re-renders generated files last.** A rebase-conflict round runs the
   repo's "Generated files" table (`mc_regen_generated`, read from the merged base)
   over its tree under the round's author pin, before the verification.
5. **The enqueue holds a conflicting head.** `bin/lead-review-enqueue.sh` does not ask
   for a lead review when the conductor has the head NEEDS_REBASE, REBASING or parked
   conflict-unresolvable, or when `git merge-tree` on the hub clone names conflicted
   paths against the base. Counter `skipped_rebase`, knob `LEAD_REVIEW_REBASE_HOLD` (1).

## Relation to BH-5234 (#5282)

BH-5234 handles the parent that was REWRITTEN and then lands: it restacks the child by
patch-id, refuses a rewrite push to a branch with open children, and pages
`staleparent`. This change handles the parent that moves while it is still OPEN, by a
merge (never a rewrite of the child), so it never trips BH-5234's rewrite guard. A
child that took a parent merge here still restacks cleanly when the parent lands:
BH-5234's replay drops sync merges and replays only the child's own commits.
