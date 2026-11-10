# BH-9253: batch victims are requeued solo, and the resolver keeps a rung floor per project

Date: 2026-11-09. Ticket: example-org/cromford#9253.

## What happened

- 2026-11-08 09:22-09:44Z, hub-2. #9141 #9132 #9130 #9103 had green Harness CI on their own heads. Mergify batched them. The batch drafts failed on "Tests, traced (shard 7/12)", and Mergify dequeued every member with `BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS`. The conductor counted a second ejection and parked all four `BLOCKED_HUMAN queue-ejected-twice` at 12:01Z.
- 11:58Z. A resolver tick logged `rungs=0/50 reason=drained visited=[project-5]` and `HANDOFF-WAIT summary: 50 hand-off(s) not dispatched this tick`. No line alerted.

## What changed

1. Conductor: the batch-victim rule (`bin/merge-conductor.d/bh-9253-batch-victim.sh`, `mc_bv_solo`). A queue-ejected-twice PR is a batch victim when its newest Mergify dequeue code is in `MC_BATCH_VICTIM_CODES`, its own-head CI is green (`mc_ci_state`, required checks only), its APPROVE is bound to that head and the live head is that head, and it was not requeued solo on that head before. The conductor then adds `queue-solo` and requeues it alone. It does not park it. The rule runs in the settle pass and in the parked-row pass, once per head. If the solo run fails too, the next ejection parks the PR as before.
2. `bin/lib/queue-risk.sh`: `qr_enqueue_step` keeps a `queue-solo` label on a batch route when `QR_KEEP_SOLO=1`. Without that, enforce mode would delete the label in the same requeue.
3. Resolver: a per-project floor (`bin/blocked-resolver.d/bh-9253-project-floor.sh`). In a run that holds several projects, a project that already holds `BR_PROJECT_FLOOR` rungs does not take the last rungs while another non-held project with rows still ahead holds fewer. The skipped row waits for the next tick (`PROJECT_FLOOR` line). A one-project run is unchanged.
4. Resolver: the zero-dispatch alert. A tick that ran 0 rungs while at least one of its own candidates got no `dispatched`, `lock-held`, `held` or `acted` ack this tick writes one line, `bin/alert-line.sh --id br-zero-dispatch:<scope>`, and one `ZERO_DISPATCH` log line. It reads only this run's own rows and ack files.

## Knobs (settings rows, code fallback in brackets)

| Knob | Row | Fallback | Kill switch |
|---|---|---|---|
| `MC_BATCH_VICTIM` | `lane.merge-conductor.mc_batch_victim` | 1 | 0: every batch ejection parks as before |
| `MC_BATCH_VICTIM_CODES` | `lane.merge-conductor.mc_batch_victim_codes` | `BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS` | an empty or unknown code: no victim |
| `BR_PROJECT_FLOOR` | `lane.blocked-resolver.br_project_floor` | 1 | 0: the list order alone decides |
| `BR_ZERO_DISPATCH_ALERT` | `lane.blocked-resolver.br_zero_dispatch_alert` | 1 | 0: no line |

The solo requeue spends one unit of `MC_REQUEUE_CAP`. No `.mergify.yml` change: the `solo` queue and its label rule exist since BH-5430.

## Not changed

- The hub cron runs one resolver run per project (`--dispatch`). A project run holds one project, so the floor changes nothing there. The 11:58Z `HANDOFF-WAIT` summary most probably counted claims from a sibling run in the shared `handoffs/tick-cands`. This box cannot read hub-2's logs to prove it. Per-project hand-off dirs are a state-format change for their own ticket.
- A `fix-main-red` PR takes the hotfix rule even with `queue-solo`. The hotfix queue is batch_size 1 already.

## Tests

- `tests/mc-batch-victim.bh-9253-test.sh`
- `tests/resolver-project-floor.bh-9253-test.sh`
