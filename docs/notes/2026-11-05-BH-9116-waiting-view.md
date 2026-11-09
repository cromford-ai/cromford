# Mission Control: the "To do (waiting)" view (BH-9116)

Doc: DASH-TICKETS-SNAPSHOT

## What was wrong

The KANBAN pipeline and the per-project screens showed only tickets with a
build or job in flight. An open board ticket that had not started showed
nowhere. project-3 showed "building 3" while many to-dos were open, and one of the
3 was a claimed queue row with no running build.

## What changed

- **KANBAN** (`/kanban`) has a third tab, `TO DO (WAITING)`. **`/p/<project>`**
  shows the same list in QUEUES, above BUILD QUEUE.
- The view lists every open ticket of the hub's ticket snapshot that is not in
  flight, with one reason (first match wins): `not-triaged`,
  `needs-clarification`, `blocked-by`, `ready-not-queued`, `queued`,
  `deferred`, `stale-claim`, `other`. The rule and its candidate set are in the
  header of `console-ui/src/lib/waiting.js`.
- A review ticket that waits on the client or the requester is a row
  (`needs-clarification`). Any other review ticket is a PR in review, so it is
  in flight. An in_progress ticket is a row only when its claim is stale.
- The PIPELINE tab's BUILDING column and its count drop every card whose
  (project, ticket) pair the view marks as a stale claim. The header says
  `· N stale claims not counted`.
- Data path: `GET /api/dash/kanban/waiting` (a Pages Function) reads the ticket
  snapshot with the caller's cookie (that is the sign-in check), then POSTs the
  open tickets to `POST /api/waiting/state` on harness-jobs. That route reads
  triage_state, build_queue, jobs + job_heartbeats and ticket_edges in one D1
  batch of six statements, each on a primary key or an existing index. No file
  read, no box call, no write.
- A failed read is a warn banner, never an empty table.

## Knobs

Settings rows (schema.d/202611090506-bh-9116-waiting-settings.sql), with the
same numbers as code fallbacks:

- `waiting.stale_claim_min` (30): a claim or a heartbeat older than this is stale.
- `waiting.max_tickets` (2000): the most open tickets one call reads; more are
  cut and the view says so.
- `waiting.defer_lookback_min` (10080): how far back a parked or budget_stopped
  job counts as the last build answer.
- `waiting.reason_text_max` (200): the most characters of a queue or job
  reason text the view returns.

## Not covered

- GitHub-issue projects (cromford and kin) are not in the ticket
  snapshot. The view names them as "not covered".
- A `Blocked-by` that names a PR has no ticket_edges row, so it does not make
  a `blocked-by` row.
- The payload's `reconcile` block gives the parts of the total
  (`todo + review_waiting_client + in_progress_stale - todo_in_flight`) for the
  post-deploy check against the project-3 board API.
