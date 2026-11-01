# Reports from the repo, not logs: per-head stuck clock, hung CI, queue presence, dead-log alert, repo activity (BH-8417)

Doc: MERGE-CONDUCTOR, MERGIFY, ARCHIE

## What changed

On 2026-10-26 at 07:2xZ the conductor's pages disagreed with GitHub:

1. `#7750` paged `STUCK: 6408m in one state ... on fe37f152`. GitHub showed
   fe37f152 committed 2026-10-25T16:24:30Z, about 15h earlier. The row had
   entered HEAD_MOVED on 2026-10-21T20:34Z, and `mc_transition` keeps
   `since` when the head moves inside one state.
2. `#7750`'s Harness CI run had been `in_progress` for 15h. No line said
   the run was hung.
3. `#7646` read QUEUED for 3.5 days. `mc_mergify_inqueue` returns 0 for our
   `merge-queue` label plus a row that was QUEUED on the last tick, so no
   witness was asked again. Mergify did not hold the PR.

## The rule now

### Per-head stuck clock

- `mc_ci_state` (`bin/lib/mc/classify.sh`) sets four globals from the
  actions/runs body it already reads. There is no new GitHub read.
  `MC_HEAD_COMMIT_TS` is the newest `head_commit.timestamp` of a run on this
  sha, as epoch. `MC_HEAD_COMMIT_SHA` is that sha. `MC_CI_RUNS` is one
  `id|name|status|started-epoch` line per latest run of each workflow, and
  `MC_CI_RUNS_SHA` is its sha. Its stdout word does not change.
- `mc_headclock_note` (fragment `bin/merge-conductor.d/bh-8417-head-clock.sh`)
  keeps that time in `state/merge-conductor/head-clock/<key>_<head12>`. A
  tick whose CI word comes from the memo reads it back.
- `mc_stuck_check` measures `age = now - max(since, head commit time)`. It
  uses the since clock when the time is for another sha, empty, in the
  future or not a number. The page prefix `STUCK: <n>m in one state (TTL
  <t>m) on <sha8>` does not change (`bin/triage-spool-retire.sh` reads it).
  The page and the log line add `head <sha8> committed <iso>, in <STATE>
  since <iso>`, or `head <sha8> (head time unknown), in <STATE> since <iso>`.

### Hung CI

- `mc_ci_hung_check` (same fragment) reads `MC_CI_RUNS` only. A latest run
  whose status is not `completed` and whose `run_started_at` is
  `MC_CI_HUNG_AFTER_S` or more ago is `CI run <id> hung <n>m`.
- Once per (PR, head): mark `cihung <key> <head> <id>`, then POST
  `actions/runs/<id>/cancel`. On a later tick, when that run reports
  `completed`: mark `cihungrerun <key> <head> <id>`, then POST
  `actions/runs/<id>/rerun`. This rerun spends the head's shared `cirerun`
  mark when no other arm has spent it, so the flake ladder does not re-run
  the same run again. The rerun asks `mc_head_still` first (BH-3804).
- A second hang on the same head after the rerun: one page
  `CI_HUNG_TWICE` (mark `cihungpage`) and nothing more.
- Observe mode: one WOULD line, no mark. The cancel takes one unit of the
  stuck-timer budget (`MC_STUCK_TIMERS_MAX_PER_TICK`). A failed POST is one
  `cancel-failed HTTP <c>` or `rerun-failed HTTP <c>` line; the mark stays.

### Queue truth

- `bin/merge-queue-reconcile.sh` keeps each 2xx Mergify
  `merge-queue/status` answer in
  `state/merge-queue-status/<owner>_<repo>.json`, with `fetched_at` added
  (tmp + mv). A failed read leaves the last good file.
- `mc_queue_presence` (fragment `bin/merge-conductor.d/bh-8417-repo-truth.sh`)
  answers `present` (the PR is a batch member or waiting, or it carries
  Mergify's own `queued`/`checking` label), `absent` (a fresh file does not
  list it) or `unknown` (no file, a file older than
  `MC_QUEUE_STATUS_STALE_S`, a file read before the row entered QUEUED, a
  body that does not parse). `unknown` never acts.
- A QUEUED row that is `absent` logs `ROW DISAGREES WITH GITHUB: queue` on
  every tick. Past `MC_QUEUE_ABSENT_AFTER_S` (clock file
  `state/merge-conductor/queue-absent/<key>_<head12>`), it gets ONE
  `@mergifyio requeue` per (PR, head) through the `requeued` mark that BH-636
  and BH-3480 share (mark first), and ONE page per (PR, head) (`qabsentpage`)
  that starts `not in Mergify queue <n>m (label merge-queue present, Mergify
  status <iso>)`. The row becomes QUEUED only when Mergify acknowledged the
  requeue; otherwise WAIT_CI. The tick's own `mc_transition` writes it.
- The reconciler reads only repos with an active queue row in the jobs DB
  (last 24 h). A repo outside that list has no file, so its presence is
  `unknown` and nothing acts.

### GitHub facts on every page

- `mc_repo_truth` runs once per PR, right before the tick's `mc_transition`.
  It builds `MC_GH_FACTS` from what the tick already read:
  `open mergeState=<ms> head=<sha8>@<iso|unknown> ci=<word> (newest run <id>
  <status> <n>m)[; CI run <id> hung <n>m] queue=<present|absent [n]m|unknown|n/a>
  as of <iso>`.
- A QUEUED or WAIT_CI row logs `<key> <STATE> github: <facts>`. The STUCK
  page carries `github: <facts>` in its detail.

### Dead-log detector (hub lane `log-freshness`, `*/15`)

- `bin/log-freshness.sh` reads `catalog/log-freshness.d/*.tsv`, one file per
  log: `<log>\t<expected cadence s>\t<owning lane>\t<reader>`. Seeded:
  `logs/archie-fm-watch.log` (600 s), `logs/archie.log` (900 s),
  `logs/ALERTS.log` (3600 s, owner `pipeline-health`).
- A log is judged by its newest line's leading ISO stamp, else its mtime.
  Older than `LOG_FRESHNESS_MULT` x cadence, or absent: ONE ALERTS line per
  (log, day) that names the lane and the newest line's time. Day markers live
  in `state/log-freshness/` and are pruned after `LOG_FRESHNESS_KEEP_D` days.
- `logs/archie-fm-watch.log` stopped on 2026-10-19 because `_jobs_req`
  answers rc 2 on every 404, and the worker's row miss
  (`{"error":"archie action not found"}`) was read as "route absent". Now
  `afw_route_absent` reads the body: a row miss fails only that finding and
  the loop goes on; a real route-absent is one ALERTS line per day. Every
  acting tick writes a `tick findings=<n>` line.
- `bin/archie.sh` writes `tick due=0` on a tick with nothing due, so a quiet
  tick is not a dead log.
- The Archie turn rule (`prompts/archie-soul.d/15-operating-loop.md`) reads
  stop-the-line findings from `logs/ALERTS.log` and `bin/repo-activity.sh`
  first, and `logs/archie-fm-watch.log` only when its newest line is under
  30 min old.

### Archie reports from the repo

- `bin/repo-activity.sh <owner/repo> [--since <iso|Nh>]` (default 6h) prints
  `<iso> <kind> #<n> <sha8> <detail>` for kinds `merged`, `opened`, `closed`,
  `push` and `ci`, from `pulls?state=all&sort=updated` and
  `actions/runs?created=>=<since>` through `gh_rest` (ETag). A failed read
  prints `UNREADABLE <endpoint> HTTP <code>`, no event lines, and exits 75.
  The page cap `REPO_ACTIVITY_MAX_PAGES` prints `INCOMPLETE <endpoint>
  pages=<n>`. A `push` needs a head seen on an earlier run
  (`state/repo-activity/<owner>_<repo>.heads`).
- `archie_repo_activity_block` (`bin/lib/archie-repo-activity.sh`) runs it for
  cromford and every fleet.conf repo over the last
  `ARCHIE_REPO_ACTIVITY_SINCE_H` hours (default 6), capped at
  `ARCHIE_REPO_ACTIVITY_LINES`; UNREADABLE and INCOMPLETE lines are always
  kept. `bin/archie.sh` puts it in the check prompt, and `compose_v2_prompt`
  (`bin/orchestrate.sh`) in the operator's chat-turn briefing.
- `prompts/archie-soul.d/25-repo-truth.md`: a merged, queued or stuck claim
  cites a repo-activity line or a conductor `github:` facts string, never a
  log line alone.

## Knobs

| Row | Default | What |
|---|---|---|
| `lane.merge-conductor[.<project>].mc_ci_hung_after_s` | 5400 | seconds before a not-completed run is hung |
| `lane.merge-conductor[.<project>].mc_queue_absent_after_s` | 1800 | seconds a QUEUED row may be absent from Mergify before the requeue and page |
| `lane.merge-conductor.mc_queue_status_stale_s` | 600 | age past which the Mergify status file is `unknown` |
| `lane.merge-conductor.mc_head_clock_keep_d` | 14 | days a head-clock or queue-absent file is kept |
| `lane.log-freshness.log_freshness_mult` | 3 | a log is stale past this multiple of its cadence |
| `lane.log-freshness.log_freshness_keep_d` | 7 | days a dead-log day marker is kept |
| `REPO_ACTIVITY_MAX_PAGES` (`_lib.repo-activity`) | 5 | pages per endpoint per repo-activity run |
| `lane.archie.archie_repo_activity_lines` | 40 | event lines in the Archie block |

## Tests

`tests/mc-head-clock.bh-8417-test.sh`, `tests/mc-ci-hung.bh-8417-test.sh`,
`tests/mc-queue-absent.bh-8417-test.sh`, `tests/mc-repo-truth.bh-8417-test.sh`,
`tests/mc-replay-1026.bh-8417-test.sh` (the 10-26 facts through the whole
`bin/merge-conductor.sh`), `tests/log-freshness.bh-8417-test.sh`,
`tests/archie-fm-watch-404.bh-8417-test.sh`, `tests/repo-activity.bh-8417-test.sh`.
