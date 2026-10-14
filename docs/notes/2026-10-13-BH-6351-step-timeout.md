# A conductor worker step has its own timeout and logs STEP lines (BH-6351)

Doc: MERGE-CONDUCTOR

## The evidence

Sentry issue CROMFORD-HARNESS-G (7786053174) is a `conductor-worker-deadline`
event for project-6#191. Its title was the last lane-log line for the PR:
`-> READY head=6d12eb15 ... reason=clean, approved, checks green` at
23:44:10Z on 2026-10-12. The kill came at 23:46:48Z with a 600 s deadline.

`mc_worker_bounded` starts its deadline clock when the worker starts. So the
worker started at about 23:36:48Z (23:46:48Z less 600 s). It spent about
442 s before the READY line and about 158 s after it. This split is an
inference from the deadline and the two timestamps. It is not a measurement.
`mc_transition` logs the `-> READY` line only when the state changes, and a
quiet path logs nothing before it, so the stall can be on either side.

The step is not known from the evidence on this box. This build ran on a
pool box that has no `merge-conductor.log`, and the project-6 tick log lives
on box-hub. The STEP lines name it on the next stall.

## What changed

Main already kept a step trail per worker (BH-6346, `mc_step` in
`bin/lib/fanin.sh`), and a deadline kill named the step. This change adds:

- A per-step timeout. The watchdog in `mc_worker_bounded` polls the trail
  every `MC_STEP_POLL_S` (default 5). A step that runs `MC_STEP_TIMEOUT_S`
  (default 240, 0 = off) is killed the same way as a deadline. The FANIN
  outcome is `killed:step-timeout`. The log line is
  `<key> STEP_TIMEOUT step=<step> after <n>s on <head8> (step timeout <st>s,
  worker deadline <d>s): worker stopped; row left <state>, the next tick works
  it again`. One warn alert and one Sentry event (reason
  `conductor-step-timeout`, tag `step`) go out per (PR, head, step).
- The `enqueue` and `merge` steps wait on purpose. Their timeout is never
  under `max(MC_MERGE_LOCK_WAIT, MC_MERGIFY_WAIT_S) + 10`.
- The `lock-probe` step takes the PR lock. The READY re-kick (BH-6000) waits
  for that lock on purpose, up to `MC_PR_LOCK_WAIT_S`. Its timeout is the step
  timeout plus that wait, as the deadline adds the wait too. With no wait set,
  lock-probe has the plain step timeout.
- A step timeout that is not under the worker deadline never fires. The
  deadline fires and names the step. With the default 180 s deadline the
  default 240 s step timeout is off. It fires on a project that runs a
  longer deadline, such as project-6's 600 s.
- STEP lines. After a READY transition (`MC_STEP_LOG=1` in `pr_worker`) every
  step logs `<key> STEP_START step=<name>` and `<key> STEP_END step=<name>
  took=<n>s`. The last step's end carries `result=<rc:N|step-timeout|deadline>`.
  On any path, a step of `MC_STEP_SLOW_S` (default 60, 0 = off) or more logs
  one `<key> STEP_SLOW step=<name> running=<n>s` while it runs and a
  `STEP_END ... started=<HH:MM:SSZ>` when it ends.
- New READY-path step names: `ready-checks`, `land-rebase`, `base-guard`,
  `ticket-hold`, `prequeue`, `lead-fence`, `merge`, `settle`. `arm:<STATE>`
  now sits just before the action arms, after the land rebase.
- The trail line is `<epoch>\t<name>\t<log flag>`. The deadline mark is
  `<d>\t<stage>\t<step>\t<step_s>\t<earlier>\t<kind>\t<step timeout>`. A mark
  with 2 fields (an older writer) reads as kind `deadline`, step `unknown`.
- The WORKER_DEADLINE Sentry title is now `WORKER_DEADLINE: worker killed
  after <d>s on <head8> in step <step>`. It copies no log line. The stage stays
  in `extra.stage`, and the fingerprint is unchanged.
- `sentry_report` reads an optional `.tags` object in extra-json as extra
  tags, then deletes it from extra. A key must match `^[a-z][a-z0-9_]{0,31}$`,
  a value must be a string (cut to 200 chars), at most 8 entries pass, and the
  core tags win on a clash.

## Knobs

`MC_STEP_TIMEOUT_S`, `MC_STEP_SLOW_S` and `MC_STEP_POLL_S` are registry knobs
in `catalog/lanes.d/merge-conductor.json`. Settings rows:
`lane.merge-conductor.mc_step_timeout_s`, `lane.merge-conductor.mc_step_slow_s`,
`lane.merge-conductor.mc_step_poll_s`. No new env var is needed.

## Probe after deploy

    grep -E 'STEP_(START|END|SLOW|TIMEOUT)' /root/harness/logs/merge-conductor.log | tail
    grep -c 'STEP_TIMEOUT' /root/harness/logs/merge-conductor.log

Suite: `tests/mc-step-timeout.bh-6351-test.sh`.
