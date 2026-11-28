# BH-9594: a failed GitHub read is recorded against the box

Doc: GH-REST, STATE-STORES

## The gap

`bin/orphan-reconcile.sh` reads the board through `bin/lib/gh-rest.sh`. When a
read answered 401, 403, 429, 5xx or nothing, the lane logged
`unverifiable (HTTP 401 auth) — enqueued nothing`, called `gh_rest_alert` and
exited 0. Nothing recorded the failure against the box. No lane could tell a
dead credential from a quiet board.

## What changed

- `bin/lib/could-not-read.sh` (new, sourced): `cnr_classify_status`,
  `cnr_classify_text`, `cnr_record`, `cnr_box`. `cnr_record` POSTs to the jobs
  worker and always returns 0.
- `worker/jobs/schema.d/202611121922-bh-9594-box-read-failures.sql`: tables
  `box_read_failures` (append, indexes `(box, cred_class, at)` and `(at)`) and
  `box_cred_health` (primary key `(box, cred_class)`). Settings rows
  `retention.box_read_failures.days` = 14, `lib.could-not-read.cnr_enforce` = 1,
  `box_read_failures.recent_max` = 20.
- `worker/jobs/src/routes/box-read-failures.js`: `POST` and
  `GET /api/box-read-failures`. A failure adds a row and adds 1 to
  `consecutive` in one statement. `ok` sets `consecutive` to 0.
- `worker/jobs/src/routes/retention.d/bh-9594-box-read-failures.js`: rows older
  than 14 days are deleted by the hourly `bin/d1-retention.sh` lane.
- `bin/orphan-reconcile.sh`: its reads go through `cnr_retry`. A could-not-read
  answer writes one record a run. A good open-list read records `ok`. The lane
  still declines and exits exactly as before.
- Seams for the later BH-9555 children, with placeholders that keep today's
  behaviour: `bin/lib/cnr-retry.sh` (BH-9555.3),
  `bin/lib/triage-state.d/bh-9555-3-cnr.sh` (BH-9555.3) and
  `bin/lib/triage-state.d/bh-9555-5-pr-record.sh` (BH-9555.5), called from
  `bin/lib/triage-state.sh`.

## Kill switch

Set the settings row `lib.could-not-read.cnr_enforce` to 0 (env `CNR_ENFORCE`).
Then `cnr_record` posts nothing and prints nothing.

## Tests

`tests/could-not-read-record.bh-9594-test.sh` and
`worker/jobs/test/box-read-failures.bh-9594.test.js`.
