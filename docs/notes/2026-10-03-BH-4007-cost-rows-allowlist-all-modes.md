# The cost-rows allow list reaches --box and --verify, and a missing list says so (BH-3982, slice BH-4007)

Doc: COST

## Why

BH-4004 filtered only the cron mirror (`cost-rows-push.sh <box>`). The pool
reap (`--box`, run by `bin/fly-pool.sh` and `fly/builder-runner.sh`) still
sent fixture rows, and `--verify` still counted them as owed. A fail-open run
filtered nothing and said nothing.

## What changed

- `bin/cost-rows-push.sh` builds `COST_ROWS_ALLOW` once, after the lane gate,
  `lane_env_apply` and `jobs-client.sh`, and before `--verify`, for all three
  modes.
- `--box` makes the per-run drop log too and writes the same
  `… [<box>] dropped <N> row(s) whose project is not in fleet.conf or COST_ROWS_LANE_PROJECTS (<names>) — BH-3982`
  line to `logs/cost-rows-push.log`. Its stdout `pushed <n> (<m> dup)` is
  unchanged.
- `--verify` does not count a row the list drops as owed. An empty list counts
  every row, the same fail-open as the pusher. It stays read-only: no temp
  file, no flag, no log line.
- A push (cron or `--box`) whose list comes back empty writes one line per UTC
  day, gated by `flags/alerted-cost-rows-noallow-<YYYYMMDD>`:
  `… [<box>] cost-rows-push: allow list unavailable (fleet-conf.sh --projects answered nothing) — not filtering`.
  A log line, not ALERTS. No line when `bin/lib/cost-row.sh` itself is missing.
- `COST_ROWS_LANE_PROJECTS` is a registered, settable string knob on the
  `cost-rows-push` lane (`catalog/lanes.d/cost-rows-push.json`, settings key
  `lane.cost-rows-push.cost_rows_lane_projects`), with
  `env-templates/lanes/377-cost-rows-allow-list.env.example`.

## How to check

On a box: `grep -E 'BH-3982|allow list unavailable' /root/harness/logs/cost-rows-push.log`.
Suite: `tests/cost-rows-push-modes.bh-4007-test.sh`.
