# BH-9308: the log screens get a range, search, filters, a CSV and a period report (BH-9120.4)

Doc: console-ui/README.md

## Why

#9120 puts a date range on every report screen. BH-9304 shipped the period
contract and ranged JOBS on `created_at`. This ticket gives the four log
screens (JOBS, LANES, HISTORY, COMMAND LOG) the rest: the URL period on each,
a search box and column filters in the URL, a CSV of the whole filter, and a
period-report entry.

## What changed

- Worker `GET /api/jobs`: new params `q` (over `ticket_id`, `kind`, `meta`),
  `lane`, `sort` (created_at, updated_at, project, status, kind, box) + `dir`,
  `cursor` (keyset, base64url of `[sortValue, id]`), `totals=1`,
  `series=hour|day|week` and `format=csv` (a lean select with no per-row
  subquery). Each needs a range: without `from` it is a 400. The no-range and
  from-only SQL text is unchanged.
- Worker `GET /api/lane-runs`: a range path on `enqueued_at` with `q` (lane,
  project, claimed_by, args_json, prof_line), `lane`, `machine`, `project`,
  `status` (`failed` = done with rc != 0, `done` = done with rc 0 or null),
  sort, cursor, totals, series and CSV. With no `from` the statement and
  answer are unchanged.
- New indexes `idx_lane_runs_enqueued` and `idx_lane_runs_project_enqueued`
  (`worker/jobs/schema.d/202611090614-bh-9120-4-log-indexes.sql`) and the
  settings row `console_db.schema_apply_timeout_s` (30).
- Pages `GET /api/cockpit/history`: a range path on `started_at` (search over
  `rkey`, `kind`, `summary`; keyset cursor; totals; series; CSV). With no
  range param it answers as before. New `GET /api/cockpit/commands` (from is
  required) over `created_at`, with `type`, `project`, `status` and `q`. The
  knobs come from the jobs worker; a failed fetch uses the code fallbacks and
  the answer says `knobs_source: "fallback"`.
- `console-ui/schema.d/` (new): `CREATE INDEX IF NOT EXISTS` statements for
  harness-console-db (`idx_runs_started`, `idx_runs_project_started`,
  `idx_commands_created`). `bin/console-db-schema.sh` applies them after a
  Pages deploy through the D1 query API and refuses any other statement. A
  failure is one warn alert `console-db-schema`; the deploy is never stopped.
- `console-ui/src/lib/log-period.js`: URL helpers, the toolbar (search,
  chips, "Download CSV", "Period report") and the report panel.
- The four screens: the picker, the toolbar and the in-place report panel
  (`?report=1`). JOBS and LANES headers that the server can sort write
  `?sort=&dir=`. HISTORY and COMMAND LOG chips keep the period and the search.
- `SortableTable`: an optional `onSort(key, dir)` prop.
- The period-report seams `jobs`, `lanes`, `history`, `commands` are filled.

## Rule touched

Indexes and retention (BH-6730): every new range read names its index and is
proven by EXPLAIN at volume in `worker/jobs/test/log-period.bh-9120-4.test.js`
and `console-ui/tests/log-period.bh-9120-4.test.js`. No new table.
