# BH-7748: the ticket-hold step is bounded and names its call in flight

Ticket: example-org/cromford#7748 (Sentry CROMFORD-HARNESS-N). A merge
conductor worker on box-hub (project-2) was killed at its 600 s
deadline in step `ticket-hold`. The event named the step but no call.

Doc: MERGE-CONDUCTOR

## What changed

- `to_lane_hold` (`bin/lib/ticket-ownership.sh`) runs `to_merge_hold` under
  the merge-conductor knob `MC_TICKET_HOLD_TIMEOUT_S` (default 90 s, 0 or not a
  number = no bound). The value used is never past `MC_WORKER_DEADLINE_AT`
  minus 15 s. With under 1 s left, no read starts and the PR is held this pass.
- Past the bound, the check's process tree gets TERM, then KILL 3 s later. The
  PR is held (rc 0, not merged) this pass. One line goes to the lane log:
  `<slug>#<num> TICKET_HOLD_TIMEOUT call=ticket-hold/<name> took=<n>s timeout=<t>s rc=124: ...`.
  The MERGE_HELD why is `the hold check timed out (call <name>) — ...`. No
  alert and no Sentry event. A late answer after the bound is still held.
- `to_merge_hold` names each read before it starts (`to__call`), in the BH-7029
  call-file format: `auth`, `pr-thread`, `issue-repo`, `pr-read`, `lead-row`,
  `ticket-thread`, with the prefix `ticket-hold/`. In a conductor worker the
  file is `MC_CALL_FILE`. After a held answer in step `ticket-hold` it names
  `ticket-hold/hold-note`; after any other answer it is emptied.
- `mc_fanin_outcome` (`bin/lib/fanin.sh`): the WORKER_DEADLINE line and alert
  carry ` | call: <path> (<n>s)` before ` | calls:` when a call was in flight.
  The Sentry event adds the tag `call` and the extras `call` / `call_s`. The
  title and fingerprint do not change. With no call, the line is as before.

## Why the PR is held, not passed, on a timeout

At the conductor call site, `to_lane_hold` rc 0 means "do not merge" and any
other rc means "go on". A timed-out read that returned non-zero would merge a
PR whose HOLD was never read. So the timed-out CALL ends with rc 124 (in the
log line), and `to_lane_hold` holds the PR this pass, like the existing
"could not be read" paths. The worker then returns at once.

## The knob

`catalog/lanes.d/merge-conductor.knobs.d/MC_TICKET_HOLD_TIMEOUT_S.json`,
`required: true`, so `lane_env_apply merge-conductor` exports the default 90
when there is no settings row. Settings row:
`lane.merge-conductor.mc_ticket_hold_timeout_s`. A lane that does not load the
merge-conductor knobs reads it unset and runs the check unbounded, as before.
A process the conductor starts inherits the exported value.

## Check on a box

    grep -E 'TICKET_HOLD_TIMEOUT|WORKER_DEADLINE.*call: ticket-hold' /root/harness/logs/merge-conductor.log | tail -5

Tests: `tests/ticket-hold-bound.bh-7748-test.sh`.
