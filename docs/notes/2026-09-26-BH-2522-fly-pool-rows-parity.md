# Pool assignments become machines rows: parity, the flip, no more ssh sweep

Doc: OPERATOR-SETUP

## What changed

- New `bin/fly-pool-rows-parity.sh [--backfill] [--flip] [--json]`. It compares
  this box's `state/fly-pool/<p>/*.json` with the live machines rows for each
  pool project (one `GET /api/machines?project=<p>&live=1` per project). A file
  with no live row, or a row with another key, is `file_without_row`; a keyed
  live row with no file is `row_without_file` (counted, never blocking). Files
  younger than 240 s are not compared. A file with no machine or no key is
  `unreadable`. Verdict and rc: `parity` 0, `drift` 1, `unknown` 2 (any failed
  or truncated read, or a backfill with no `flags/fly-pool-app-<p>`).
- `--backfill`, only while the flag is off, writes the missing rows with
  `machine_put` and re-reads the rows before it believes them.
- `--flip` sets `fly_machines_rows=on` through `setting_set`, only on parity,
  with no young file waiting, no `FLY_MACHINES_ROWS` in the env, and the
  settings row still `value=off actor=seed`. An `off` written by anyone else
  stays off. The schema is untouched: `worker/jobs/schema.sql` is additive only.
- `bin/fly-pool-tick.sh` runs it with `--backfill --flip` after the per-project
  `wait`, fail-open.
- `bin/sweep-stale-builds.sh` no longer ssh's to any box. The `BOXES` loop,
  the unreachable-box skip and the `skipped_unreachable` beat field are gone.
  With the flag on, the pool evidence is `machines_list "" live` (rc 3 and one
  ALERTS line on a failed read or a full 500-row page). With it off, it is the
  hub's own pool files. Build-dir evidence is the hub's `builds/`.

## Why

BH-2522: pool assignments were only in files on the box that ran the pool, so
the sweep had to ssh every box to see them. The rows already existed (BH-1054
to BH-1056) behind a flag nobody had turned on, because nothing proved the rows
matched the files.

## Where to look

- `state/fly-pool/.parity.json`, `[pool-parity]` lines in `logs/fly-pool.log`.
- `bin/jobs-client.sh setting-get fly_machines_rows`.
- Turning the flip off: drop `--flip` from the tick line, or set the row by
  hand (`bin/jobs-client.sh setting-set fly_machines_rows off`). That makes
  the box the actor, so the preflight never flips it back.
- Every reader of `machines_rows_on` switches at the flip: `bin/fly-pool.sh`,
  `bin/fly-pool-tick.sh` (onboard retry policy), `bin/fly-provision.sh`,
  `bin/fly-image-refresh.sh`, and now `bin/sweep-stale-builds.sh`.
