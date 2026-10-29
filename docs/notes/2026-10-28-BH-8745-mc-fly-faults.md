# BH-8745: project-6-os Fly conductor — lease misses, died rows, write-back lock busy

## Evidence (2026-10-28, newest 50 `merge-conductor` rows of project-6-os, 09:42Z to 20:43Z)

| Rows | Status | attempts | Note |
|---|---|---|---|
| 51903, 51881, 51423, 50988 | done, `state=LEASE_HELD` | 2 | the second claim of the row missed the project lease |
| 51975, 51676, 51350, 51210, 51006, 50970, 50891, 50827 | died rc 137 | 3 | enqueued to died in 6 m 9 s to 6 m 40 s: 3 x the 120 s row lease with no heartbeat |
| 51553 | failed | 1 | `state=MERGED` with rc not 0 (out of scope) |
| the other 37 | done | 1 | a normal run takes 4 to 7 minutes |

## Causes

1. **The row heartbeat started too late.** `lw_run` (`bin/lane-run-worker.sh`) called `lrh_start`
   only after the spawn. The pre-run steps (`lw_warm_ensure`: up to 120 s on `locks/warm-<p>.lock`
   plus `git fetch`; `lri_fetch`: the snapshot download) sent no heartbeat. A pre-run longer than
   `lane_run.lease_s` (120 s) let the row lease run out, and the claim route gave the row to the
   next machine as attempt 2. The two machines then raced for the project lease: one got 409 `held`
   and ended `LEASE_HELD`; the other was killed by its first heartbeat (409 `not_claimer`). At
   attempt 3 `sweepDead` turned the row `died`, and the hub ran `fallback=machine-failed`.
2. **A dead holder's project lease outlived the row lease.** `project_lease.ttl_s` is 180 s and the
   row lease 120 s. A new claimer got `held` at once and ended `LEASE_HELD` with no wait.
3. **The hub's write-back apply waited 10 s for the snapshot lock.** `_mc_proj_apply` used the lib
   default (`LRI_LOCK_WAIT_S` unset, 10 s). The cron publisher (`bin/lane-snapshot-publish.sh`)
   holds `locks/lane-snapshot-merge-conductor-<p>.lock` across its apply and tar for 1 to 2
   minutes. A held apply wrote `.owed`, but the next tick did not apply the held write-backs when
   the publish throttle (`<p>.published-at`, 120 s) returned early.

## Fix

- `lw_run` starts the heartbeat right after the name checks: `lrh_start <id> "" <max_s>`. The new
  third argument stops the beat after `lane_run.prerun_beat_max_s` seconds (one log line, nothing
  killed). Before each pre-run report and before the spawn the beat is stopped; a row lost in the
  meantime (409 `lost`) is not run and not reported.
- `merge-conductor-project.sh` polls a held lease every `mc_project_fly.lease_poll_s` seconds for up
  to `mc_project_fly.lease_wait_s` seconds. A TERM in the wait ends `state=STOPPED`, rc 0. No
  answer in the wait ends `LEASE_UNAVAILABLE`, rc 75, as before.
- `_mc_proj_apply` and the apply in `mc_proj_publish` wait `mc_project_fly.apply_lock_wait_s`. A
  busy lock gives one line that names the lock and the wait. The publish keeps
  `mc_project_fly.publish_lock_wait_s` (the BH-7520 seed note still says both calls wait it; the
  apply no longer does).
- A held apply writes `state/merge-conductor/project-fly/<p>.apply-owed` (`<row id|-> <epoch>`).
  The next `mc_proj_gate` tick applies it first, under the gate lock and before any routing,
  whatever the publish throttle says. Success removes the mark with one `held write-backs of row
  <id> applied` line; a failure keeps it (`still not applied`).

## Knobs (worker/jobs/schema.d/202610282048-bh-8745-mc-fly-faults.sql)

| Row | Seed | Range | Rollback |
|---|---|---|---|
| `lane_run.prerun_beat_max_s` | 600 | 1..3600 | none: the pre-run beat is the fix |
| `mc_project_fly.lease_wait_s` | 210 | 0..900 | 0 (the old immediate `LEASE_HELD`) |
| `mc_project_fly.lease_poll_s` | 15 | 1..300 | n/a |
| `mc_project_fly.apply_lock_wait_s` | 120 | 1..600 | 10 (the old lib default) |

## Post-merge probe (not a PR gate)

From the hub, every 6 h for 24 h:
`_jobs_req GET "/api/lane-runs/by-prefix?lane=merge-conductor&project_prefix=project-6-os&limit=50"`.
Count `status` died or failed plus `state=LEASE_HELD`. The target is 5 or fewer in 24 h, and no new
`mc-project-lease-project-6-os` line in `logs/ALERTS.log`. On the lane machines, read
`logs/lane-run-worker.log` for `lease lost during the pre-run` and `pre-run heartbeat stopped`.

Tests: `tests/lane-run-prerun-beat.bh-8745-test.sh`, `tests/mc-fly-faults.bh-8745-test.sh`.
