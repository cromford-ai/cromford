# The Fly machine registry routes are wired

Doc: DB-COORDINATION-SPEC

**What changed.** The four `/api/machines` handlers in `worker/jobs/src/index.js`
now exist, on top of the BH-1054 contract chunk (`CREATED_TABLES.machines`,
`MACHINE_STATES`, `MACHINE_TERMINAL`, the `machines` table in `schema.sql`, the
five client verbs in `bin/jobs-client.sh`). None of those contract pieces was
edited; this slice only reads them.

- `PUT /api/machines` — register or correct one machine. Upsert on `machine_id`,
  `spawned_at=COALESCE(machines.spawned_at, t)` so the first register is the
  birth, optional fields COALESCEd so a thinner later call does not blank them,
  and `ended_at` cleared when the new state is non-terminal.
- `PUT /api/machines/observe` — one Fly listing, capped at 200 entries. Every
  entry is validated before any write, so one unknown state refuses the whole
  call and writes nothing. Unknown ids are registered (`role='pool'`), not
  ignored. Then one sweep statement marks the unlisted `gone`.
- `PATCH /api/machines/<id>` — close or correct. Upsert, because the close most
  likely to arrive is for a machine nobody registered. `ended_at` moves only on
  a terminal state; `detail` over 300 chars is a `400`, never truncated.
- `GET /api/machines?project=&app=&key=&live=1` — `LIMIT 500`, ordered newest
  first, each row decorated with `age_s` and `seen_age_s`.

**Why the sweep has no `NOT IN (<ids>)` list.** D1 binds at most 100 parameters
per statement, so an id list would break at 100 machines — on the exact fleet
size where the registry starts to matter. It does not need one: every listed row
is stamped `last_seen = t` in the same transaction, so `last_seen < t` IS "not
in this listing". A row that has never been listed is judged on `spawned_at`
with a 30-minute grace, because a machine created after the caller read its
listing is missing from that listing for an innocent reason.

**Why a capped observe sweeps nothing.** `gone` is the one mark in this table a
client would act on, and a partial listing cannot prove absence. Over the cap
the call processes the first 200, answers `capped:true` and `gone:0`, and leaves
the sweep owed to the next tick — defer, never drop.

**The contract disagreement, resolved in review round 1.** This slice first
shipped with `destroy_failed` refused (`400`), because BH-1054's set did not
carry it and this slice may not edit that set. That was the wrong way round:
BH-1054's own ticket spells `destroy_failed` out, the sweep writer (BH-1056)
sends exactly that close when flyctl refuses a destroy, and every writer fails
open — so the refusal would have been indistinguishable from a worker outage
and the machine the epic names as its risk would never have shown up in
`machines-list live`. Round 1 added `destroy_failed` (and Fly's `suspending`)
to `MACHINE_STATES` in the contract and flipped this test to `200`;
`destroy_failed` stays OUT of `MACHINE_TERMINAL`, so the close records the
failure and leaves `ended_at` NULL.

**What it touches.**

- `worker/jobs/src/index.js` — the four handlers, `decorateMachine`, and the
  route-local constants `MACHINE_ROLES`, `OBSERVE_CAP` (200), `OBSERVE_GRACE_S`
  (1800) and `MACHINE_DETAIL_MAX` (300). Every handler starts with
  `await ensureTable(env, "machines")` and sits behind the existing bearer
  check; every stamp comes from the request's single server clock `t`.
- `worker/jobs/README.md` — four rows in the `## API` table and the
  `fly_machines_rows=off` seed line.
- `worker/jobs/test/machines.bh-1055.test.js` — the routes driven through the
  worker's real `fetch` over a `node:sqlite` in-memory database behind a
  D1-shaped adapter, so the SQL is what is under test.
- `docs/verification-map/fly-machines.md` — the "not wired in this slice"
  language and the "machines-list returns nonzero" probe were both false after
  this change and are rewritten.

**What it does NOT touch.** No shell writer, no `bin/` change, no reader switch,
no schema change. Nothing calls these routes on a cron yet, and the
`fly_machines_rows` flag stays `off`: the worker never reads it, because the
knob belongs to the caller (`machines_rows_on` in `bin/jobs-client.sh`).
