# Fly machine registry contract chunk (BH-1054)

Doc: DB-COORDINATION-SPEC

**What changed.** Added the dark `machines` table, the `fly_machines_rows='off'`
seed, the worker-side `CREATED_TABLES.machines`, `MACHINE_STATES`, and
`MACHINE_TERMINAL` constants, and five fail-open client verbs in
`bin/jobs-client.sh`: `machines-rows-on`, `machine-put`, `machines-observe`,
`machine-close`, `machines-list`. The actual `PUT /api/machines`,
`PUT /api/machines/observe`, `PATCH /api/machines/<id>`, and `GET /api/machines`
route handlers are intentionally out of scope for this slice; with this chunk
alone the flag stays `off` and every verb fails open (nonzero, no stdout)
against a worker that lacks the routes.

**Why.** The Fly pool sweep currently builds its picture of machines from
`fly machines list` and per-machine tracking files. A registry table gives the
fleet one shared, queryable source of truth for which machines exist, what role
they play, and when they disappeared. Keeping the registry dark until an
operator flips the flag lets the schema and client verbs land safely before
any route starts writing rows.

**What it touches.** `worker/jobs/schema.sql`, `worker/jobs/src/index.js`,
`bin/jobs-client.sh`, `tests/jobs-client-machines.bh-1054-test.sh`,
`worker/jobs/test/machines-schema.bh-1054.test.js`,
`docs/verification-map/fly-machines.md`,
`docs/verification-map/entries/BH-1054.md`, and this note.
