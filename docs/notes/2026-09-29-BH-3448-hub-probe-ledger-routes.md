# Hub-probe request ledger: table and worker routes (BH-3448, BH-3434.1)

Doc: DB-COORDINATION-SPEC

## What changed

BH-3447 landed the contract: the `hp_*` verbs in `bin/lib/jobs/hub-probe.sh`
and two empty route modules. This slice fills the modules and adds the table.

1. **Table** `hub_probe_requests` (`worker/jobs/schema.sql`, `BH-3434` block,
   applied by `bin/harness-sync.sh` before `wrangler deploy`). One row per
   `(project, ticket_key, probe, args_hash)`, UNIQUE, plus an index on
   `(status, requested_at)`. `status` is one of pending, claimed, pass, fail,
   rejected. There is no `CREATED_TABLES` entry, so a D1 the apply never reached
   answers 503 `hub_probe_requests schema not applied`.
2. **Ledger routes** (`worker/jobs/src/routes/hub-probe.js`):
   - `POST /api/hub-probe` inserts with `ON CONFLICT DO NOTHING` and answers
     `{created, row}`. `args_hash` is the sha256 of the canonical args JSON
     (keys sorted at every depth, arrays in order), computed only by the
     worker. A client `args_hash` is ignored. A key is requested once ever: a
     re-request of a finished row answers the stored row untouched. 400 for a
     bad project, ticket_key (`[A-Za-z0-9._-]{1,64}`), probe
     (`[a-z][a-z0-9-]{0,31}`), missing args, or args over 2048 characters.
   - `POST /api/hub-probe/claim {claimed_by, n}` moves at most `n` pending rows,
     oldest first, to claimed in one `UPDATE ... RETURNING`. `n` outside 1..100
     is a 400, never clamped.
   - `POST /api/hub-probe/result {id, result, http_status, output, note}` works
     only from claimed. Anything else is 409 with the row's status, and an
     unknown id is 404. `result` may be pass, fail, rejected, or pending. The
     ticket named the field `status` and the contract client sends `result`, so
     `status` is read when `result` is absent. `pending` needs a note, puts the
     row back to pending and clears `claimed_by`/`claimed_at`. `output` is cut
     to 4096 UTF-8 bytes on a character boundary by the worker.
   - `POST /api/hub-probe/commented {id}` sets `commented_at` only where it is
     NULL and answers `{ok:true}` either way. Unknown id is 404.
   - `GET /api/hub-probe?project&ticket` lists that ticket's rows oldest first,
     at most 200, with `truncated`.
3. **Counter routes** (`worker/jobs/src/routes/hub-probe-count.js`):
   - `GET /api/hub-probe/count-today?probe` counts rows of that probe with
     `claimed_at` today (UTC). A deferred row does not count.
   - `GET /api/hub-probe/count?table&template` reads SQL only from the frozen
     `D1_COUNT_SQL` map (tables jobs, ledgers, split_watchdog_actions,
     hub_probe_requests; templates `all` and `last-24h`). Anything else,
     prototype keys included, is a 400 before any statement is prepared. The
     map's keys are pinned to `HP_D1_TABLES`/`HP_D1_TEMPLATES` in
     `bin/lib/hub-probes/common.sh` by the suite.

A missing table is a 503 on every route, never a count of 0 or an empty list.

## Tests

`worker/jobs/test/hub-probe.bh-3434.test.js` and
`worker/jobs/test/hub-probe-count.bh-3434.test.js`, both through `worker.fetch`
against node:sqlite running the shipped `schema.sql`. Route-table fragments
`621-hub-probe.txt` and `622-hub-probe-count.txt`.

## Not in this slice

The lane that claims and runs probes, and reclaiming a row left claimed by a
crash, are later siblings of BH-3434.
