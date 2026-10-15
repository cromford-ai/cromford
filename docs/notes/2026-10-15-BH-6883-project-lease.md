# Project lease with a fence token (BH-6883, BH-6881.1)

Doc: HARNESS-COORDINATION, MERGE-CONDUCTOR

## What changed

A new D1 table, three bearer-gated routes, one settings row and a shell
client. Nothing calls them yet. BH-6881.3 (#6887) is the first caller: the
merge conductor acquires `merge-conductor <project>` and renews before each
landing write.

- Table `project_leases` (`worker/jobs/schema.d/202610151655-bh-6883-project-leases.sql`):
  `lane`, `project`, `holder`, `fence`, `lease_until`, `acquired_at`,
  PRIMARY KEY `(lane, project)`.
- Routes (`worker/jobs/src/routes/project-leases.js`, fragment
  `worker/jobs/test/route-table.d/780-project-leases.txt`). Each route
  runs ONE statement:
  - `POST /api/project-leases/acquire {lane, project, holder, ttl_s?}`. It
    wins when there is no row, when the row's `lease_until <= now`, or when
    the row's holder is the caller. 200 `{fence, lease_until, as_of}`. Else
    409 `{error:"held"}`, and the answer does not name the holder.
  - `POST /api/project-leases/renew {lane, project, holder, fence, ttl_s?}`.
    It wins only when holder AND fence match and `lease_until > now`. Else
    409 `{error:"lost"}`, nothing written.
  - `POST /api/project-leases/release {lane, project, holder, fence}`. It
    sets `lease_until` to now (an earlier `lease_until` stays), only when
    holder AND fence match. A retried release answers 200 again. Else 409
    `{error:"lost"}`, nothing written.
  - 400 for a `lane`, `project` or `holder` that does not match
    `[A-Za-z0-9._-]{1,64}`, a `fence` that is not an integer >= 1, or a
    `ttl_s` that is not an integer in 10..900. A 400 runs no statement.
  - A D1 failure is 503 (`project_leases schema not applied` or
    `project_leases unavailable`).
- Shell client `bin/lib/project-lease.sh`: `pjl_acquire <lane> <project>
  <holder>` prints the fence; `pjl_renew <lane> <project> <holder> <fence>`
  prints `lease_until`; `pjl_release <lane> <project> <holder> <fence>`.
  rc 0 = ok, rc 3 = 409 `held` (acquire) or `lost` (renew, release), rc 1 =
  anything else (missing argument, no jobs client, transport, other status,
  a 200 without the field). The caller sources `bin/jobs-client.sh` first.
  Sourcing the lib runs nothing.

## The fence rule

The fence starts at 1. A takeover of an expired row, by any holder, sets it to
the old fence + 1, and a re-acquire of an expired row by the same holder also
does. A re-acquire of a live lease by its own holder keeps the fence and moves
`lease_until`. The fence never goes down.

## Rules for callers

- A row is never deleted. A deleted row would start the fence at 1 again, and
  a stale holder's old fence could then match. There is no retention job: the
  table holds one row per `(lane, project)`.
- The holder must be unique per process (the machine id, or the hub hostname
  for the hub). Two processes with one holder string share one lease.
- All times come from the worker's clock. A box never sends a time.

## Knob

`project_lease.ttl_s` (settings row, seed 180, bounds 10..900): the lease length
when the caller sends no `ttl_s`. A row value outside the bounds, or not an
integer, uses the code fallback 180.

## Proof

`tests/project-lease.bh-6883-test.sh` drives the real worker
(`tests/lib/project-lease.bh-6883.mjs`, node:sqlite with the composed schema).
Case 5 runs EXPLAIN QUERY PLAN on 5,000 seeded rows: every statement uses the
primary key index and none scans the table.
