# Box console command routes: /api/box-console-commands (BH-2654, BH-2528.1)

Doc: DB-COORDINATION-SPEC

## What changed

New route family `worker/jobs/src/routes/box-console-commands.js`, registered
at the end of `ROUTES` in `worker/jobs/src/index.js` (behind the bearer). It is
the server side of `bin/lib/jobs/box-console-commands.sh` (BH-2653) over the
`box_console_commands` table that BH-2653 put in `schema.sql`.

- `POST /api/box-console-commands` creates a queued row. 201 new, 200
  `created:false` on an identical replay, 409 when the id is reused for a
  different box, type, project or payload. `type` is one of nine names, exact
  case. A payload over 256 KB (UTF-8 bytes) is 413, never sliced.
- `POST /api/box-console-commands/claim {box, limit}` flips up to `limit`
  (1-100) of that box's queued rows to claimed in one statement and answers
  them as a bare array, oldest first. `[]` when none.
- `POST /api/box-console-commands/:id/result {box, ok, result, body}` moves a
  claimed row to `done` (ok) or `failed` (not ok), only for the box that owns
  it. An identical repeat is 200 `unchanged:true`; anything else is 409.
- `POST /api/box-console-commands/expire {ttl_s}` flips queued rows older than
  `ttl_s` to `expired` and returns them once. Claimed rows older than 2×`ttl_s`
  are listed in `stale_claimed` (max 500, `stale_truncated`) and left claimed,
  so a command runs at most once.
- `GET /api/box-console-commands/:id` answers `{command}` or 404
  `no such console command`.

## Why

The console needs to reach a box without ssh. The hub forwards a command as a
row, the box claims and answers it. The routes are
`/api/box-console-commands/…`, not `/api/box-commands/…`: that prefix belongs
to #2518's `box_commands` table (the RESUME rename on BH-2528).

## Notes

- Terminal status is `done` or `failed`, per the ticket body. The BH-2653
  schema comment lists `queued | claimed | done | expired`; there is no CHECK
  constraint, and `failed` is what the console UI (#2656) reads as terminal.
- No `ensureTable`: `bin/harness-sync.sh` applies `schema.sql` before
  `wrangler deploy`. A missing table answers 503 `schema not applied`.
- TTL and claim limit are the BH-2653 settings rows
  `lane.box-console-commands.*`, read by the callers and passed in.
