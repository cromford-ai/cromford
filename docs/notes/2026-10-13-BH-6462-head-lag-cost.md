# A conductor worker traces its calls, and the head-lag refs read happens once per tick (BH-6462)

Doc: MERGE-CONDUCTOR

## The cause

Sentry issue CROMFORD-HARNESS-C: a project-4 conductor worker on box-hub
was killed at about 199 s. The step trail (BH-6346) said `head-lag` took 86 s
and 91 s. All other steps were also slow: `start` took 12 s and `lock-probe`
took 26 s, and those two steps do only local file work. The trail named the
step. It did not name the calls inside the step, so nobody could say if
GitHub, the jobs worker or the box was slow.

## The head-lag step

The step runs from `mc_step head-lag` to `mc_step verdict-read` in `pr_worker`
(`bin/merge-conductor.sh`). Its calls, in order:

| # | Call | Network | When |
|---|------|---------|------|
| 1 | `mc_lane_epoch` → `bin/account-pick.sh review claude <model>` (a child process) | the child can call the jobs worker; not traced | every PR, only with `ACCOUNT_ROUTING=1` |
| 2 | `head_lag_mins_for` → `lane_knob` → `_jobs_req GET /api/settings` | jobs, cached `LANE_GATE_CACHE_S` | once per cache window at most |
| 3 | `head_lag_tip`: the tick memo, then `prs_branch_tip` (`GET repos/<slug>/git/matching-refs/heads/<prefix>/`), then `gh_rest GET repos/<slug>/branches/<br>` | GitHub | every same-repo PR; the refs read when the cache is past its TTL; the branches read when the refs tip is not the head |
| 4 | `head_lag_rows_read` → `_jobs_req GET /api/pr-attempts` | jobs | only when the tip is not the head |
| 5 | `head_lag_note` / `head_lag_kick` → `PUT /api/pr-attempts`, the CI kick | jobs + GitHub | only on a lag |
| 6 | `mc_handoff_sticky` → `GET /api/pr-attempts`, up to 2 times | jobs | only for a `BLOCKED_HUMAN` row on a hand-off reason |
| 7 | `mc_batch_held`, `mc_contested_loser` | local files | every PR |

The step has no `git` call. Calls 2 to 6 go through `gh_rest` or `_jobs_req`,
so the trace below measures them. Call 1 is a child process. Its time is in the
step's seconds but not in the trace.

## What changed

- **The call trace.** `bin/lib/call-trace.sh` is new. `mc_worker_bounded`
  (`bin/lib/fanin.sh`) gives each worker a trace file, `<mark>.calls`.
  `gh_rest` (`bin/lib/gh-rest.sh`) writes one line per request that reached
  `gh api`. `_jobs_req` (`bin/lib/jobs/req.sh`) writes one line per request,
  retries included. A line is `<step>\t<kind>\t<method path>\t<ms>\t<status>`.
  The path loses its query string. The status is the HTTP status, `000`, or
  `curl_rc=<n>`. `mc_step` sets `MC_STEP_NAME`, the step each line names. The
  file variable is a local of `mc_worker_bounded` and is never exported, so a
  detached child writes nothing. A request a gate refused before `gh api`
  writes nothing.
- **The `calls:` segment.** On a deadline kill, `mc_worker_bounded` leaves
  `<mark>.calls` beside the mark. `mc_fanin_outcome` reads it with
  `call_trace_summary`, adds ` | calls: <summary>` to the WORKER_DEADLINE log
  line and lane alert, adds `calls` to the Sentry `extra`, and removes the file.
  The Sentry title, tags and fingerprint do not change. A normal return removes
  the file. A `.calls` file older than one day is removed by the next worker.
- **The refs pin.** `tick_project` calls `prs_refs_pin`
  (`bin/lib/pr-snapshot-refs.sh`) once, before it starts the workers, with the
  branch of each row. It reads the refs once per branch prefix and copies the
  fresh cache to `state/merge-conductor/tick/<tick>.refspin-<owner_repo>-<prefix>.json`.
  `head_lag_tip` passes that prefix to `prs_branch_tip`, and a pinned branch
  answers with no GET for the rest of the tick. Before this, each worker that
  reached head-lag after the 60 s TTL, or before the first read landed, made
  its own `matching-refs` read. In the test tick (4 PRs, a cold cache) that was
  4 reads. It is now 1. `mc_branch_exists` does not use the pin.
  `PR_SNAPSHOT=0` turns the pin off with the snapshot. `mc_tick_gc` removes old
  pin files.
- **The stage.** With no log line for the PR in this tick, the mark's stage is
  the step name (or `start`), not `unknown`. A mark written before this change
  with no stage still reads `unknown`.

## The deadline (ticket item 5): no change

The sum of the steps on a normal tick is far below 198 s. In the event, all
steps were slow together, and two of them do no network work. A longer deadline
hides that fault and does not fix it. The `calls:` segment gives the evidence
for the next decision, for example an `MC_PR_PARALLEL` ceiling on that box.

## How to read `calls:`

Example: `| calls: start jobs=1/0.1s; head-lag gh=2/1.3s jobs=1/0.2s; slowest: gh GET repos/o/r/branches/x 1.1s (head-lag)`.

- Each step lists `<kind>=<count>/<seconds>` for `gh` (GitHub REST) and `jobs`
  (the jobs worker).
- Compare a step's seconds in `| step:` and `| earlier:` with its traced
  seconds. If the step took 86 s and its traced calls took 2 s, the time went
  to work that is not a traced call (a child process, the box). If the traced
  seconds are near the step's seconds, the slowest call names the slow service.
- `none` means the worker made no traced call, or the box ran a tree without
  this change.
- The segment prints only measured numbers. It does not name a cause.

## The live probe (owed after deploy)

On box-hub, 24 h after the deploy:

```bash
grep 'WORKER_DEADLINE' /root/harness/logs/merge-conductor.log | grep -c 'example-org/project-4#'
```

The ticket asks for 0. Also read the event count of Sentry issue 7784933083.
If a kill still occurs, its `calls:` segment names the slow call.

Tests: `tests/conductor-head-lag-cost.bh-6462-test.sh`.
