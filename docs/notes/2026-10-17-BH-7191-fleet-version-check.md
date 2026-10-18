# BH-7191 (BH-7302): fleet version check, the tracer

Doc: OPERATING

New hub lane `fleet-version-check` (`bin/fleet-version-check.sh`, every 10 min, behind `hub-lease.sh check`). Alert only: it writes no flag, no pause and no setting, and it exits 0 on every path.

What it reads, per tick: `GET /api/registry` and `GET /api/boxes` (in parallel), and first-parent `origin/main` in `HARNESS_CHECKOUT` (`git fetch`, then `git log --first-parent -n 3000`). Each registry box takes the newest-reported `box_status` row named like it or with its cron box id.

Lag = the box's report time minus the merge time of the oldest first-parent main commit the reported sha lacks. Only commits merged before the report count, and only commits on `bin/lib/fleet-paths.sh` paths. A sha at the tip is 0.

| Row | Result |
|---|---|
| no sha | `ALERT nosha no sha reported` |
| report older than 60 + max_lag min, or none | `ALERT nosha report stale` |
| sha not on main | `ALERT lag sha not on main` |
| sha older than the 3000 fetched commits | `ALERT lag lag>=<n>m` |
| lag > max_lag | `ALERT lag lag=<n>m` |
| otherwise | `OK lag=<n>m` |

Thresholds: the settings rows `harness_version.max_lag_min` (30) and `harness_version.max_beat_gap_min` (30, no reader until BH-7191.2). The env values `HARNESS_VERSION_MAX_LAG_MIN` / `HARNESS_VERSION_MAX_BEAT_GAP_MIN` override them on one box. A value that is not a whole number logs one WARN line, and the lane uses 30.

Dedup: an ALERT goes to `bin/alert-line.sh --id fleet-version:<kind>:<box>` once, and the lane touches `state/fleet-version-check/open/<kind>.<box>`. Later ticks log `still open`. An OK tick for the box removes its `lag` and `nosha` markers (`cleared`). To re-page a condition by hand, delete its marker file. A fresh `flags/orchestrator-sync-in-progress` (< 45 min) logs ALERTs as `suppressed`.

Log: `logs/fleet-version-check.log`. Off: `bin/harness-ctl.sh off fleet-version-check`.

Seams for the siblings: `bin/lib/fleet-version-rules.d/10-role.sh` (BH-7191.1), `30-beat.sh` and `40-nosync.sh` (BH-7191.2), `bin/lib/fleet-version-sink.sh` (BH-7191.4). `worker/jobs/src/lib/core.js` adds the nullable columns `box_status.{harness_synced_at,sync_timer,harness_lag_min,lag_checked_at}`, `registry_boxes.role`, `harness_commit` on `lane_runs`, `lane_machines` and `build_queue`, and `idx_lane_ticks_box`. No route reads them yet.

Until BH-7191.2 removes the remote-box branch of `bin/pipeline-health.sh` section 8, one stale box can page under two keys (`driftfail:*` and `fleet-version:*`).
