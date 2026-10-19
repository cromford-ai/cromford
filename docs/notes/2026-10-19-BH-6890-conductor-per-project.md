# Merge conductor per project on a lane-run machine (BH-6890, BH-6881.6)

Doc: MERGE-CONDUCTOR, PROJECT-LANES, HARNESS-COORDINATION

## What changed

The hub can now move the WHOLE merge conductor of one project to a lane-run
machine. The machine holds the project lease (#6883) for the run and enqueues
READY PRs into the repo's merge queue. The code ships dark: the placement row
is seeded `hub`.

- **Placement.** `bin/lib/lane-placement.sh` reads
  `lane_placement.<lane>.<project>` first, then `lane_placement.<lane>`, then
  `lane_placement.default` (`lp_decide <lane> [project]`). A caller with no
  project is unchanged.
- **Hub.** `tick_project` calls `mc_fly_project_gate`
  (`bin/lib/mc/fly-workers.sh`) after the project hold and before any GitHub
  read. With `lane_placement.merge-conductor.<project>=fly`, the gate
  (`mc_proj_gate`, `bin/lib/mc/project-placement.sh`) does one of these, with
  one log line `<project> project-fly: ...` in `logs/merge-conductor.log`:

  | newest row of (merge-conductor, project) | hub does |
  |---|---|
  | none, or done with no deferred word | applies pending write-backs, publishes the snapshot, enqueues ONE row (args `bin/merge-conductor-project.sh <project>`), no PR work |
  | queued (fresh) or claimed | writes `<project>.owed`, no PR work |
  | 409 `already_live` on the enqueue | writes `<project>.owed`, no PR work |
  | a hub fallback tick of the project still runs | writes `<project>.owed`, no new row |
  | queued for `MC_FLY_QUEUE_STALE_S` (600 s) or more, or `withdrawn` | fallback `no-capacity` |
  | died, failed, done rc != 0, done with no `PROF mc-project` line | fallback `machine-failed`, once per row |
  | done with `deferred=<words>` | fallback `machine-deferred`, once per row |
  | the lane_runs read or the enqueue failed | fallback `enqueue-failed` |

  Before any hub fallback, under the gate lock, the hub applies the
  project's pending write-backs (`lri_apply_pending`, the `BR_PRE_APPLY`
  rule) and writes the hub mark (`<project>.hubtick`). If the apply fails, the
  hub does no PR work for the project that tick (owed). A stale row is ended
  first (`POST /api/lane-runs/<id>/withdraw`, status `died`, prof
  `withdrawn by=hub-<host> ...`), so no machine claims it during the hub tick.
  A withdrawn newest row (the hub's own withdraw, or the worker's
  refused-at-claim end) is taken back once. The hub keeps the project for
  `mc_project_fly.nocap_backoff_s` (600 s), then enqueues a new row. The hub
  mark is `<pid> <start stamp> <epoch>`. It counts only while that pid lives
  with the same start stamp and the mark is younger than
  `mc_project_fly.hubtick_max_s` (3600 s). It is removed when the take-back
  tick ends.
  A placement row that cannot be read fails closed for a project last placed
  fly (`<project>.placed`) or with a live row. When the fresh box settings
  cache has no fly placement row and no `.placed` mark exists, the hub tick
  skips the gate for every project (one jq read, no settings read per
  project).
  Fallback with `lane_fallback.merge-conductor.<project>=hub` (the default):
  that tick runs on the hub as today. After a failed or deferred row, a
  full tick runs on. A keyed tick starts ONE full tick of the project
  (`MC_ONLY_PROJECT`, `MC_PROJ_TAKEBACK=1`) under the BH-5463 full-tick lock.
  When a full tick of the project already holds it, the take-back waits for
  the next tick. The hub then settles and rebases what the machine left.
  `mc_project_fly.failed_alert_n` (3) machine-failed rows in a row raise one
  held ALERTS line. The row id goes to `<project>.taken`,
  and the next tick enqueues a new row.
  Fallback `off`: ONE ALERTS line per project per hour
  (`lane-alert.sh --id mc-project-fly-<project>`), and the hub runs nothing
  for that project. After a failed or deferred row it enqueues a new row.
- **Machine.** `bin/merge-conductor-project.sh <project>` does these steps.
  1. Acquire the lease (holder `FLY_MACHINE_ID`).
  2. Run `bin/merge-conductor.sh` with `MC_ONLY_PROJECT=<project>`,
     `MC_ON_MACHINE=1`, `MC_LEASED_RUN=1` and the lease exported
     (`MC_LEASE_FENCE`, `MC_LEASE_PROJECT`, `MC_LEASE_HOLDER`).
  3. Renew the lease every `MC_PROJECT_RENEW_S` (60 s) while it runs.
  4. Post the write-back (`lri_checkpoint`) and release the lease.
  5. Print
  `PROF mc-project state=<S> landed=<n> queued=<n> deferred=<w|-> fence=<f>`.
  S is `MERGED` (the run saw one of its landings merged), `QUEUED` (it
  enqueued one), `LEASE_LOST`, `STOPPED` (TERM), `LEASE_HELD`,
  `LEASE_UNAVAILABLE` or `TICKED`.
- **What a lease-held run does that a per-PR run does not.** With
  `MC_LEASED_RUN=1` and a fence: the READY arm enqueues (`mc_enqueue`), the
  QUEUED settle pass runs, and the tier-2 and external enqueue steps
  (`ae_project`, `xe_project`) run. Every landing writer renews the fence
  first (`mc_lease_fence_ok`, BH-6887). The per-PR path
  (`bin/merge-conductor-pr.sh`, no `MC_LEASED_RUN`) still defers all of them.
- **Alerts (a change for every lane on a lane-run machine).**
  `bin/lane-alert.sh` with `LANE_RUN_ID` set posts its line to
  `/api/alert-lines` (#6889) and writes nothing local. The hub replays it
  through `bin/alert-line.sh` with the same `--id` and severity. On that path
  the alert-state machine of `lane-alert.sh` and the `--critical` Telegram DM
  do not run. A `--resolve` or a `--log-only` stays local. A failed post takes
  the local path.
- **Fence before every queue post.** `_ae_send` (`bin/lib/autoenqueue.sh`,
  used by `ae_project` and `xe_project`) calls `mc_lease_fence_ok` just before
  the `@mergifyio queue` POST.
- **attempts.txt.** Appends go under `attempts.txt.lock`
  (`_mc_attempt_append`), the lock the hub's write-back apply takes. The
  `@rows` line also carries the repo's own lines (`identityalert`,
  `citimeout`).
- **TERM and a lost lease.** The entry reaps the conductor's whole process
  tree (by pid where there is no `setsid`) before it removes the stop file. A
  TERM before the conductor starts releases the lease. A run that lost its
  lease posts no write-back of its own. The worker's final write-back still
  posts, and the hub applies it compare-and-set.
- **Snapshot.** `catalog/lane-run-inputs.d/merge-conductor.rw` now carries
  this repo's lines of `state/merge-conductor/attempts.txt` (`@rows`) and the
  land watermark `state/merge-conductor/land/<project>`. The cron publisher
  has a `--lane merge-conductor` line (6,16,...). The hub gate also publishes
  the one project just before it enqueues.

## Settings rows

| row | seed | use |
|---|---|---|
| `lane_placement.merge-conductor.project-6-os` | `hub` | `fly` moves the project to a machine |
| `lane_fallback.merge-conductor.project-6-os` | `hub` | `off` stops the hub fallback for the project |
| `mc_project_fly.alert_s` | 3600 | one ALERTS line per project per this many seconds, with the fallback off |
| `mc_project_fly.publish_min_s` | 120 | the hub gate publishes a project's snapshot at most once per this many seconds |
| `mc_project_fly.failed_alert_n` | 3 | machine-failed rows in a row that raise one ALERTS line, with the fallback on |
| `mc_project_fly.hubtick_max_s` | 3600 | a hub take-back mark older than this no longer blocks a new row |
| `mc_project_fly.nocap_backoff_s` | 600 | after a withdrawn (no-capacity) row is taken back, the hub keeps the project this long, then enqueues a new row |

## What still runs on the hub (deferred words)

These need hub files. A lease-held run writes their word to
`MC_PR_DEFERRED_FILE`, and the hub's next tick of the project runs them
(`fallback=machine-deferred`):

| word | why |
|---|---|
| `settle` | `conductor_settle` writes the deploy queue file and spawns the deploy-verify lane, and its dedupe is `attempts.txt` on the hub |
| `land` | a direct merge (a repo with no queue, or `landing_direct`): it settles in the same tick |
| `rebase` | the rebase job files, unless `conductor_remote_spawn.<project>=1` (BH-6888) puts it on the pool |
| `rereview`, `dv` | box-local job files (BH-6888 C1 and C2 are not built) |

Not carried and not needed for a landing: `lane-epoch`, `hold-reminder-at`,
`diffs/*`, `state/stack-follow/*`, `state/lead-authority/human-needed-*`. The
batch train (`bin/batch-resolve.sh`) does not run on a machine.

## Switch and rollback

On, for project-6-os (data change, after merge):

    setting_set lane_placement.merge-conductor.project-6-os fly

Rollback: `setting_set lane_placement.merge-conductor.project-6-os hub`. The
next hub tick runs the project as before. A row already queued or claimed
still runs once on a machine, under the lease. Wait for that live row to
finish before you call the rollback done, or accept one hub tick that
overlaps it. Landings stay serialised by the project lease in both cases.

Keep `lane_fallback.merge-conductor.project-6-os=hub` until #6895 (24 h with
0 fallbacks and 0 lease conflicts). For fewer `rebase` take-backs, also set
`conductor_remote_spawn.project-6-os=1`.

## Proof (after the flip)

1. One real project-6-os PR is enqueued by a machine: the lane_runs row
   (lane `merge-conductor`, project `project-6-os`) with
   `claimed_by=<machine id>` and `PROF mc-project state=QUEUED`, then a later
   row with `state=MERGED`.
2. The GitHub merge event of that PR at that time.
3. No keyed tick of project-6-os does PR work on the hub in that window:
   `grep -c 'keyed tick.*project-6' logs/merge-conductor.log` against
   `grep -c 'project-6-os project-fly: enqueued' logs/merge-conductor.log`,
   and every `fallback=` line counted by word.
4. The machine image sha equals the lane image sha of main.

## Known limits

- The hub still starts `bin/merge-conductor.sh` for each wake of a fly
  project. The gate returns before any GitHub read.
- The withdraw route is a jobs-worker change. Until the worker is deployed,
  the withdraw is not answered: the hub falls back as before, and a machine
  that claims the row later waits on the project lease for each landing.
- An owed run waits for the next hub tick of the project (a wake, the 5-min
  backstop or the 30-min cron tick).
- The hub applies a machine's write-back on its next gate call or the next
  cron publisher tick, so `pr-state.tsv` on the hub can lag the machine by up
  to 10 min for a fly project.

Tests: `tests/merge-conductor-project.bh-6890-test.sh`.
