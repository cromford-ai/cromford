# BH-6374: sibling parts of one split ticket run one at a time when they share a file

Doc: SCHEDULER

What changed: a split ticket's parts (`TK-142.1`, `TK-142.2`, ...) were built
side by side. They are planned against the same contract and often edit the
same files, so the second to merge conflicted and was closed. The fleet pool
spawned a part with no check against its siblings, and
`bin/overlap-schedule.sh` only put a colliding sibling in a later WAVE (advice)
or in UNPLANNED when it had no list.

The rule is now one script, `bin/sibling-serial.sh`:

- A key is a part when it matches `^(.+-[0-9]+)\.([0-9]+)$`. Parts with the
  same parent are siblings. A key that is not a part is never judged.
- For a candidate part K, the first hit wins:
  1. a sibling in flight (any n): K waits when the lists collide, or when K or
     the sibling has no pre-plan list;
  2. a sibling with an open PR (branch `(^|/)<sibling>($|[-/])`): K waits when
     its list names a file the PR changed (exact match);
  3. a lower-n sibling queued: K waits when both lists exist and collide.
- Lists are pruned as `bin/overlap-schedule.sh` prunes them (SOURCE: header,
  same-list bare directory, OVERLAP_IGNORE, read-mostly). One shared path is
  enough; there is no Jaccard threshold.

Where it acts:

- `bin/fly-pool.sh:pool_spawn_decision` gate 0c runs
  `bin/sibling-serial.sh check <p> <KEY>`. On rc 3 the row stays queued (no
  QROW write, no deferral count, no alert) and `logs/fly-pool.log` gets
  `SIBLING_SERIAL <K> waits for <S> on <file> — no machine spawned; re-checked next tick`.
  The reuse handoff (`next_job_or_destroy`) calls the same function.
- `bin/overlap-schedule.sh` runs `decide` over its own ROWS / INFLIGHT / PRS
  and prints `HELD: <K> waits for sibling <S> on <file> (SIBLING_SERIAL)`. A
  verdict that is only an open sibling PR is not held while STACKED_BUILDS is
  on: the existing STACK line places it on that PR's branch.

State: `state/sibling-serial/<p>/<K>.sibling-since` (box-local, catalog/state-paths.json) holds `<S><TAB><epoch>[<TAB>released]`,
the wait clock. At `SIBLING_SERIAL_MAX_MIN` (360) the key is released, the
pool log says `SIBLING_SERIAL_RELEASED <K> after <m> min behind <S>`, and one
warn alert goes through `bin/alert-line.sh` per (key, blocker). A go removes
the file.

Knobs (lib `sibling-serial`, `catalog/lanes.d/_lib.sibling-serial.json`):
`SIBLING_SERIAL=1` (0 = off), `SIBLING_QUEUED_MAX_MIN=120` (a queued sibling
older than this holds nobody; 0 = a queued sibling never holds),
`SIBLING_SERIAL_MAX_MIN=360` (0 = no ceiling). `lane_switch sibling-serial-off`
is the same kill switch.

Fallback rate (how often a part waits only because a list is missing):

```
grep -c 'SIBLING_SERIAL .* on (no pre-plan list)' /root/harness/logs/fly-pool.log
grep -c 'SIBLING_SERIAL .* waits for .* on [^(]' /root/harness/logs/fly-pool.log
```

Not in this change (slice C1 of BH-6374): the pool building a part stacked on
its sibling's PR branch, the merge of a stacked child whose base was
squash-merged (scope item 5, A6), the "Part of #N" children, and the replay
over the last 30 split parents.
