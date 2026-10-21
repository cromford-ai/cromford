# BH-7803: the remote-results consumer cursor as ledger rows

Slice C0 of #7803 (the C3 slice of #4157: "`state/remote-results/` to DB rows").

## What changed

`state/remote-results/<project>/` holds the cursor that stops one remote build from being staged twice.
The files live on one box. A rebuilt or restored box had none of them, and its first tick re-staged every
close-out the 50-row feed window still held.

`bin/lib/rr-cursor.sh` now writes each part of the cursor as a `ledgers` row too:

| Kind | Key | Status | Detail | File it mirrors |
|---|---|---|---|---|
| `rr-handled` | `<project>/<job_id>` | `staged` | `{key, dest, box}` | `.handled/<job_id>.job` |
| `rr-since` | `<project>` | `at` | the watermark | `.since` |
| `rr-consumed` | `<project>/<KEY>@<build-id>` | `staged`, `duplicate`, `empty`, `badjson` | the relay json, cut to 3500 bytes | `.handled/<KEY>.json[.empty\|.badjson]` |

`<build-id>` is the json's `build_dir` basename, else `machine_build_dir`, else the first 16 hex of the
file's sha256. A `badjson` file takes its KEY from the file name.

## Read and write order

- Readers (`rt_stage` and `bin/triage-gate.sh` section 3b) read the file first. Only a missing file asks the
  row. A row that answers writes the file back.
- Writers do the file op first. Its rc is the function's rc. Then they PUT the row. A failed PUT writes one
  `rr-cursor: <kind> row NOT written for <id> (the file marker stands)` line to `logs/<project>.log`. It does
  not set the `RRFAILED` watermark freeze.
- No client (`job_ledger_row` / `job_ledger_put` not in scope) is the file-only behaviour exactly.
- An unreadable row with no file reads "not handled". That is the answer a missing file gave before.
- A project or job id outside `[A-Za-z0-9._-]`, or `.` / `..`, is refused (rc 1, nothing written).

## Retention

`rr-since` is one row per project. `rr-handled` and `rr-consumed` grow at one row per remote build, the same
rate the `.handled/` files grow. `ledgers` rows are not deleted on purpose (a deleted row reads "not done").
[NOTE] candidate: add both kinds to the BH-6774 archive list. An archived row still reads as present.

## Left for C1 of #7803

- Move the relay `<KEY>.json` writers (`bin/fly-pool.sh`, `bin/fly-results-ingest.sh`) to a row, and its
  readers (triage-gate section 1, fleet-status-push, pipeline-health, fleet-slo, builds-retention, the
  staging relay loop) to read it. Update the `remote-results` row of `catalog/state-paths.json`.
- After this slice has run in prod, retire the cursor's file writers and delete the old markers.
