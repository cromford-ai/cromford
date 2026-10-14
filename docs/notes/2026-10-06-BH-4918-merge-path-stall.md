# One slow PR worker is killed alone, and a READY row always says why (BH-4918)

Doc: MERGE-CONDUCTOR

## The cause

`bin/merge-conductor-backstop.sh` runs the keyed conductor every 5 minutes
under `timeout 240`. Without `--foreground`, `timeout` signals its whole
process group. Every `pr_worker` of the tick (`tick_project`'s
`fanin_run_sub … &` loop) is in that group, and so is `ae_project`, the pass
that posts `@mergifyio queue` after the workers. One worker stuck on a slow
GitHub read held the run until the timer fired, and the kill took every
healthy sibling and the enqueue pass with it. The next fire's `fanin_begin`
then said `enumerated 7 accounted 2 missing: … (run died before fan-in)`.

A killed worker's `gh`/`curl` child also kept fd 9, the PR's lock, until its
own call returned, so the next fire skipped that PR with `an earlier
conductor worker still holds this PR's lock`.

## What changed

- `bin/lib/fanin.sh` `mc_worker_bounded` runs `pr_worker` under a deadline,
  `MC_WORKER_DEADLINE_S` (default 180 s, `0` = none, not a number = 180). Past
  it, `_mc_kill_tree` sends TERM and then KILL 5 s later to the worker and every
  descendant in its own session. That includes the `gh`/`curl` child that holds
  fd 9, so the PR lock is freed. A descendant in another session (a `setsid`
  rebase, re-review, deploy-verify or batch-resolve lane) is left alone.
  `tick_project` launches every worker through it.
- The backstop passes `MC_WORKER_DEADLINE_CAP_S` = `MC_BACKSTOP_TIMEOUT_S` − 45,
  never under 30. The worker deadline is `min(MC_WORKER_DEADLINE_S, cap)`, and
  the cap also applies when the knob is 0, so a settings row cannot put the
  group timeout back in charge. The backstop logs
  `keyed conductor run: worker deadline capped at <cap>s under timeout <TO>s`.
  `MC_BACKSTOP_TIMEOUT_S` (default 240) replaces the literal `timeout 240`.
  Under 75 s the cap sits at its 30 s floor. At 30 s or less the timeout
  would fire first, which is why the catalog row's minimum is 60.
- New FANIN outcome words, from `mc_fanin_outcome`:
  - `killed:deadline` (plus ` rc=143`/`rc=137`): the worker was killed at its
    deadline. Once per (PR, head), through the `workerdeadline` attempt row:
    `<key> WORKER_DEADLINE: worker killed after <d>s on <head8> at stage: <the
    last line this tick logged for the PR, or unknown>` in
    `logs/merge-conductor.log`, plus one `lane-alert.sh --severity warn
    merge-conductor` with the same text.
  - `READY held:<kind>`: the row is READY, and the READY arm wrote a ready-why
    note for this head during this tick (`MC_FANIN_T0`).
  - `READY unexplained`: the row is READY with no enqueue and no note from
    this tick. Once per (PR, head), through `readyunexplained`: a
    `READY_UNEXPLAINED` log line and one warn alert.
- `bin/merge-conductor.sh`: every READY-arm return that used to leave no note
  now writes one (`mc_ready_why … logged`, so its existing log line stays the
  only line). The new kinds are `diff-unread`, `main-red`, `dep-unread`,
  `budget`, `gh-unread`, `state-moved`, `block-gate` (#4184's `not a CI-only
  block — declined` shape), `block-gate-unread`, `lead-unpinned`,
  `queue-held`, `merge-lock`, `enqueue-failed` and `merge-failed`. The per-PR
  lock skip writes `worker-locked` when the row is READY.

## Knobs

| knob | lane | default | row |
|---|---|---|---|
| `MC_WORKER_DEADLINE_S` | merge-conductor | 180 | `lane.merge-conductor.mc_worker_deadline_s` |
| `MC_BACKSTOP_TIMEOUT_S` | merge-conductor-backstop | 240 | `lane.merge-conductor-backstop.mc_backstop_timeout_s` |

`MC_WORKER_DEADLINE_CAP_S` is not a knob. The backstop sets it for its own run.
Keep `MC_WORKER_DEADLINE_S` above `MC_MERGE_LOCK_WAIT` (120 s).

## Edges

- A kill between the label/`@mergifyio queue` POST and the `QUEUED`
  transition leaves the label posted and the row READY. The next tick's queue
  read settles it.
- TERM still runs the worker's EXIT trap (the hotfix marker drop). KILL, 5 s
  later, does not, and the marker's TTL covers that.
- `fanin.sh` unreadable: the fallback stub runs `pr_worker` unbounded, as
  before. No `ps`: only the worker pid is signalled.
- A ready-why note is now fresh on more READY rows, so the sweepstall detector
  (`bin/pipeline-health.sh`) reads budget, queue-held and block-gate rows as
  held, not stalled. The READY TTL alert still pages a hold that stands.

## Live probes (hub)

```
grep -c WORKER_DEADLINE /root/harness/logs/merge-conductor.log
grep 'run died before fan-in' /root/harness/logs/merge-conductor.log | tail
grep -c READY_UNEXPLAINED /root/harness/logs/merge-conductor.log
grep 'worker deadline capped' /root/harness/logs/merge-conductor-backstop.log | tail -1
```

Suite: `tests/merge-path-stall.bh-4918-test.sh`.
