# Registry seed apply: worker routes, fleet gate, run table (BH-2521.2, BH-2676)

Doc: DB-COORDINATION-SPEC

## What changed

- **`registry_seed_runs`** (worker/jobs/schema.sql, additive, applied by
  `bin/harness-sync.sh` before deploy): one row per console apply that got past
  the gate and the fingerprint. Status is `started`, then `applied` or `failed`.
- **`GET /api/settings/seed-registry/plan`** also answers `plan_fp`: 64 lowercase
  hex, the SHA-256 of `{insert, update, prune}` with every list sorted. The CLI's
  `--dry-run` reads its keys with jq and ignores this one.
- **`POST /api/settings/seed-registry/apply {plan_fp, actor}`**: 400 on a blank
  actor or a bad fp. 409 `fleet_gate` with `boxes:[{box, reason}]` when a box that
  ticked a lane in the window has no harness commit, no report time, an
  unreadable one or a stale one, or when no box ticked at all. 409 `plan_moved`
  with the fresh plan when the fp no longer matches. None of those write anything.
  Otherwise it writes the `started` row, runs the seed, and marks the row
  `applied` with the counts and key lists. A seed that throws marks it `failed`
  with the error and answers 503. 200 is `{id, actor, rows, changed, pruned,
  changed_keys, pruned_keys, as_of}`, where `actor` is the caller.
- **`GET /api/settings/seed-registry/runs`**: the last 20 runs, newest first,
  `truncated` when there are more.
- **`POST /api/settings/seed-registry`** (the CLI's) answers exactly what it did.
  Its body moved into `runSeed` so both paths run the same seed.

## Knobs

`seed_gate_tick_window_s` (fallback 86400) and `seed_gate_max_age_s` (fallback
7200), as settings rows. A row wins when it is a positive int. The fallbacks are
the numbers `bin/harness-ctl.sh` `_seed_gate` uses.

## Known differences from the CLI gate

The worker has no checkout, so it does not check that a box's commit contains the
contract, and it has no `--exclude-box`. A retired box that still ticks lanes
blocks the console apply; the CLI keeps that override. CLI seeds write no run
row, so `/runs` only shows console applies.
