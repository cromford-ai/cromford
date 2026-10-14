# Product proposal rows: the table and the shell client (BH-2531 part 1, BH-2717)

Doc: DB-COORDINATION-SPEC

## What changed

- **`worker/jobs/schema.sql` gains `product_proposals`,** appended at the end
  and keyed `PRIMARY KEY (project, proposal_id)`. `proposal_id` is the
  run-product slug, `record` is the ledger entry as JSON text, and `status` is
  one of `candidate | gate_pending | posting | posted | vetoed | expired`.
  There is no index beyond the primary key. `bin/harness-sync.sh` applies it
  before the next worker deploy, the same way as every other statement in the
  file. Nothing else in schema.sql changed.
- **`bin/lib/proposal-rows.sh` is new.** It is a sourced shell client with
  three verbs, built on `_jobs_req` from `bin/jobs-client.sh`. The caller loads
  the jobs client.
- **No lane sources the lib yet.** The worker route
  (`/api/product-proposals`) and the lane wiring (`bin/run-product.sh`,
  `bin/product-cmd.sh`, `bin/post-proposal.sh`) are the sibling slices of
  BH-2531. Until the route deploys, the live worker answers
  `404 {"error":"unknown endpoint"}` and every verb returns 1. The lanes
  behave exactly as they did before this change.

## Why a table

The product lane's proposal ledger is one file on the owning box,
`state/product-<project>.ledger.json`. If that file is lost (a rebuilt box, a
restore from an old backup), the lane no longer knows which proposals it
already gated, vetoed or posted, and it can post the same `[Proposal]` ticket
to the client's board again. A D1 row keyed `(project, proposal_id)` outlives
the box. The file stays the working copy, and the row is the copy that
survives.

## rc contract

| verb | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `prow_get <project> <slug>` | prints the status | unusable: outage, 503, transport failure, a 404 that is not the route's own, a 2xx with no string `.proposal.status`, `HARNESS_SECRET` unset, no client loaded | no row: a 404 whose body is exactly `{"error":"proposal not found"}` | `JOBS_URL` is empty |
| `prow_put <project> <slug> <ledger-file> [status] [if_absent]` | the row landed (2xx and a JSON object back) | did not land: no file entry for the slug, a ledger that is not a JSON array, 404, 409, 5xx, a non-JSON 2xx | n/a | `JOBS_URL` is empty |
| `prow_restore <project> <ledger-file>` | rows read, file brought up to date | rows unreadable, or the file exists but is not a JSON array: the file is left byte-identical | n/a | `JOBS_URL` is empty: the file is untouched |

`JOBS_URL` empty is checked first, so rc 3 holds even when no jobs client is
loaded. With `JOBS_URL` set and no client, the answer is 1.

**Contract term for the route slice:** a missing row must answer 404 with the
body `{"error":"proposal not found"}`. `prow_get` reads any other 404 as 1,
because the router's own `unknown endpoint` 404 means the route is not
deployed. Reading that as "never posted" would cause the re-post this table
exists to stop.

`prow_put` sends the slug's LAST file entry. The row status is `[status]` when
given, else the entry's own. With `if_absent`, the body carries
`if_absent: true` and the route must only create, never change, an existing
row.

`prow_restore` appends rows whose slug the file lacks. It replaces a slug's
entries only when the row record's `updated_at` is lexically newer, and it
never deletes a file entry. It creates the file as `[]` only after the rows
answered, and it writes via tmp and `mv`. It then backfills every file slug
the rows did not return with an `if_absent` PUT. A put that does not land is
not counted and is tried again on the next run. It logs one line to
`logs/<project>.log` when the file changed, one when the list came back
`truncated: true`, and one with the backfill count.

## HTTP contract (from the ticket)

- `GET /api/product-proposals?project=<p>[&proposal_id=<s>]` answers
  `{proposals:[...], truncated, as_of}` or `{proposal}` or 404.
- `PUT /api/product-proposals` with
  `{project, proposal_id, status, record, actor?, if_absent?}` answers the
  stored row.

## Fail-open vs refuse, per lane (intended for the sibling slices, not shipped here)

- **Restore fails open.** When `prow_restore` answers 1 or 3, a lane keeps
  running on its file exactly as it does today.
- **Posting is the sibling's call.** Whether `bin/post-proposal.sh` refuses to
  post when `prow_get` answers 1 (unreadable), instead of posting blind, is
  decided in the lane-wiring slice. The distinct rc 1 and rc 2 exist so that
  it can make that call.
