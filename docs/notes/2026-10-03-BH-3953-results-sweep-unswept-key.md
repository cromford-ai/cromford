# The results sweep reads the newest result first, and a held sweep keeps no stamp (BH-3953)

Doc: TRIAGE-STATE, ALERTS-STATE-MACHINE

## What changed

- `bin/lib/rt/scope.sh`: the results-sweep (and remote-results-pending) reading
  list `RDIRS` comes from the new `rt_unswept_dirs`. It lists every
  `builds/<p>-*/` and `builds/pool-<p>-*/` dir with a RESULT and no COMMENTED as
  `<dir> :: <first RESULT line>`, newest RESULT mtime first, still capped at 30.
  It used to be glob (name) order cut at 30.
- `bin/lib/rt/gate.sh`: when the triage precondition (the throttle) holds a
  `RUN results-sweep`, the tick deletes `state/<p>.sweepfp` before it exits.
  `bin/triage-gate.sh` step 3 still writes the stamp when it prints the RUN; the
  hold now undoes it, so the next tick asks again instead of reading the set as
  swept for 45 minutes. Other held decisions leave `sweepfp` alone.
- `bin/lib/closeout-overdue.sh` (new), called from `bin/orphan-reconcile.sh` at
  its `awaiting-closeout` skip: when the key's oldest un-commented RESULT is older
  than `CLOSEOUT_OVERDUE_S` (default 2700 s; non-numeric means 2700, below 600
  means 600), it sends one `bin/lane-alert.sh --id closeout-overdue:<p>:<KEY>
  --severity warn pipeline-health` line naming the key, the dir, its RESULT and
  the un-commented dir count. lane-alert's id state machine sends it once and
  counts repeats. GitHub-Issues boards only, because orphan-reconcile is.
- Knob template `env-templates/lanes/376-closeout-overdue.env.example`.

## Why

BH-3859 on box-small, 2026-10-03: a pool REVIEW_BLOCKED result was
staged at 15:33Z as `cromford-BH-3859-remote<ts>/`. That tick's sweep was
held by the throttle with its stamp already written. The 16:03Z sweep bought
shards for the lowest-named keys, and BH-3859 was not in the 30-line list at
all. orphan-reconcile logged `skipped=BH-3859:awaiting-closeout` every tick and
nothing alerted until a human posted the finding at 16:04Z.

Older un-commented dirs past the cap now wait instead. pipeline-health check 4
still counts them per project, and the new warn names each open orphan.

Pinned by `tests/results-sweep-unswept-key.bh-3953-test.sh` and
`tests/orphan-reconcile-test.sh` §6.
