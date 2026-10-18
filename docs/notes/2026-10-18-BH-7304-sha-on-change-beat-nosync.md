# BH-7304 (BH-7191.2): sha on change, sync facts, beat and nosync rules

Doc: OPERATING

`bin/lib/lane-gate.sh` sends the box's harness sha on the liveness post when the sha changes, or when the last send is an hour old. Before, it sent only hourly. The stamp `state/lane-gate/.harness-commit-sent` is now `<epoch> <sha>`. An old epoch-only stamp reads as "sha unknown", so the next tick sends and rewrites it. Lane-gate reads the sha from the checkout files on every tick. It runs no `git`.

A send tick also carries:

| Key | Value | Left out when |
|---|---|---|
| `harness_synced_at` | the ISO time of a `done` line in `state/harness-sync-phase` | the phase is `copied` or `step=<name>`, or the file is missing |
| `sync_timer` | 1 when a non-comment `crontab -l` line names `harness-sync-timer`, else 0 | the box has no `bin/harness-sync-timer.sh` (BH-7191.1), or no `crontab` |

`POST /api/lanes/liveness` stores `harness_synced_at` (only `YYYY-MM-DDTHH:MM:SSZ`) and `sync_timer` (only 0/1 or "0"/"1") in `box_status`. A missing or bad value keeps the stored one, and the tick still lands. `harness_reported_at` moves only with a valid sha, because `harness-ctl seed-registry` reads it.

`GET /api/boxes` adds `last_beat_at` per box: the newest `lane_ticks.last_tick_at` of the box, any lane, or null. It is one `GROUP BY box` aggregate on `idx_lane_ticks_box`, read in parallel with the `box_status` read, and merged in JS.

`bin/fleet-version-check.sh` now gets two more rules:

| Rule | Input | Result |
|---|---|---|
| `30-beat.sh` | `last_beat_at` empty or unparseable | `ALERT beat no heartbeat on record` |
| | older than `harness_version.max_beat_gap_min` (30) min | `ALERT beat no heartbeat <n>m` |
| `40-nosync.sh` | `sync_timer` 0 | `ALERT nosync no sync timer` |
| | empty or another value | `OK sync timer not reported` |

`bin/pipeline-health.sh` section 8 no longer judges remote boxes, so a stale box pages once (`fleet-version:*`), not twice. It still auto-heals the hub's own checkout and pages `driftfail:local` when the heal fails. The knob `HARNESS_HEAD_GRACE_S` had no other reader and is removed from `catalog/lanes.d/pipeline-health.json`.

Known gap: the lane clears only the `lag` and `nosha` open markers on an OK line. A `beat` or `nosync` marker stays until someone deletes `state/fleet-version-check/open/<kind>.<box>`, so a second episode for the same box does not page again.
