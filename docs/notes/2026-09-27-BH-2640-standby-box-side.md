# Standby box side: heartbeat POST and verify lane (BH-2640, part of #2519)

Doc: RESTORE

## What changed

- **`bin/standby-heartbeat.sh <of> <snapshot> <rc>`** (new). It POSTs
  `{box, of, snapshot, ok}` to the hub's `/api/hub/standby/heartbeat` through
  the jobs client. `box` comes from `bin/box-name.sh`, the same way the
  watchdog report gets `<self>`. It prints one line (`recorded`,
  `failed (HTTP n, fail-open)` or `skipped: <why>`) and always exits 0. A skip
  makes no request. A failure writes no ALERTS line.
- **`bin/state-restore.sh --standby`**: `standby_finish` calls the heartbeat
  after the watchdog block, which is unchanged. The exit code is unchanged. A
  refusal before the EXIT trap sends neither report.
- **`bin/standby-verify.sh`** (new lane, `catalog/lanes.d/standby-verify.json`).
  It claims one `standby_verify_runs` row for this box
  (`POST /api/hub/standby/verify/claim {claimer}`), dry-runs
  `state-restore.sh <of_hub> latest` into a `/tmp` scratch dir (never
  `--apply`, never `--standby`), judges it with restore-lab's four rules and
  posts `POST /api/hub/standby/verify/<id>/result`. A result that is not
  recorded is exit 1 plus one ALERTS line. A claim that fails (a 404 before
  the worker routes deploy) is exit 0, one log line, no ALERTS line.
  Knobs: `STANDBY_VERIFY_TIMEOUT_S` (1500 s) and `STANDBY_VERIFY_TMPDIR`
  (a path, not settable).
- **`bin/standby-install.sh`** prints the verify line
  `*/5 * * * * root …/hub-lease.sh check || …/standby-verify.sh >> …/logs/standby-verify.log 2>&1`
  immediately before the stream line. The stream line stays last.

## Why no cron file

The lane registers with `boxes: []`, so `bin/render-cron.sh` renders it on no
box. Only the standby installer runs it, behind `hub-lease.sh check ||`, so it
goes inert once the standby holds the lease.

## Operator step

Standbys installed before this change need `bin/standby-install.sh <box> --apply`
re-run to get the verify line. The heartbeat needs nothing: it rides the
existing stream line. Both are inert until the worker's standby routes deploy
(the heartbeat fails open, the claim gets a 404).
