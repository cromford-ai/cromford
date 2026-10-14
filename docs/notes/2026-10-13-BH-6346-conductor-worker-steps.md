# A conductor worker names its step at a deadline kill, stops at a 401, and caps its lock waits (BH-6346)

Doc: MERGE-CONDUCTOR

## The cause

Sentry issue CROMFORD-HARNESS-A had 119 `conductor-worker-deadline` events.
The worker for cromford#6176 was killed at 600 s, and the event said
`at stage: unknown`. The stage was the last `merge-conductor.log` line that
named the PR. A worker that logs nothing before it stalls gives no stage.

The same tick ran 2909 s and logged HTTP 401 answers. A worker went on
sending reads after a 401, and each one got another 401. Two project locks,
the merge lock and the git lock, can wait 120 s and 180 s inside a worker,
and that wait counts against the worker deadline.

## What changed

- **The step trail.** `mc_worker_bounded` (`bin/lib/fanin.sh`) gives each
  worker a step file, `<mark>.steps`, with one `<epoch>\t<name>` line per step.
  The first line is `start`. The file is removed when the worker returns or is
  killed. A `.steps` or `.auth` file older than one day (a tick killed whole)
  is removed by the next worker. `pr_worker` calls `mc_step <name>` at 13 step
  boundaries: `lock-probe`, `head-lag`, `verdict-read`, `rebase-result`,
  `ci-read`, `identity`, `diff-scan`, `classify`, `arm:<STATE>`, `dep-gate`,
  `state-guard`, `block-gate`, `enqueue`.
- **The deadline mark** is now `<d>\t<stage>\t<step>\t<step_s>\t<earlier>`. No
  field is empty (an empty stage is `unknown`, an empty `earlier` is `none`),
  because the reader splits on tabs and IFS joins empty fields.
- **The WORKER_DEADLINE line**, lane alert and Sentry text keep the old
  prefix and end `| step: <step> (<n>s) | earlier: <name>=<n>s ...`.
  `earlier` holds at most 300 bytes. Steps that do not fit are counted as
  ` +N more`.
- **The Sentry event** carries a `step` tag and the extra fields `step`,
  `step_s` and `earlier`. `sentry_report` takes an optional 6th argument, a
  JSON object of extra tags. Only string values are kept, each cut to 200
  chars, and the five standard tags win on a clash. The fingerprint
  `[lane, project, reason]` does not change.
- **The 401 stop.** The worker's 401 marker is `<mark>.auth`
  (`GH_REST_AUTH_FAIL_FILE`, a local, never exported). `gh_rest` creates it
  on a 401 (`GH_REST_REASON=auth`). The `gh()` wrapper in
  `bin/lib/gh-limit-logger.sh` creates it on a 401 stderr. After that, every
  `gh_rest` call of the worker answers rc 75, status 401, reason
  `auth-skipped`, and sends no request (`bin/lib/gh-rest-auth.sh`). At the next
  step boundary `mc_step` writes one line and exits the worker:
  `<KEY> AUTH_401: a GitHub call answered HTTP 401 during step <prev>; worker stopped after <n>s before step <next>, the next tick retries`.
  The fan-in outcome is `skipped:auth`. It clears the fan-in streak on
  purpose: a solo run does not cure a bad token. The line pages nothing.
- **The lock-wait cap.** `mc_merge_locked` and `mc_git_locked`
  (`bin/lib/mc/locks.sh`) wait at most `MC_MERGE_LOCK_WAIT` /
  `MC_GIT_LOCK_WAIT`, and inside a worker at most the seconds left before
  the worker deadline less 15 s (`mc_lock_wait_left`). With less than that
  left they answer 99 at once, which every caller already reads as "nothing
  written, the next tick tries again". The knobs keep their values and
  meaning. Outside a worker nothing changes.
- **The PR lock** was already `flock -n`: a worker skips a PR another worker
  holds and does not wait. The suite pins that.

## Not done here

Ticket item 3, "use the step data from the next events to find the slow step,
then cut it", needs the events this change produces. It is the next action
after this change is deployed.

## Probes (hub)

- `grep WORKER_DEADLINE /root/harness/logs/merge-conductor.log | tail -3`:
  each line ends `| step: <name> (<n>s) | earlier: ...`.
- `grep AUTH_401 /root/harness/logs/merge-conductor.log | tail`: lines only
  while a token answers 401.
- `grep FANIN /root/harness/logs/merge-conductor.log | grep skipped:auth`.
- Sentry issue CROMFORD-HARNESS-A: new events carry a `step` tag.

Suite: `tests/conductor-worker-steps.bh-6346-test.sh`.
