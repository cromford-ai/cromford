# BH-10060: the fleet-status counters use their detectors' filters (slice C0)

Doc: WATCHDOG-SPEC

## Cause

`bin/fleet-status-push.sh` `fsp_project_row` counted two numbers by a looser
rule than the detectors they summarise.

- `remote_results_pending` tested only RELAYED, the 30-minute age and the
  rr-consumed row. The staleremote detector in `bin/pipeline-health.sh` also
  skips a json the retention rule retired, a json whose own result line proves
  a settled PR older than `STALEREMOTE_PR_SETTLED_DAYS`, and a folderless json
  it cached as ledger-terminal. The counter counted all three.
- `queue_depth` and `oldest_queued_min` removed held keys and `*.failed.json`
  parks (BH-1461). They did not remove the keys the pool's push-rejected
  terminal gate skips every tick. A terminal key counted and aged forever.

## Change

- The counter sources `bin/lib/remote-results-ledger.sh` and applies the
  detector's three no-read filters, in the detector's order. It reads the
  detector's cache `state/remote-results-terminal/<p>.tsv` and makes no ledger
  read. It lags the detector by one pipeline-health tick at most.
- The settled window is the pipeline-health knob
  `STALEREMOTE_PR_SETTLED_DAYS`, read once per run (env, then `lane_knob`,
  then the fallback 7). One value for the counter and the detector.
- `pool_terminal_key` applies the rule of `bin/fly-pool.sh`
  `pool_terminal_check`. With `pool_state_rows` on and the worker answered,
  an active row is terminal, and a row cleared at or after the file's verdict
  makes the file stale. No row, or no answer: the `.terminal` file decides.
  It reuses the `psr_load` snapshot; there is no second GET.
- Terminal keys are out of `queue_depth` and `oldest_queued_min` and are
  counted in a new `.projects[<p>].terminal` field.

## Plan deviation

The plan's case Q5 said a DB answer with no terminal row wins over a
`.terminal` file. The pool gate does the opposite: no row, the file decides.
The build follows the pool gate. The test pins both: a row cleared after the
file's verdict counts (Q5), and a file with no row is terminal (Q7).

## Test

`tests/counters-true.bh-10060-test.sh`: 26 assertions, R1-R10, P1, Q1-Q7,
X1, K1. Red at HEAD c48f2967: 19 fail.
