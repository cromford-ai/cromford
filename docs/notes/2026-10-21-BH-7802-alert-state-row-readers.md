# Alert-state readers decide from the alerts row (BH-7802)

Doc: ALERTS-STATE-MACHINE, worker/jobs/README.md

## What changed

With `flags/alerts-db` on, four readers of `state/alerts/<id>.json` now read
the `alerts` row in the jobs worker first. The file is the fallback when the
worker does not answer.

- `alert_state_resolve` takes count and severity from the row the worker
  closed. Before, a resolve from a box with no file paged `critical` with
  `n=1`, whatever severity the condition opened at.
- `alert_state_age` takes `first_seen` from the row. Before, the RESOLVED line
  said `for 0m` when the file was absent.
- New `alert_state_open <id> [--file-exists]`. `bin/lib/tz-check.sh` and
  `bin/disk-guard.sh` use it to decide whether to call `--resolve`.

Two worker contract changes carry the data:

- `POST /api/alerts/resolve` adds `rows: [{id,count,severity,first_seen}]`.
  The statement is `UPDATE ... RETURNING`, so the rows are the ones that moved.
  `resolved` keeps its meaning.
- `GET /api/alerts?id=<id>` returns one row by primary key, in any state.

Two jobs-client calls read them: `alert_resolve_rows` and `alert_row`.

## Why

A condition opened on one box and resolved on another has no file on the
resolving box. The file-only readers gave the wrong severity, a 0m age, and
(for tz-check and disk-guard) no resolve at all.

## Fail open

- Flag off: no request; every reader gives the file answer, as before.
- Outage, non-JSON 200, or a worker that ignores `?id=`: one `db-miss` line in
  `logs/alerts-state.log`, then the file answer.
- An older worker with no `rows` key: `alert_resolve_rows` prints `#norows`,
  and `alert_state_resolve` reads count and severity from the file.

## Not changed

The file writer stays (the outage fallback). `state/alerts/alias/` stays on
files. The console `/alerts` FLEET ROWS already reads the rows. The `alerts`
table has no retention rule yet; the named fix is a rule in
`worker/jobs/src/routes/retention.js` for `state='resolved' AND last_seen`
older than a settings-row window.

Tests: `tests/alert-state-rows.bh-7802-test.sh`,
`worker/jobs/test/alerts-rows.bh-7802.test.js`.
