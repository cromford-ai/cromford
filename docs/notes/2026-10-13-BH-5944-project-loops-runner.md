# Six project loops on the per-project runner (BH-5944)

Doc: BUILD-CONCURRENCY

Parent: BH-5938 (BH-5938.4). The runner is BH-5913
(`bin/lib/project-lanes.sh` `pl_dispatch` and `bin/project-lane-run.sh`).
BH-5943 moved stuck-work onto it. This change moves six more lanes:
dequeue-watch, archie-fm, review-autopilot, fleet-status-push,
metrics-collect and stale-owed-tickets. BH-6894 (7cf4caec) moved
pr-url-reconcile onto the runner with its own design, so this change does not
touch it.

Before this change, each of these lanes looped over every fleet project in one
process under one lock. One slow project held the lock for all the others, and
the next tick found the lock held and did nothing.

What each lane does for a project did not change. Only who runs it and which
lock it holds changed.

## The three modes

Every one of the six lanes now has the same three modes.

| command | what it does |
|---|---|
| `<lane>.sh --dispatch` | The cron line. It starts one detached `<lane>.sh <project>` per fleet project through `pl_lane_dispatch` and returns. It takes no lock. |
| `<lane>.sh <project>` | One project's run. It holds `locks/<lane>-<project>.lock` (fd 9, the runner's) and `locks/<lane>.lock` SHARED (fd 4). |
| `<lane>.sh` | The whole-fleet run of before (hand runs, the wake launch). It holds `locks/<lane>.lock` EXCLUSIVE. |

Many project runs hold the shared fleet lock at once. A whole-fleet run and a
project run never overlap: each one finds the other's lock held and stops
(`locked`, `busy`, or silent, as the lane did before).

archie-fm is the one exception in its arguments: the dispatch runs
`archie-fm.sh tick --project <p>`, so `--project <p>` without `--pr` is the
project mode. `--pr` and no argument keep the exclusive lock. A project run
never re-opens fd 9.

A bad argument, or a project that fleet.conf does not name, exits 2 before any
lock or worker request (`pl_project_known`).

## The cron lines

Same cadence. Each line now writes into its own cron log, and the runner
appends every project run's stdout and stderr to the same file.

| file | command |
|---|---|
| `cron/lanes/415-dequeue-watch.cron` | `dequeue-watch.sh --dispatch >> logs/dequeue-watch-cron.log 2>&1` |
| `cron/lanes/725-archie-fm.cron` | `archie-fm.sh --dispatch >> logs/archie-fm-cron.log 2>&1` |
| `cron/lanes/490-review-autopilot.cron` | `review-autopilot.sh --dispatch >> logs/review-autopilot-cron.log 2>&1` |
| `cron/lanes/270-fleet-status-push.cron` | `fleet-status-push.sh --dispatch >> logs/fleet-status-push-cron.log 2>&1` |
| `cron/lanes/130-metrics-collect.cron` | `metrics-collect.sh --dispatch >> logs/metrics-collect-cron.log 2>&1` |
| `cron/lanes/300-stale-owed-tickets.cron` | `stale-owed-tickets.sh --dispatch >> logs/stale-owed-tickets-cron.log 2>&1` |

The five hub lines keep the `hub-lease.sh check &&` prefix. metrics-collect is
a box lane and has none.

## Per lane

- **dequeue-watch.** A project run keeps only its own fleet.conf row, and its
  summary line ends ` project=<p>`. The observe tick (`observe_report_tick`)
  runs once per dispatch, in the dispatch arm. So `DEQUEUE_WATCH_OBSERVE_TICKS`
  still counts dispatches, not dispatches times projects. A busy project run
  writes `locked project=<p>`.
- **archie-fm.** The day cap is now claimed under a lock.
  `afm_cap_claim <project> afm_claim <args>` holds
  `locks/archie-fm-cap-<playbook>.lock` (fd 5, at most 30 s) around
  `afm_cap_ok` and the claim. Two project ticks at `used = cap - 1` can not
  both claim. rc 100 means no claim: the cap is full or unreadable, or the lock
  was not free (one `afm_log` line). The three call sites (restack, data-lane
  apply, rebase-repair) use it. The suite and data-lane children close fds 4
  and 5, so a 900 s suite never holds the shared lane lock or the cap lock.
  `ARCHIE_FM_PROJECTS_PER_TICK` and the rotation do not apply to one project.
- **review-autopilot.** The dispatch runs the fleet-wide steps once: the wake
  backstop, the housekeeping `find` and `pause_refresh`. A project run skips
  them. Its end beat carries `project: <p>` and the akey
  `review-autopilot:<p>:<YYYYmmdd-HH>`, so one hour's per-project beats do not
  dedupe into one. The day cap was already per project.
- **fleet-status-push.** `fsp_project_row <p>` builds one project's part of
  the snapshot. A project run writes it to
  `state/fleet-status-push/<p>/row.json`:
  `{"v":1,"project":p,"at":<epoch>,"row":{the 7 .projects fields},"rrp":<n>,"lane":{project,box,cadence_min,offset_min}|null}`.
  It pushes nothing. The dispatch starts all runs at once (window 0), waits up
  to `FLEET_STATUS_PUSH_ROW_WAIT_S` (default 60) for a v1 row with
  `at >= <dispatch start>` from every project that is not held, and computes
  any missing or late row itself. Then `.projects`, `remote_results_pending`
  and the expected lanes are built from the rows, and the rest of the script
  (stale_owed, hub, quotas, the POST, the beat, the lease alert,
  `lanes_expect`, the ceiling watch) runs once. It logs
  `dispatch: N project row(s) from their runs, M computed here after Ws`. The
  whole-fleet run computes every row inline and takes no lock.
- **metrics-collect.** A project run writes each new build as one row in
  `state/metrics-collect/<p>/rows.csv` and one line in `<p>/seen.txt`. The
  builds no fleet project owns go to `state/metrics-collect/unresolved.csv`
  (the dispatch and the whole-fleet run write them). `mc_aggregate` rebuilds
  `logs/metrics.csv` = header + `legacy.csv` + every `rows.csv` (sorted by
  project) + `unresolved.csv`, tmp + mv, under
  `locks/metrics-collect-agg.lock`. ONE-TIME CUTOVER: when `legacy.csv` is
  absent, the body of the old `logs/metrics.csv` becomes `legacy.csv`, and the
  old `state/metrics-seen.txt` is only read from then on, so no build is
  written twice. `reopen-metrics.sh` reads the same file and columns.
- **stale-owed-tickets.** A project run writes
  `state/stale-owed-tickets/<p>/entry.json` =
  `{"v":1,"at":…,"entry":{count,tickets}}`, or `"entry":null` when the project
  was skipped (no token or base, the board list failed). `so_aggregate`
  rebuilds `state/stale-owed.json` from the current map cut to the board
  projects, with `.[p] = entry` for every row (a null entry deletes the key, as
  a skipped project was absent before). The read-merge-write of
  `state/stale-owed-queued.json` and of each `state/stale-owed-orphans.json`
  stamp and prune re-reads the file under `locks/stale-owed-tickets-agg.lock`
  and changes only the run's own keys. The section-4 `find` runs in the
  dispatch, once. A project with no board writes one log line and exits 0.

## Shared runner additions (bin/lib/project-lanes.sh)

- `pl_lane_lock <lane> <project>`: the project lock (the runner's fd 9, or
  `pl_lock_take` for a hand run), then the fleet lock shared on fd 4. rc 1 busy.
- `pl_lane_lock_all <lane>`: the exclusive fleet lock on fd 9, for the
  whole-fleet mode of metrics-collect and stale-owed-tickets, which had no lock
  before.
- `pl_lane_dispatch <lane> <window-s> <cmd> [args...]`: `pl_dispatch` with a
  period of window x `PL_DISPATCH_SPREAD_PCT` / 100. The windows: dequeue-watch
  50 s, archie-fm 300 s, review-autopilot 1800 s,
  fleet-status-push 0 s, metrics-collect 600 s, stale-owed-tickets 600 s.
- `pl_agg_lock <lane>` / `pl_agg_unlock`: `locks/<lane>-agg.lock` on fd 5, at
  most 30 s, held only around a read-merge-write of a shared file. On the time
  limit the run keeps its own row, skips the aggregate with one log line, and
  the next run rebuilds it.
- `pl_project_known <project>`: fleet.conf names it.

## Knobs

| knob | where | default | meaning |
|---|---|---|---|
| `PL_DISPATCH_SPREAD_PCT` | `catalog/lanes.d/_lib.project-lanes.json` | 100 | the share of each lane's dispatch window the project runs spread over; 0 starts all at once |
| `FLEET_STATUS_PUSH_ROW_WAIT_S` | `catalog/lanes.d/fleet-status-push.knobs.d/` | 60 | how long the fleet-status-push dispatch waits for the rows; 0 computes every row in the dispatch |
| `PL_TEST_BARRIER`, `PL_TEST_BARRIER_EXIT`, `PL_TEST_LOCK_WAIT_S` | `_lib.project-lanes.json`, `settable: false` | empty, 0, 30 | test seams, honoured only under `HARNESS_TEST_SANDBOX=1` |

## Tests

- `tests/project-loops.bh-5944-test.sh`: the lib (L1-L6), each lane's
  dispatch of 50 projects with no run waiting on another project's lock
  (D-<lane>), each lane's busy path, the observe tick per dispatch,
  archie-fm's shared lock, review-autopilot's beat, and the
  locked archie-fm day cap (C1-C3).
- `tests/fleet-totals.bh-5944-test.sh`: the rows and the aggregate of
  fleet-status-push (F1-F6), metrics-collect (M1-M6) and stale-owed-tickets
  (S1-S6). The fleet total equals the sum of the rows.
