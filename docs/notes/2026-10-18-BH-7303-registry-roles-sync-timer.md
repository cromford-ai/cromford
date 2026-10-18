# Box roles in the registry, a sync timer on every box, the watchdog list from the registry (BH-7303)

Doc: OPERATING, ADDING-A-BOX

## What changed

Part of BH-7191 (fleet version lag), slice 1 of the children (C1 and C5).

- **A role per box.** `registry_boxes.role` is one of `build review gate
  standby hub gate-only retired`, or null. The harness-jobs registry routes
  validate it (anything else is 400). `GET /api/registry` leaves the key out
  when the role is null, and every reader applies a default then.
- **`# @boxrole <box> <box_id> <role>`** is a new `fleet.conf` directive, for a
  box with no project row or to override a default. The committed file has two:
  `box-review-2 review2 review` and `bh-hub-2 hub2 hub`. It is not the
  `# @box <box> <ip>` line of the db-mode render (BH-5650), which keeps its
  shape. The db-mode render (`bin/lib/registry.sh _rg_render`) writes a
  `# @boxrole` line for every box with a role.
- **`bin/fleet-conf.sh --boxes-with-roles`** prints `box<TAB>box_id<TAB>role`
  for every box the file knows. First match wins: a `@boxrole` line, the hub,
  the `@standby` box (standby), an active row's box (build), a
  `@retired <project> <box>` box (retired).
- **`bin/registry-seed.sh`** gives each box row its role. The `watchdog-ping`
  and `harness-sync-timer` lanes get one `lane_boxes` row per box whose role is
  not `gate-only` or `retired`, in place of those two lanes' `.boxes`.
- **`bin/registry.sh set-box-role <box> <role>`** and **`add-box --role`**.
- **`bin/registry-export.sh`**: `import.json` keeps `role`. A template
  `# @boxrole` line prints verbatim and is not refreshed from the registry.
- **The `harness-sync-timer` lane** (`bin/harness-sync-timer.sh`, `*/5` on
  every box in `catalog/lanes.d/harness-sync-timer.json`, review2 and hub2
  included). It runs `bin/harness-sync.sh deploy` when
  `state/harness-sync-last-success` and its own
  `state/harness-sync-timer-last-attempt` are both one period old. Period:
  knob `HARNESS_SYNC_PERIOD_MIN`, settings row
  `lane.harness-sync-timer.harness_sync_period_min`, default 15, 5 to 240. It
  probes `locks/harness-sync.lock` with `flock -n` and never waits. A failed
  sync is rc 1 and leaves last-success alone; harness-sync writes its own
  alert, and the attempt stamp holds the next try for one period.
- **`fvc_rule_role`** (`bin/lib/fleet-version-rules.d/10-role.sh`): a
  `gate-only` box prints `SKIP <box> gate-only (registry role)`, a `retired`
  box `SKIP <box> retired`; both stop the later rules (rc 2).
- **The watchdog list.** `bin/fleet-status-push.sh` puts the names of the boxes
  whose role is not `gate-only` or `retired` into the snapshot as
  `expected_boxes`; the 60 KB shed keeps it. The watchdog's `scheduled`
  stale-ping loop, the `/api/ping` unknown-box check and `/api/status` use that
  set, and fall back to `worker/watchdog/src/boxes.json` when it is absent,
  empty or not a list of valid names. A box that has never pinged is still not
  paged.
- **The two `@boxrole` boxes ping.** `catalog/lanes.d/watchdog-ping.json`
  lists `review2` and `hub2`, so file mode and db mode give them the same
  crontab. `cron_watchdog_name_for` (`bin/lib/cron-lines.sh`) names a box with
  no project row from its `@boxrole` line (`box-review-2`,
  `bh-hub-2`). They have no `cron/boxes/<id>.d`: that directory is full
  enrollment (cost lanes, audit-tail), and `bin/box-register.sh` creates it.
  `worker/watchdog/src/boxes.json` (the fallback) is unchanged, so while the
  watchdog has no snapshot with `expected_boxes`, a ping from review-2 or
  hub-2 raises the hourly unknown-box alert, as it does today.
- **`bin/box-lists-check.sh`** allows the `@boxrole` box ids in the box lists.
  It does not require them.

## Why

A box synced only by `update-runners` (05:17Z) and `bin/fleet-propagate.sh`
lags main by up to a day when a propagate does not reach it. Two boxes
(review-2, hub-2) had no project row, so no list named them. The watchdog
could not page for them, and the version check could not tell a gate-only box
from a lagging one.

## Operator steps

1. If a box's `state/box-id` is not `review2` / `hub2`, correct the
   `# @boxrole` line and `catalog/lanes.d/harness-sync-timer.json`, or the
   registry with `bin/registry.sh`. Until then that box's crontab has no
   `harness-sync-timer` line.
2. The registry is seeded in prod, so the seed does not add the roles there.
   Run `bin/registry.sh add-box box-review-2 --id review2 --ip <ip>
   --like <box-id> --role review` and the same for `bh-hub-2` (`--id hub2
   --role hub`). `--like` names the existing box whose lanes it must run. For a
   box that exists, run `bin/registry.sh set-box-role <box> <role>`.
3. Run `bin/update-runners.sh` once on bh-hub-2: fleet-propagate cannot reach
   it with the hub key.
