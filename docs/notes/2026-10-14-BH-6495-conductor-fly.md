# Merge-conductor per-PR workers on lane-run machines (BH-6495, BH-6047.5)

Doc: MERGE-CONDUCTOR, PROJECT-LANES

## What changed

The hub's conductor tick can now place each PR's worker on a lane-run Fly
machine instead of starting it on the hub. The code ships dark: the switch row
is seeded `0`.

- **Hub.** In `tick_project`'s launch loop, after the worker window check,
  `mc_fly_arm` (`bin/lib/mc/fly-workers.sh`) decides per PR. With the switch
  on, it enqueues ONE `lane_runs` row: lane `merge-conductor-pr`, project
  `<project>.<pr>.<head12>`, args
  `bin/merge-conductor-pr.sh <project> <owner/repo>#<pr> <head40>`. No local
  `pr_worker` starts for that PR. The tick logs
  `<owner/repo>#<pr> enqueued merge-conductor-pr <key>` and, after fan-in,
  one line per project:
  `FLY-ENQUEUE <owner/repo> enqueued=<n> skipped=<n> fallback=<n>`.
  Fan-in accounts the PR `enqueued:fly`.
- **Machine.** `bin/lane-run-worker.sh` claims the row and runs
  `bin/merge-conductor-pr.sh`. The entry checks the run key and the project's
  repo, reads the PR's head once, and runs today's keyed tick for that one PR
  (`MC_ONLY_PR`, `MC_FANIN_SOLO_RUN=1`) with `MC_ON_MACHINE=1`. It prints one
  line `PROF mc-pr state=<S> reason=<words> deferred=<w|->`, which the worker
  stores in `lane_runs.prof_line`.
- **SIGTERM hand-off.** TERM to `bin/lane-run-worker.sh` during a run sends
  TERM to the run's process group, waits up to `lane_run.term_grace_s`
  (seeded 20, 1..25, code fallback 20), then KILLs the group and posts
  `POST /api/lane-runs/<id>/release`. The row goes back to `queued` with its
  `attempts` kept, and another machine resumes it. TERM with no run in flight
  exits 0 at once.
- **Worker routes** (`worker/jobs/src/routes/lane-runs.js`):
  `POST /api/lane-runs/:id/release {machine}` (200 queued; 409 `not_claimed`
  or `not_claimer`; 404) and
  `GET /api/lane-runs/by-prefix?lane=&project_prefix=[&live=1][&limit=1..50]` (rows
  newest first, `truncated` when more exist). The schema fragment
  `worker/jobs/schema.d/202610142107-bh-6495-conductor-fly.sql` adds the index
  `idx_lane_runs_lane_project` for that read and seeds the two settings rows.

## The switch

`mc_fly_workers_on <project>`: the row `conductor_workers_on_fly.<project>`
wins when it exists, else the fleet row `conductor_workers_on_fly`. Only the
trimmed value `1` is on. No row, any other value (`yes`, `true`, `2`) or a
settings outage is off. A run with `MC_ON_MACHINE=1` never enqueues, so a
machine cannot enqueue itself.

On, for one project first, then for the fleet:

    setting_set conductor_workers_on_fly.<project> 1
    setting_set conductor_workers_on_fly 1

Rollback: set the same row to `0`. The next tick starts every worker on the
hub again. Rows already queued still run on a machine once each; nothing else
reads them.

## When a PR still runs on the hub

With the switch on, a PR runs on the hub this tick, after one log line
`<owner/repo>#<pr> fallback=<word>`, when:

| word | why |
|---|---|
| `land-fire` | the base moved this tick. The land fan-out records its sha only after every worker answered (BH-870), so that project's tick stays on the hub. |
| `machine-deferred` | the newest done row of this key carries `deferred=<x>`: the machine run needed a rebase, a re-review or a landing (`land`, `enqueue`, `merge`, `settle`, `dv`). |
| `enqueue-failed` | the prefix read or the enqueue failed. The PR is never dropped. |
| `key-too-long` | `<project>.<pr>.<head12>` is not a lane name of at most 64 bytes. |

Count them on the hub: `grep -c 'fallback=' logs/merge-conductor.log`, or by
word, `grep -o 'fallback=[a-z-]*' logs/merge-conductor.log | sort | uniq -c`.

`skipped:fly-live-other-head`: a row of another head of the same PR is still
live. This head is enqueued after that row is done. No worker starts, so one
PR never runs on two machines at once.

## What a machine does not do

A machine lands nothing. It has no `builds/` record, so its verdict is the
ledger's alone and the BH-4585 CONTRADICTION park cannot fire there. Its flock
serialises against nobody. The hub has both, so the hub owns every landing.
`MC_ON_MACHINE=1` makes these answer "deferred" and write their name to
`MC_PR_DEFERRED_FILE`:

- A READY PR stops before the merge budget take, with no enqueue and no merge
  (`land`). It logs `<key> READY at <head8> on a lane-run machine`.
- `mc_enqueue` returns 99 (`enqueue`), and `mc_merge_locked` returns 99 for
  `mc_merge` (`merge`) and for `mc_enqueue` (`enqueue`): "nothing written,
  try next tick". These are second guards behind `land`.
- `conductor_settle` writes nothing and returns 0 (`settle`): no MERGED row, no
  issue close, no `deployreq` row, no stack follow, no deploy verify.
- The QUEUED settle pass and the parked-merged pass do not run. They read
  every QUEUED row of the repo, not only `MC_ONLY_PR`'s, so on a machine they
  would settle other PRs. The hub runs them on every tick.
- The tier-2 self-enqueue (`ae_project`) and the external enqueue
  (`xe_project`) do not run. Each posts `@mergifyio queue`, which is a landing.
- `mc_rebase_spawn` and `mc_rereview_spawn` return 3, the cap answer their
  callers read as "a later tick". `mc_dv_spawn` returns 3 too, but no caller
  reaches it on a machine. Their job and result files are box-local, and the
  machine stops when the run ends. No re-review is bought on a machine, so
  the box-local `CAPFILE` is never spent there.

The hub then runs that PR on its next tick (`fallback=machine-deferred`) and
keeps it on the hub until the head changes, because the result files live on
the hub. The batch train counts only rows worked on the hub, so it fires less
often while the switch is on.

## Known limits

- **The hub takes a PR back (default-safe, rescue v2 #6495).** With the
  switch on, the hub still runs a PR itself, with one `fallback=<word>` line,
  when the newest row of its key:
  - finished and failed: status `died`, an rc that is not 0 (75 =
    UNVERIFIABLE included), or no `PROF mc-pr` line (`fallback=machine-failed`,
    `mc_fly_failed_for`). Before this, the hub enqueued the same key every tick
    and nothing paged (lead review of #6624);
  - waits unclaimed `MC_FLY_QUEUE_STALE_S` or longer (default 600 s, the
    rollback line "a row unclaimed for more than 10 min"):
    `fallback=no-capacity` (`mc_fly_stale_for`). A machine that claims that
    row later lands nothing, so the overlap is reads and comments, not a merge.
- **The enqueue runs in the background.** Each row's 2 jobs-worker reads run in
  `mc_fly_launch`, a `&` job inside the same `pr_slot_wait` bound as a local
  worker, not inline one PR after another. The `FLY-ENQUEUE` counts come back
  through a tick file.
- **Row growth.** A PR that waits gets one new row per tick. Nothing prunes
  `lane_runs` yet.
- **Cost rows.** Lane-fleet cost rows carry the row's project, so a cost
  roll-up per project for lane `merge-conductor-pr` must strip `.<pr>.<head12>`.
- **Verdict reads before READY.** A machine still classifies a PR on the
  ledger verdict alone (WAIT_CI, WAIT_REVIEW). A PR whose record contradicts
  the ledger is parked when it reaches READY, because the hub then runs it.
- **A hub rebase is audited on the hub only.** A PR the hub ran
  (`deferred=rebase`) gets a new head when its rebase pushes, and the new head
  goes to a machine. The machine has no job file for that rebase, so its
  audit line is not written.

## Proof owed after merge (AC4)

Flip one quiet project, then the fleet. Post on the ticket: the hub `uptime`
and `pgrep -fc merge-conductor.sh` before and 1 hour after, the 600 s
deadline hits per hour, the `fallback=` counts by word,
`grep -c FLY-ENQUEUE logs/merge-conductor.log`, and the priced cost rows for
lane `merge-conductor-pr`.

Tests: `tests/conductor-enqueue-only.bh-6495-test.sh` (AC1, the real tick; F9 machine-failed, F10 no-capacity),
`tests/conductor-pr-claim.bh-6495-test.sh` (AC2, the real machine path),
`tests/lane-run-release.bh-6495-test.sh` (AC3),
`tests/conductor-machine-lands-nothing.bh-6495-test.sh` (a machine lands nothing),
`worker/jobs/test/lane-runs-release.bh-6495.test.js` (the routes).
