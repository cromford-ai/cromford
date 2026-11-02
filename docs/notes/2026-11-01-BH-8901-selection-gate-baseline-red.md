# The selection gate does not count a suite that is red on the base too (BH-8901)

Doc: REMOTE-GATE

## What changed

- `bin/selection-gate.sh` step 6: with `SELECTION_GATE_BASELINE_RUN=1`, each suite
  that is still red after the quarantine and the host notes runs once more on
  the merge base. It uses the same runner on the same host, in a detached
  `git worktree` of the base, under `timeout SELECTION_GATE_BASELINE_TIMEOUT_S`.
  The output is `<out>/baseline-run.txt`.
- A suite with a `FAIL <suite> (rc N)` line on the base, N not 127, moves from
  `red:` to `baseline-red:` and does not fail the gate. If no red is left, the
  gate is `rc: 0`.
- Every other base answer keeps the suite red: `PASS`, rc 127 (the suite is not
  on the base), `BLIND`, no line, or a near-miss name.
- A suite whose own file the diff changes is never sent to the base.
- A base run that could not run keeps every red and caches nothing. That is
  rc 124 or more, the timeout, a `RUNNER-FAILURE` line or no worktree. The
  reason is in `baseline: could-not-run: <why>`. It never becomes
  `baseline-red`, and it never changes `rc:`.
- gate.txt gets two lines after `host-noted:` only when the knob is 1:
  `baseline-red: <list|->` and
  `baseline: <-|skipped: head-is-base|ran <n> on <mb12> (<c> cached)|could-not-run: <why>>`.
  With the knob 0 or unset, gate.txt is the same 10 lines as before.
- `bin/lib/selection-gate.sh`: `_sg_run` passes the three knobs. The
  `SELECTION-GATE rc=` log line ends with ` baseline-red=<n>`. `SG_MARKER` (the
  PR body) gets one sentence after the marker line that names the suites. The
  marker line itself does not change.
- `bin/blocked-resolver.d/bh-8062-selection-gate.sh`: the fix round's verify
  passes the same knobs, so a baseline red does not refuse its push.

## Cache and retention

The base result is cached per box in
`$HARNESS/state/selection-gate/baseline/<base sha>/<suite, / as _>`. A file
holds `red` or `green`, written through a temp file and one rename. A second
build on the same base does not run that suite again. Each base run first
deletes base dirs older than `SELECTION_GATE_BASELINE_KEEP_DAYS` days. On a
pool machine the cache lives only as long as the machine.

## Knobs (fly-pool lane)

- `SELECTION_GATE_BASELINE_RUN`: default 1. 0 is the BH-8062 gate. The script alone,
  with the env unset, falls back to 0.
- `SELECTION_GATE_BASELINE_TIMEOUT_S`: default 900 seconds.
- `SELECTION_GATE_BASELINE_KEEP_DAYS`: default 2 days.

## Test

`tests/selection-gate-baseline.bh-8901-test.sh`.
