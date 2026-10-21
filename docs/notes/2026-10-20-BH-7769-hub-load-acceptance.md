# Hub load acceptance verdict: `bin/hub-load-report.sh --acceptance` (BH-7769)

Doc: OPERATING

## What changed

`bin/hub-load-report.sh` (BH-7397 C0) printed the hub numbers, but a person had
to read six lines and decide if the acceptance of #7397 held. The new flag
`--acceptance` adds one seventh line and makes the exit code the verdict:

```
acceptance load_p90_le_cap=<v> conductor_ticks_in_window=<v> window_deferred_zero=<v> verdict=<v>
```

Each value is `pass`, `fail` or `NA`:

| value | NA when | pass when | fail when |
|---|---|---|---|
| `load_p90_le_cap` | no hub-load sample in the window | runnable p90 <= cap | runnable p90 > cap |
| `conductor_ticks_in_window` | no `logs/merge-conductor.log`, or 0 TICK lines in the window | `over_window=0` | `over_window` > 0 |
| `window_deferred_zero` | no log, or 0 TICK lines and 0 FANIN runs in the window | `window_deferred_lines=0` and `deferred_runs=0` | any WINDOW_DEFERRED line or `deferred:window` run |
| `verdict` | no value fails and one is NA | every value passes | any value fails |

Exit code with the flag: 0 pass, 1 fail, 3 NA. A bad flag is still rc 2.
Without the flag the six lines and rc 0 do not change by one byte, so
`bin/hub-move.sh proof` (BH-7715, when it merges) is not affected.

A 0 with no conductor activity is NA, not pass: an empty window proves nothing.

## How to use it (on the hub)

1. Run the live verdict for the last hour:
   `/root/harness/bin/hub-load-report.sh --acceptance; echo rc=$?`
2. Run the launch-day replay:
   `/root/harness/bin/hub-load-report.sh --acceptance --since 2026-10-18T16:00:00Z --until 2026-10-18T17:00:00Z; echo rc=$?`

"0 WINDOW_DEFERRED while PRs are approved and green" counts every
WINDOW_DEFERRED line and every `deferred:window` run in the window. The log
does not carry approval or CI state, and `mc_window_defer` fires only for
conductor candidate rows, so this is the strict reading the log supports.

## Not measured here

The verdict itself was not taken by this build. The build ran on a pool
machine with no `state/hub-load/`, no `logs/merge-conductor.log` and no
`logs/fly-pool.log`. The hub operator runs the two commands above.

## Item 1 of #7769: move pool scheduling off the hub, or batch it

Not in this change. It has owners:

- The batch half is on main: a1cca5b5 (one open-PR list read per tick),
  BH-6549 (one hold listing per tick, held verdicts cached across ticks),
  BH-7421 (per-tick budget), BH-7475 (stop at a row boundary), BH-7491
  (bounded wait per project tick), BH-7509 (`POOL_TICK_MAX_PARALLEL` and the
  load shed).
- The move half is open work: BH-7516 (lane-run image for pool ticks on Fly),
  BH-7636 / #7662 (placement `box:<name>` for the conductor and the fly-pool
  tick), BH-7706 / #7772 (one decision pass, parallel spawns), BH-7715 / #7757
  and BH-7716 / #7763 (the hub and the conductor on bigger machines).

Tests: `tests/hub-load-report-acceptance.bh-7769-test.sh`.
