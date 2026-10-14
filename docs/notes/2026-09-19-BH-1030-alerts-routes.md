# The jobs worker answers /api/alerts: note, state, resolve, claim, flush, list, families

Doc: ALERTS-STATE-MACHINE, DB-COORDINATION-SPEC

BH-1068 shipped the `alerts` table, its `CREATED_TABLES` mirror and seven client
wrappers pointing at routes that did not exist yet. This is the worker half:
the seven paths those wrappers call, implemented against the wire spec in
`worker/jobs/README.md` `## Alerts table (2026-09-19)`. Nothing on any box calls
them until `flags/alerts-db` is set, which is the last step of BH-1030's
rollout, so deploying them changes no behaviour anywhere today.

## What shipped, in `worker/jobs/src/index.js`

Seven path matches before the terminal 404, each opening with
`await ensureTable(env, "alerts")` and stamping every column with the request's
one clock `t`:

| route | what it does |
|---|---|
| `POST /api/alerts/note` | read, `alertDecision`, then INSERT `ON CONFLICT DO NOTHING` or a CAS UPDATE; up to 3 tries, then 409 `contended` |
| `PATCH /api/alerts/state` | 404 unknown, 409 on an edge the table forbids, CAS `WHERE id=? AND state=<the state we read>` |
| `POST /api/alerts/resolve` | `UPDATE … SET state='resolved' WHERE state<>'resolved' AND id IN (…)`, `resolved` = real `meta.changes` |
| `POST /api/alerts/claim` | candidates through the shared where-builder, one CAS per row, only the rows that changed come back |
| `POST /api/alerts/flush` | the same claim, as `flush@<box>`, over quarantined rows past `alert_flush_ttl_s` with no live claim |
| `GET /api/alerts` | the filtered list, `limit` capped at 500, measured `truncated`; `group=family` returns the family counts |
| `GET /api/alerts/families` | the same handler, second path match: `lane` is the `claimed_by` prefix |

**The decision is a pure function.** `alertDecision(row, body, t, knobs)` is
exported next to `decorateLane` and holds the whole fire/remind/suppress rule —
the one `bin/lib/alert-state.sh` has been running on JSON files, in ISO time
through `ageSeconds`. New incident when the row is absent, resolved, or quiet
for `close_s`; otherwise `count + 1` and a remind when `notified_at` is
`reminder_s` old (a NULL stamp has no age and is due). No SQL in it, so the
boundaries are unit-testable without a database.

**Every write is a compare-and-swap.** Two boxes noticing the same outage in the
same second is the normal case here, not the edge, so every UPDATE carries the
state its decision was made on and the row only counts as changed when
`meta.changes > 0`: note on `(id, count, last_seen, state)`, state on
`(id, state)`, claim and flush on `(id, state, claimed_by IS NULL OR claimed_at
<= t - lease)`. A note that loses re-reads and re-decides, at most three times,
then answers 409 — no route sleeps, waits or polls.

**The knobs are rows.** `alertKnobs` reads `alert_flush_ttl_s` and
`alert_claim_lease_s` from `settings` in one query; the constants
`ALERT_FLUSH_TTL_S = 2700` / `ALERT_CLAIM_LEASE_S = 900` sit next to the read as
the documented fallback for a D1 that has no rows yet. The row wins whenever it
parses as a positive integer.

**One where-builder** serves claim, flush and list. Every value is bound; the
only strings built from code are the operators and the `IN (?k,…)` holes, the
`GET /api/wakes` precedent. `claimed_by_prefix` compares
`substr(claimed_by,1,n+1)` against `<prefix>@` rather than using LIKE, so a
prefix off the wire cannot carry a `%` and `medicine@a` never answers for lane
`medic`.

**Bounds.** `ids` is refused past 99 (D1 binds at most 100 parameters per
statement) rather than silently sliced; a claim select that also carries an id
list walks it in slices of 90 to leave room for its own predicates. Claim and
flush cap at 200 candidates, list at 500 with `truncated` measured from a
`limit + 1` read. Business inputs (`reminder_s`, `close_s`, `severity`, `state`,
`id`, `family`) are 400s out of range; `limit` is a page size and clamps.

## What is NOT here

Nothing is sent from the worker. `flush` claims a row and stamps no
`notified_at`: the box delivers and then PATCHes `quarantined -> new`, which is
the edge that stamps it. "Marked delivered without a delivery" cannot come from
this route. `resolve` moves `state` only — `claimed_by`/`claimed_at`/
`notified_at` stay as history, and the next note on the row clears the claim.
`actor` is validated and dropped: the contract table has no column for it and
`schema.sql` belongs to BH-1068.

## Assumptions this build made

- A1 list params: the ticket writes `older_than_s`/`since_s`, the README and the
  shipped client send `older_than`/`since`. Both spellings are read; accepting
  only the ticket's would make `alerts --older-than` filter nothing.
- A2 a note's body `state` opens an incident (`new` or `quarantined`) and is
  ignored on a live row, so a note can never bypass the edge table.
- A3 `GET /api/alerts/families` is a path alias of `group=family` with
  `lane` as the prefix, because the merged client already calls it.
- A4 flush age is `first_seen` (the column `idx_alerts_state` was built for), so
  a chatty incident cannot postpone its own escalation.
- A5 resolve leaves the claim columns alone.
- A6 `actor` is not persisted.
- A7 `quarantined -> new` stamps `notified_at` and leaves the claim to expire.
- A8 the note response carries `count` at the top level as well as inside
  `alert`, because `alert_note` in the client reads `.count`.
- A9 flush with no box claims as `flush`, with one as `flush@<box>`.
- A10 list orders `last_seen DESC, id ASC`; claim and flush take the oldest
  incident first (`first_seen ASC`).

## How it was verified

`worker/jobs/test/alerts.bh-1030.test.js` drives `worker.fetch` against real
SQLite (`test/lib/d1-sqlite.bh-1030.js` runs the worker's own statements over
`node:sqlite`, `t.skip` when that module is absent) with `schema.sql` applied and
the clock frozen, so the TTL and lease boundaries land on the same side of a
second every run. Ten deliberate mutations — a weakened note CAS, a stealable
claim, a dropped age filter, a `>` remind boundary, a constant `truncated:false`,
an open edge table, a counted-not-measured `resolved`, an unfiltered candidate
query, an ignored body `state`, a LIKE prefix — each turn a test red.

The shipped client was run against a local instance of these routes:
`alert-note` twice prints `fire 1` then `suppress 2`, `alerts` prints the TSV,
`alert-state`, `alert-claim`, `alert-families`, `alert-flush`, `alert-resolve`
all answer rc 0, and `alert-state` on an unknown id answers rc 2. No production
D1 was touched from the build box; `cd worker/jobs && npx wrangler deploy` is the
human step.
