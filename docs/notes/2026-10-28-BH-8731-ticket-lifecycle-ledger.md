# BH-8731: ticket lifecycle ledger and API (lifecycle 1/6)

Doc: EVENTS

## What changed

- `build_queue` gets four nullable columns through `ensureColumns`
  (`worker/jobs/src/lib/core.d/bh-8731-lifecycle.js`): `phase`, `phase_at`,
  `phase_actor`, `question`, and the index `idx_build_queue_phase_at`.
  `status` still says where the queue row is. `phase` says where the ticket is.
- New append-only table `ticket_events` (schema.d fragment
  `202610282027-bh-8731-ticket-events.sql`), indexes `(project, ticket_key, id)`
  and `(at)`. Retention rule `ticket_events.age` archives rows older than
  `retention.ticket_events.days` (180), then deletes them.
- Phases: triaged, planned, plan_blocked, building, pr_open, in_queue,
  ejected, abandoned, merged, closed. merged and closed are terminal. The
  transition table and the owner map are `worker/jobs/src/lib/lifecycle.js`;
  `core.js` re-exports them next to `QUEUE_TRANSITIONS`.
- Owners: triage -> triaged; pool -> planned, plan_blocked, building, pr_open;
  conductor -> in_queue, ejected, merged; pr-records or resolver -> abandoned;
  board -> closed; lifecycle -> any move out of plan_blocked, abandoned or
  ejected that is not to abandoned or closed.
- `POST /api/lifecycle/transition`: an illegal or wrong-owner move is 409 and
  writes nothing. An accepted move writes one event and the phase columns in
  one batch, under one `phase IS <read>` guard (a lost race is 409 stale).
  A move needs an existing `build_queue` row (404 otherwise).
- `GET /api/lifecycle/stuck`: rows older than `lifecycle.stuck.<phase>_min`
  (seeds: plan_blocked 1440, ejected 30, abandoned 0, building 180,
  in_queue 120, pr_open 1440). A row that is not a whole number >= 0 uses
  the code default. 0 means stuck at once.
- `GET /api/lifecycle/history`: one ticket's events, newest first.
- CLI verbs `lifecycle-transition` and `lifecycle-stuck`
  (`bin/jobs-client.d/`, lib `bin/lib/jobs/lifecycle.sh`).

## Not in this slice

No lane writes a phase yet. Slices 2-6 connect triage, the pool, the
conductor, pr-records and the resolver, the board close and the lifecycle
re-entry writer.
