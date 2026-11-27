# BH-10274: triage shard runner fault (2026-11-26)

## What happened

At 11:28Z eight project-3 triage shards ended `codex rc=1`. Each ticket waited a
whole tick. The console run summary showed only the last stack frames.

## Cause (from the code)

1. `bin/triage-shard.sh` called `bin/agent-call.sh triage ...` once. The shard
   exports `RUNNER_TRIAGE=$SHARD_RUNNER`. It had no retry of its own: a nonzero
   exit only re-armed the ticket and wrote an ALERTS line.
2. `bin/agent-call.sh:4864` fails over only when `"$FALLBACK" != "$RUNNER"`.
   `bin/bootstrap-machine.sh:302-303` writes `RUNNER_TRIAGE_FALLBACK=codex`
   into every box's `global.env`. On a box whose triage runner is codex, the
   fallback is also codex, so a codex crash ends the stage at rc 1 with no
   second rung.
3. When claude was the primary and codex the fallback, `$OUT.runner` records
   the last rung (codex). The console then shows `codex rc=1` although claude
   also failed.
4. The summary used `tail -3 "$OUT"`. On a codex failure `$OUT` is the events
   plus `$OUT.err`, so the last 3 lines are Node `at ...` frames. The
   `Error: ...` line above them was lost.

The literal 11:28Z codex error line is in `logs/project-3.triage-*.out(.err)` on
box-project-3-1. The build machine cannot read that box's logs, so this note
does not quote it. Not verified here: the literal error text. After this
change, the next fault prints its first error line in the ALERTS line and in
the console summary.

`bin/agent-call.sh` is not changed. The `FALLBACK == RUNNER` case applies to
every stage; a change there is a separate ticket.

## Fix

- `bin/lib/runner-fault.sh` (new): `rf_start_fault`, `rf_first_error`,
  `rf_other_runner`, `rf_fault_line`.
- `bin/triage-shard.sh`: after a runner fault before the model answered
  (rc 1/126/127, within `TRIAGE_SHARD_FAULT_S`, no `DECISION:` or `tickets=`
  text), the shard retries once on the other runner. The retry is pinned with
  `AGENT_CALL_RUNNERS=<runner>` (no survival rungs) and uses the same
  call-guard fingerprint (K=2 for `triage-shard`). A retry refused before the
  call keeps the first rc and never parks the ticket.
- One ALERTS line per shard of a new family:
  `[<project>/<KEY>] TRIAGE RUNNER FAULT: <runner> rc=<n> before the model answered (<s>s): <first error line> — <retry outcome>[ — ticket put back in scope]`.
  It replaces the generic `triage shard exited rc=` line for a fault.
  It is written through `bin/alert-line.sh`, which stamps it and notes the
  alert row at once.
- A failed shard's summary (log line and console beat) is
  `error: <first error line>`. An rc 0 summary is unchanged.

## Knobs (`catalog/lanes.d/run-triage.knobs.d/`)

| Env | Default | Meaning |
|---|---|---|
| `TRIAGE_SHARD_FAULT_RETRY` | 1 | 0 = no retry |
| `TRIAGE_SHARD_FAULT_S` | 120 | max seconds for a start fault |
| `TRIAGE_SHARD_RETRY_RUNNER` | "" | retry runner; empty = claude, or codex for a claude failure |
| `TRIAGE_SHARD_ERR_LINE_MAX` | 300 | cut length of the error line |

Test: `tests/triage-shard-runner-fault.bh-10274-test.sh`.
