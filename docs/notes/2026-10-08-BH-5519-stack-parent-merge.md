# A stacked child merges its open parent branch (BH-5519)

Doc: MERGE-CONDUCTOR

## What changed

The ticket asks for a model-free "merge main" lane. Most of it was already in
main as the merge conductor. One item was missing: "Stacked PRs merge their
PARENT branch, not main."

Before this change, a stacked child (base = an OPEN parent's branch) that
GitHub listed DIRTY was parked `STACKED_WAIT`. `mc_classify` returns
`STACKED_WAIT` before its DIRTY clause, and `mc_rebase` could only merge
`origin/main`. Nothing merged the parent into the child until the parent
merged and `mc_stack_follow` restacked it.

Now:

- `mc_rebase` takes an optional 6th argument `<base>` (default `main`). The
  seven existing callers pass 5 arguments and are unchanged.
- With a base other than main, the fetch, the merge, the vmap clean-merge
  repair and the regenerate read `origin/<base>`. A pushed parent merge
  answers rc 5 and the approval is NOT rebound, because the PR's diff is read
  against a parent that just moved.
- Under `REBASE_ON_POOL`, a parent merge answers rc 3 and logs
  `stacked parent merge … is not a pool job`. The pool job merges main only.
- The `OPEN*` arm of the stacked block in `bin/merge-conductor.sh` calls
  `mc_rebase … "$BASEREF"` when: actions are on, `MC_STACK_PARENT_MERGE` is
  not 0, the head is in the same repo, the child is DIRTY or CONFLICTING, this
  head has no `stackmerge <key> <head>` attempt, and the rebase budget has
  room. The attempt is recorded before the merge.
- Log lines: `STACK_PARENT_MERGED <sha8> from <parent>`,
  `STACK_PARENT_CONFLICT <files>`, or `not merged this tick (rc N)`. The row
  stays `STACKED_WAIT`, and its reason names the merge or the conflict.
- A conflict is NOT parked `BLOCKED_HUMAN`. The fix round merges
  `origin/main`, which is wrong for a stacked child. When the parent merges,
  `mc_stack_follow` restacks the child and hands a conflict to the fix round.
- New knob `MC_STACK_PARENT_MERGE` (int, default 1, 0 = off) in
  `catalog/lanes.d/merge-conductor.json`.

## The ticket items that were already in main

| Ticket item | Where |
|---|---|
| Event-driven on a main push, plus a periodic sweep | `MC_LAND_REBASE` fan-out in `bin/merge-conductor.sh`, `land_rebase_arm` in `bin/lib/mc/rebase.sh` |
| Plain merge, never a rebase or a force push | `mc_rebase` (`git merge --no-edit`, push through `hold_push` with a lease) |
| Append-only add/add keeps both sides, base first | `mc_resolve_append_union` (BH-4641) |
| Generated files are regenerated | `mc_resolve_generated`, `mc_regen_generated` (BH-969, BH-1162) |
| Gates before the push | typecheck + unit in `mc_rebase` when `node_modules` exists; CI on the pushed head |
| Unresolvable conflict goes to the fix round with the hunks | `rebase_result` rc 1 → `BLOCKED_HUMAN conflict-unresolvable`; `bin/blocked-resolver.sh` puts the marker hunks in the brief |
| Patch-same keeps the verdict; a resolved merge gets a re-review | clean merge rebinds; union-resolved merge returns rc 5 |
| Knobs as DB rows | `MC_LAND_REBASE`, `MC_UNION_FILES`, `MC_REBASE_BUDGET`, and now `MC_STACK_PARENT_MERGE` |

## Check it

```bash
grep -E 'STACK_PARENT_(MERGED|CONFLICT)' /root/harness/logs/merge-conductor.log
HARNESS_TEST_SANDBOX=1 bash tests/mc-stack-parent-merge.bh-5519-test.sh
```
