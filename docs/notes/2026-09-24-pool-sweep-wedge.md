# A held sweep no longer hides the board, and a deferral or an answered stub owes no close-out

Doc: RUN-BUILD-GRAPH

## What changed

- **`bin/triage-gate.sh` step 3 falls through on `sweep-unchanged`.** The
  results-sweep cost brake used to `exit`, so while ANY result stayed
  un-commented the daily safety net (step 4) and the board diff (steps 5-6)
  never ran. It now only stops the gate buying the same sweep twice; a changed
  board still answers `RUN board-changed`, an overdue daily net `RUN
  daily-sweep`. A tick where nothing else fires still prints `SKIP
  sweep-unchanged`, byte for byte.
- **`bin/lib/rt/staging.sh` marks what nobody will close out** (`RR_NO_CLOSEOUT`,
  both the relay and the ledger loop). A staged `BUILD_DEFERRED` gets the
  pool's `DEFERRED` sentinel plus `COMMENTED` (the SOP's answer to a deferral
  is "nothing"). Staging any result for KEY writes `COMMENTED` into this box's
  older `QUEUED_FLY KEY` stubs — never a newer stub, never another key.

## Why

2026-09-23 19:03Z → 2026-09-24: the pool's account-exhaustion loop parked ~250
`BUILD_DEFERRED ... RUNNER_EXHAUSTED` results in the ledger. box-small
staged each as a `-remote` dir, and ~45 `QUEUED_FLY` stubs were answered by
ledger results that bin/queued-fly-relayed.sh cannot see. With ~300 dirs no
session would close, every cromford tick read `results-sweep` or
`sweep-unchanged`: no board-changed session for 16h, a `run_triage` command
answered with a skip, and bin/orphan-reconcile.sh skipping 21 tickets as
`awaiting-closeout`. 38 open ai-build issues, no builds.

## Test

`tests/sweep-wedge.pool-doctor-test.sh` (red on main: 8 failures).
