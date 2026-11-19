# BH-9695: a second ejection with no named cause gets one Mergify event read and one more requeue

Doc: MERGIFY, MERGE-CONDUCTOR

Refs #9427 (scope 4). Slice C3 of 4.

## What changed
- At the second ejection of a head (`EJN >= 2`) on a Mergify repo, when the
  newest eject-cause record line for the head says `unknown`, the conductor
  reads Mergify's activity log for the PR ONE time:
  `GET $MERGIFY_API_URL/repos/<owner>/<repo>/logs?pull_request=<n>&event_type=action.queue.leave&per_page=<k>`.
  The seam is `bin/lib/vendor/mergify.sh` (`mergify_queue_leave_events`).
- `mc_eu_event_cause` takes the newest `action.queue.leave` event that is not
  a merge and whose `metadata.pull_request_head_sha` is this head (or null).
  It maps `metadata.dequeue_code`, `metadata.unsuccessful_checks` and
  `metadata.reason` to the eject-cause words:
  - `CHECKS_FAILED` or `BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS` with check
    names: `checks (<names>)`
  - `CONFLICT_WITH_BASE_BRANCH`: `conflict`
  - `CHECKS_TIMEOUT`: `timeout`
  - any other code, or no code and a reason: `other (<code>: <reason>)`
  - no such event, a failed read, or no code and no reason: `unknown`
- A named cause: the park happens as before. The reason names the cause
  (ec_summary reads the new record line).
- Still unknown: the conductor requeues the head one more time, and does not
  park it. The row goes QUEUED `queue-ejected: requeued once more on <h8> (no
  named cause after the Mergify event read)`.
- The ejection after that parks BLOCKED_HUMAN `queue-ejected-twice: <summary>
  — no named cause after the Mergify event read and one more requeue
  (BH-9695)`. That is the cap. Every reader that matches the
  `queue-ejected-twice` prefix works as before.

## The marks (conductor attempts ledger)
- `ejunkread <key> <head>`: the one event read, written BEFORE the read.
- `ejunkrq <key> <head>`: the one extra requeue, written BEFORE the requeue.
  Then `requeued`, then the `reejected` line is cleared, so the head is in the
  state of a first requeue. A refused requeue puts `reejected` back.
- `eupark <key> <head> park:<why>`: a final park answer (named, named-event,
  extra-spent, solo-tried, culprit), logged once.

## The record (`$MC_STATE_DIR/eject-cause/<repo>_<n>`)
Two new values of the ord field: `event` (the Mergify event read) and `extra`
(the ejection after the extra requeue).

## What does not get the extra requeue
A named record cause, an event that names a cause, a head that had its extra
requeue, a batch victim (`batchvictim`: its solo try was its one extra), a
culprit head (`dqwculprit`), a park already handed to the fix round
(`ejectfix`), a stale-dequeue park (no record line), a native-queue repo, a
head that moved or lost its bound APPROVE, observe mode, and
`MC_EJECT_UNKNOWN_REQUEUE=0`.

## Knobs
- `MC_EJECT_UNKNOWN_REQUEUE` (default 1; settings row
  `lane.merge-conductor.mc_eject_unknown_requeue`). 0 = off.
- `MC_EJECT_EVENT_READS` (default 3 per project per tick; settings row
  `lane.merge-conductor.mc_eject_event_reads`). 0 = no read; the extra
  requeue still runs. Over the budget the park waits with no fix round, and
  the parked-row pass asks again next tick.
- `MERGIFY_API_TIMEOUT_S` (default 10) and `MERGIFY_EVENTS_PER_PAGE`
  (default 10), env only (catalog/lanes.d/_lib.vendor-mergify.knobs.d/).
- `MC_REQUEUE_CAP` (shared): the extra requeue takes one unit.

## Log lines
- `EJECT_UNKNOWN_EVENT <key> <h8> <cause> (<detail>)`, once per read.
- `EJECT_UNKNOWN_REQUEUE <key> <head>`, once per extra requeue.
- `EJECT_UNKNOWN_PARK <key> <h8> <why>`, once per (key, head, final why).

## Turn it off
Set the settings row `lane.merge-conductor.mc_eject_unknown_requeue` to 0.

## Operator step
The contract suite `tests/contract/mergify.bh-9695.contract-test.sh` reads
the repo secret `MERGIFY_API_TOKEN`. Without it the suite prints `SKIP vendor:
MERGIFY_API_TOKEN is not set`. On the hub the token is in env/global.env.

## Tests
`tests/mc-eject-unknown.bh-9695-test.sh` (fake seam, 0 vendor calls) and the
contract suite above (not in the PR loop).
