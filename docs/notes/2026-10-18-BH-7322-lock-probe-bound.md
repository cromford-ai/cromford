# The lock-probe body read has a time bound (BH-7322)

Doc: MERGE-CONDUCTOR

## The gap

Sentry issue CROMFORD-HARNESS-H: "merge-conductor: worker killed at 53s
deadline in step lock-probe (project-9)". The hub log for that event
(box-hub, 10:27-10:28:30Z) was not read: the builder box has no copy.

The `lock-probe` step of `pr_worker` (bin/merge-conductor.sh, `mc_step
lock-probe` up to `mc_step lane-epoch`) makes these calls:

| call | file | can it wait? |
|---|---|---|
| `hotfix_pending_is` | bin/lib/mc/locks.sh | no: one grep on a local file |
| `exec 9>` + `mc_pr_lock_take` | bin/lib/mc/locks.sh | `flock -n` (no wait) on every cron and backstop tick. `flock -w $MC_PR_LOCK_WAIT_S` only on a READY re-kick, and `mc_worker_bounded` adds that wait to the deadline |
| `mc_record_for` | bin/lib/mc/classify.sh | local: a glob over builds/*/RESULT. No lock, no network |
| `mc_enrolled_pr` -> `pr_attempt_has` | bin/lib/jobs/jobs.sh | jobs worker call, `curl -m $JOBS_TIMEOUT`, one retry |
| `mc_is_harness_pr` -> `pr_body_read` -> `mc_pr_view` -> `gh_rest` | bin/lib/mc/classify.sh, bin/lib/gh-rest.sh | **no bound.** `gh_rest` runs `gh` under `timeout` only when the caller sets `GH_REST_TIMEOUT_S` (BH-6810), and `pr_body_read` did not |

The PR body read was the one external call in the step with no time bound. A
stalled GitHub read held the worker until `mc_worker_bounded` killed it.

## What changed

- `pr_body_read` sets `GH_REST_TIMEOUT_S` from the new knob
  `MC_PR_PROBE_READ_TIMEOUT_S` (default 20 s, 0 = off, not a number = 20;
  settings row `lane.merge-conductor.mc_pr_probe_read_timeout_s`). The bound is
  capped by `mc_lock_wait_left`: the time left before `MC_WORKER_DEADLINE_AT`
  minus 15 s. Under 1 s left, the read is not sent.
- A read the bound cut (rc != 0 and elapsed >= bound), or one not sent, writes
  `timeout<TAB><elapsed s><TAB><bound s>` into the body flag file and calls
  `mc_probe_timeout_note`. Any other unread leaves the flag file empty, as
  before. The rc is 75 either way, so the probe arm in the conductor still logs
  its deduped "body unread" line and returns 0.
- `mc_probe_timeout_note` marks the worker locked for fan-in
  (`mc_fanin_mark_locked`: outcome `skipped:locked`), writes one line, and
  writes a `probe-timeout` ready-why note on a READY row (outcome
  `READY held:probe-timeout`). No alert, no Sentry event. The line:

  `<slug>#<n> LOCK_PROBE_TIMEOUT step=lock-probe call=pr-body-read elapsed=<e>s bound=<b>s: the PR body read did not answer; treated as locked, the next tick probes it again`

  A read not sent says `bound=0s (no worker time left)`.
- A WORKER_DEADLINE kill in step `lock-probe` names the PR lock in the Sentry
  title, `... in step lock-probe (lock <MC_LOCK_DIR>/merge-conductor-<project>-<n>.lock)`,
  and in `extra.lock`. Other steps keep the title they had. The fingerprint is
  `[lane, project, reason]`, so the longer title does not split the issue. The
  WORKER_DEADLINE log line and alert are unchanged.

## Limits

- A worker with 15 s or less to its deadline sends no body read: the PR is
  treated as locked and probed again next tick. `mc_window_cap` already
  refuses to start a worker with under 15 s.
- The cause is assumed, not proven against the hub log. If the next event in
  step lock-probe still fires, its `calls` extra (BH-6462 call trace) shows
  whether a gh or jobs call ran long, and the title names the lock.

Test: tests/mc-lock-probe-bound.bh-7322-test.sh.
