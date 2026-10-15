# Lane-run machines run current code; a non-zero run is `failed` (BH-6817)

Doc: PROJECT-LANES, MERGE-CONDUCTOR

## Why

On 2026-10-15 at 01:32Z the first lane-run machine ran a merge-conductor-pr
row with rc 127. `bin/merge-conductor-pr.sh` was not in its image: the image
bakes `bin/` at build time, and nothing rebuilt it after #6763. The row was
stored `done`, so the conductor saw no failure and no alert fired.

## What changed

1. **Code sync on the machine.** `bin/lane-run-worker.sh` sources
   `bin/lib/lane-run-code.sh`. Before a claim, at most once every
   `lane_run.code_check_s` (120, 30..3600), it fetches `main` of the repo
   `fleet.conf` names for `cromford` (depth 1, the machine's GitHub App
   read token in a `GIT_CONFIG_*` header), and compares it with
   `$HARNESS/HARNESS_COMMIT`. On a new commit it stages `bin/`, `catalog/` and
   `fleet.conf` by `git archive` and checks that `bin/lane-run-worker.sh`,
   `bin/project-lane-run.sh` and `bin/jobs-client.sh` exist and pass `bash -n`.
   It composes `catalog/llm-sites.json` and `catalog/context-budgets.json` in
   the stage and keeps any old top-level catalog file the stage lacks. It
   swaps the three paths (bin last), writes `HARNESS_COMMIT` and re-execs the
   worker. The line `code <old12|unknown> -> <new12>`, `code current <sha12>`
   or `code sync failed: <why>` goes to `logs/lane-run-worker.log` and to
   stderr (`flyctl logs -a lane-run`). A failed sync leaves the tree as it
   was, claims on the current code and sends at most one
   `lane-run-code-sync` warn alert per hour.
   Only `fly/lane-run-entrypoint.sh` sets `LANE_RUN_CODE_SYNC=1`. A root with
   `.git` or a populated `builds/` never syncs. The row `lane_run.code_sync=0`
   turns it off.
2. **A non-zero run is `failed`.** D1 still stores `done` + rc (the CHECK of
   `schema.d/0020` allows no `failed`). `POST /api/lane-runs/<id>/report` and
   `GET /api/lane-runs/by-prefix` answer `status: "failed"` for rc != 0, with
   `reason` `command-missing` (rc 126/127) or `exit-nonzero`
   (`worker/jobs/src/lib/lane-run-status.js`). The worker does not start an
   `args[0]` that is not an executable file in its harness: it reports rc 127.
   For rc != 0 the stored prof is `<PROF line|PROF lane-run> rc=<n>
   reason=<r> err=<first non-empty stderr line>` (512 bytes max). A
   command-missing rc sends one `lane-run-command-missing-<lane>` warn alert
   per lane per `lane_run.command_missing_alert_s` (3600) per machine. Stdout
   and stderr now go to `logs/<lane>-cron.log` in that order.
3. **The conductor falls back on `failed`.** `mc_fly_failed_for` reads a
   newest `failed` row as `command-missing` (126/127) or `rc=<n>`, so the
   tick logs `fallback=machine-failed (<word> at <key>)` and runs that PR on
   the hub. A `done` row with rc != 0 still falls back too.
4. **The image carries its commit.** `fly/lane-run.Dockerfile` takes
   `--build-arg HARNESS_COMMIT=$(git rev-parse HEAD)`, labels the image
   `harness.commit` and writes `/opt/harness/HARNESS_COMMIT` (7-40 hex only).
   `bin/lane-fleet.sh` logs `image <id> <ref> digest=<d|-> harness_commit=<c|unknown>`
   once per started machine and digest (`state/lane-fleet/images.tsv`), and
   each start logs `start <id>: machine run image=<lane_fleet.image>` or
   `start <id>: machine start image=<the ref Fly lists for it>`.

## Operator steps

- Rebuild the image once with the build arg above.
- Confirm that the lane-run GitHub App installation can read the harness
  repo. If it cannot, every sync fails and each machine alerts once an hour.
- After the deploy, check that the three `lane_run.*` settings rows exist
  (`bin/harness-sync.sh` applies `schema.d`).
