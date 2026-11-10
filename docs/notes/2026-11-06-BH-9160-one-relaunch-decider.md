# One relaunch decider: the queue refuses plan_blocked/abandoned keys; the watchdog holds a call-guard review row (BH-9160, the rest of BH-8734)

## What changed

- `POST /api/queue` (`worker/jobs/src/routes/queue.js`) answers
  `409 {error:"phase_refused", phase, project, key, reason}` for a BUILD
  enqueue (status `queued`) of a row whose `phase` is `plan_blocked` or
  `abandoned`. The check runs before every other answer and every write, so a
  refused relaunch writes no row, bumps no attempt and rings no wake.
  - The body field `actor` set to exactly `lifecycle` re-enters the ticket. No
    trim, no case fold.
  - A NULL phase, any other phase, no row, and a `ready` put (BH-1033) keep
    their answers from before.
- `queue_put` (`bin/lib/jobs/queue.sh`) sends `JOBS_QUEUE_ACTOR` as `actor`
  when it is set. On the phase 409 it returns rc 3 and prints
  `refused <phase>`. Every other failure stays rc 1. The POST goes through the
  new private helper `_queue_put_send`.
- The run-build fly enqueue block (`bin/lib/rb/gates.sh`, between the
  `# >>> fly queue enqueue` markers) reads rc 3. It writes one project-log line
  and `RESULT "QUEUED_FLY <KEY> (refused: ticket phase <p>; not queued)"`. It
  writes no file job on the hub or on a watcher and no
  `QUEUE ROW REFUSED OR UNREACHABLE` ALERTS line. rc 1 keeps the outage
  fallback unchanged.
- New route `POST /api/lifecycle/note` (`worker/jobs/src/routes/lifecycle-note.js`,
  bearer-gated): body `{project, ticket_key, actor, reason, pr?}`. It appends
  one `ticket_events` row with from = to = the row's phase (`none` when the row
  has no phase) and moves no phase. The actor is a lifecycle actor or
  `watchdog`. The same (project, ticket_key, actor, reason) is written once; a
  repeat is `200 {duplicate:true}`. No build_queue row is `404 no_row`. Client:
  `lifecycle_note` in `bin/lib/jobs/lifecycle.sh`.
- `bin/jobs-watchdog.sh` deferred sweep (the operator, comment 6502199389 on #8734):
  an `RR-*` or `LR-*` row whose reason holds `call-guard repeat` is never
  re-queued when the refusal's head starts with the key's head8. The sweep
  writes one note (actor `watchdog`) that names the standing verdict on that
  head (word, source, verdict row id), else the box verdict word, else "no
  verdict recorded on this head". It latches `<p>/<k>#cg` in
  `state/jobs-watchdog-cg-noted.txt` (box-local, a copy of the event row) only after the note returns 0. If the
  verdicts cannot be read or the note fails, the row is not re-queued and the
  next tick tries again. The `scan:` line adds
  `N call-guard review row(s) held terminal`. Nothing resets the call guard.

## What is live, and what is not

- The refusal is inert on main today. No code writes `plan_blocked` or
  `abandoned` into `build_queue.phase` yet. The writers are #8733 (PR #8910)
  and #8732 (PR #8927). When they merge, the refusal becomes the one decider.
- The watchdog hold does not depend on phases. It is live when this merges.
- NOT in this change: item 2 of #9160 (orphan-reconcile drops its thread scan
  and the `STRANDED_SKIP_PLAN_BLOCKED` knob). If the scan goes before a phase
  writer lands, the triage tick relaunches PLAN_BLOCKED tickets again (the
  BH-8467 loop that BH-8707 fixed). It needs a child ticket with
  `Blocked-by: #8733 (hard)`.

## Knobs

None. The refused-phase set and the `lifecycle` actor are lifecycle vocabulary
(`worker/jobs/src/lib/lifecycle.js`), not limits. The note's 500-character
reason bound is the transition route's validation bound.

## Tests

- `worker/jobs/test/queue-phase-refusal.bh-9160.test.js` (W1-W13)
- `worker/jobs/test/lifecycle-note.bh-9160.test.js` (N1-N8, N8 is the EXPLAIN
  QUERY PLAN at 10 000 queue rows and 200 000 events)
- `tests/queue-phase-refusal.bh-9160-test.sh` (Q1-Q5, G1-G4, real worker on
  node:sqlite behind real curl)
- `tests/jobs-watchdog-cg-terminal.bh-9160-test.sh` (C1-C8, real watchdog,
  stub curl)
