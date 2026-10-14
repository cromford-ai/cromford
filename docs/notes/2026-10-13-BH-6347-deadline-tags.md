# The WORKER_DEADLINE Sentry event names the step and carries pr, worker_key and deadline_secs (BH-6347)

Doc: MERGE-CONDUCTOR

## The cause

Sentry issue CROMFORD-HARNESS-E had the title `worker killed after 93s on
6a7867e3 at stage: unknown`. The title used the log-derived stage, which is
`unknown` when the worker logged nothing for the PR in this tick. The event had
no PR tag. Nothing in it told a configured 93 s deadline from a shortened one.

BH-6346 (0ae426a4) already added the step trail, the `step` tag and the `step:`
field of the lane log line. That event was sent by a harness before 0ae426a4.

## What changed

`mc_fanin_outcome` in `bin/lib/fanin.sh`, the deadline branch only:

- **The title** is `WORKER_DEADLINE: worker killed after <d>s on <head8> in
  step <step>`. A worker that reached no `mc_step` boundary reads `in step
  start`. The log-derived stage stays in `extra.stage`.
- **Three new tags**: `pr` (the PR number), `worker_key` (`<SLUG>#<n>`, the key
  of the log line and the PR lock) and `deadline_secs` (the seconds the killer
  slept, field 1 of the mark). A tag with no value is not sent. `deadline_secs`
  is sent only when field 1 is an integer.
- **Three new extra fields**: `started_at` (the mark's mtime minus
  `deadline_secs`, ISO UTC, empty when either is unreadable),
  `deadline_cfg_s` (`MC_WORKER_DEADLINE_S` as this process read it, 180 when
  unset) and `deadline_cap_s` (`MC_WORKER_DEADLINE_CAP_S`, empty when unset).

The lane log line, the lane alert, the outcome word, the mark format and the
fingerprint do not change. The send is still one per (PR, head), through the
`workerdeadline` attempts row.

## How to read a short deadline

- `deadline_secs` = `deadline_cfg_s`: the worker used the configured deadline.
- `deadline_secs` < `deadline_cfg_s` and `deadline_secs` = `deadline_cap_s`:
  the backstop's cap (`MC_WORKER_DEADLINE_CAP_S`) cut it.
- `deadline_secs` > `deadline_cfg_s`: the run waited for its PR lock
  (`MC_PR_LOCK_WAIT_S`, BH-6000), and that wait was added to the deadline.

Then compare `extra.step_s` with the normal time of that step. If the deadline
is shorter than the normal time of the step, file a ticket for that step.

## Check

- On the hub: `grep WORKER_DEADLINE /root/harness/logs/merge-conductor.log | tail -3`.
- In Sentry: the next `conductor-worker-deadline` event shows the tags `pr`,
  `worker_key` and `deadline_secs`.
- Suite: `tests/conductor-deadline-tags.bh-6347-test.sh`.
