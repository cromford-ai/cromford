# BH-6374 C1: sibling parts by board key, pool stacking, squash-base merge, replay

Doc: SCHEDULER, MERGE-CONDUCTOR

This note follows `2026-10-13-BH-6374-sibling-serial.md` (C0). C0 knew a part
only by a dotted key (`TK-142.2`). A split child never has one: the decomposer
writes `TK-145.1: ...` as the title label, and the board gives the child its own
key (`TK-184`). So C0 judged no real part. In project-6-os, every part was let
through.

What changed:

- **Parts by board key.** `bin/sibling-serial.sh parts <project>` prints
  `key<TAB>parent<TAB>n` for every child in a `DECOMPOSED k0,k1,...` line 1 of
  `builds/<p>-*/RESULT` or `builds/pool-<p>-*/RESULT`. These are the same
  records `bin/lib/split-chain.sh` reads. The list is in land order, so n is
  the 0-based index (0 = the contract). The record must be younger than
  `SIBLING_PARTS_LOOKBACK_D` days (14). A key in two records takes the newer
  one. The dotted key stays a fallback for a key in no record.
- **decide reads the map** as an optional 4th file. An open PR belongs to
  sibling S when its branch matches `(^|/)<s>($|[-/])`, so `ticket/TK-184`,
  `ticket/TK-184-r2` and `agent/TK-184` are TK-184's. `check` and
  `bin/overlap-schedule.sh` pass the map.
- **The pool stacks.** When `check` answers ` stackable base=<branch>` (one
  open sibling PR is the only blocker) and the queue row has no `stack_base`,
  `bin/fly-pool.sh` gate 0c requeues the row once with `stack_base=<branch>`.
  The row keeps its attempt, counts and hotfix flag. `logs/fly-pool.log` gets
  `SIBLING_SERIAL <K> stacks on <branch> (open PR of <S>) — requeued with stack_base; spawns next tick`.
  The next tick builds it on the BH-1174 STACK path. `check` skips the PR the
  row stacks on (env `SIBLING_STACK_BASE`). `SIBLING_STACK=0` turns the
  stackable suffix off, and the pool then waits as in C0.
- **Squash-base merge** (scope item 5, A6). `mc_resolve_squash_base` in
  `bin/lib/mc/rebase.sh` runs in `mc_resolve_conflicts` before the
  `package.json` / `*.md` / real-conflict arms. It acts only on an add/add
  path. Its base A is the oldest commit on `MERGE_HEAD` since the merge base
  that added the path (after a squash merge, the squash commit). It acts only
  when a branch commit since the merge base has A's exact blob. Then it runs
  `git merge-file -p <branch> <A:path> <main>`. A clean result is staged, and
  the merge message gets `Union-resolved: <path> (squash base <sha8>, BH-6374)`.
  That trailer makes `mc_rebase` re-review the merged head. It never rebinds
  the approval. Every other case stays a real conflict.
  `MC_SQUASH_BASE_MERGE=0` (merge-conductor lane) turns it off. The conductor
  rebase and the pool rebase job both use it.
- **Replay.** `bin/sibling-serial.sh replay` runs the rule over each parent's
  parts and prints the order it gives. It writes nothing. It skips n 0. Each
  tick takes the waiting parts in n order and runs decide for each against the
  parts in flight, the ones let go this tick included. A tick that lets nothing
  go closes the wave.

Run the replay on a hub box (post-merge checklist, ticket #6374):

```
bin/sibling-serial.sh replay --project project-6-os --last 30
bin/sibling-serial.sh replay --project cromford --last 30
bin/sibling-serial.sh replay --project project-5 --last 30
```

Output, one line per parent and one total:

```
REPLAY <parent> parts=<n> waves=<w> order=<k,k> > <k> ... nolist=<n> added_cycles=<w-1>
REPLAY_TOTAL parents=<n> parts=<n> nolist_waits=<n> fallback_pct=<p>
```

`added_cycles` is the number of serial build cycles the rule adds. It is not
minutes: the records hold no build durations. `nolist` counts the parts that
waited at least once only because a list was missing. If `fallback_pct` is
high, the pre-plan step is missing data. That is a finding, not a pass.

A part of a parent whose record is not on this box is not judged by the pool.
`bin/plan-sibling.sh` still checks it at plan time.
