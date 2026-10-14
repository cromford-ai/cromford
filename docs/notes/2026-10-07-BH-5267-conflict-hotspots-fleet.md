# Every project's conflict hotspots, measured weekly and stored as rows

Doc: CONFLICT_HOTSPOTS, HUB-RECOVERY-MCP

## What changed

`bin/conflict-hotspots.sh` (BH-4986) answered "which files collide most?" for
one checkout, by hand, and `docs/CONFLICT_HOTSPOTS.md` is one run of it for
cromford. BH-5267 (wave 1 of #5248) runs it for every project, every week,
on the box that owns the project, and keeps the answer where the rest of the
fleet can read it.

- **Lane** `conflict-hotspots-fleet` (`catalog/lanes.d/conflict-hotspots-fleet.json`,
  `cron/lanes/726-conflict-hotspots-fleet.cron`): `bin/conflict-hotspots-fleet.sh`
  at Sunday 03:23Z on every box that holds a fleet.conf project (project-4,
  project-6, project-1, project-3, project-9, small, project-2, project-5). Not the hub
  or project-10. For each project `fleet-conf.sh --projects-on-box` gives
  this box, one at a time: `git fetch --no-tags origin` in `/root/repos/<p>`,
  then `bin/conflict-hotspots.sh -C /root/repos/<p> --days DAYS` under
  `timeout` and `nice -n 19`, then one `PUT /api/conflict-hotspots`.
  `flock -n locks/conflict-hotspots.lock` dedupes; a held lock logs
  `skip: already running`. `--project P` runs one project, `--dry-run` prints
  each body and sends nothing.
- **Statuses** a run can end in: `ok`, `shallow` (the measurer's rc 3; the lane
  never unshallows), `no-checkout`, `fetch-failed`, `timeout`, `error` (any
  other rc, output with no TSV header, or a knob out of range). Only `ok`
  replaces rows. Any project that did not end stored, including a PUT that did
  not answer 2xx (logged `FAILED`, never `stored`), gets one
  `bin/lane-alert.sh --severity warn` line per run.
- **Knobs** (settings rows first, `lane_knob`): `CONFLICT_HOTSPOTS_DAYS` (30,
  1..365), `CONFLICT_HOTSPOTS_TOP` (200, 1..500), `CONFLICT_HOTSPOTS_TIMEOUT_S`
  (1800, 60..86400). A value outside its range makes that project's run `error`
  naming the knob. It is never clamped.
- **Tables** (`worker/jobs/schema.sql`, self-created through `CREATED_TABLES`):
  `conflict_hotspots` keyed `(project, file)` with conflicts, rebases, prs (the
  measurer's id list, e.g. `#12,#7,ticket/x`), window_days, since, until,
  ref_sha, run_at; and `conflict_hotspot_runs`, one row per project with the
  latest run's status/detail/box/run_at, the last good window's counts
  (files_total, rows_stored, pr_merges, sync_merges, merge_tree_errors) and
  `last_ok_at`. No row = never measured; `ok` with no hotspot rows = measured,
  nothing collided; a non-ok status = the latest run failed and the rows are
  the window from `last_ok_at`.
- **Routes** (`worker/jobs/src/routes/conflict-hotspots.js`, bearer only):
  - `PUT /api/conflict-hotspots` `{project, repo, box, status, detail,
    window_days, since, until, ref_sha, pr_merges, sync_merges,
    merge_tree_errors, files_total, rows:[{file, conflicts, rebases, prs}]}`.
    Every field and row is validated before anything is written (a negative or
    fractional count, a missing file, a duplicate file, more than 500 rows: 400
    and nothing changes). `ok` is one batch: delete the project's rows, insert
    the new ones, upsert the runs row. Any other status must carry no rows and
    updates only the runs row's status, detail, box and run_at.
  - `GET /api/conflict-hotspots?project=<p>&limit=<n>` answers `{project, run,
    hotspots, total, limit, truncated, as_of}`, ordered conflicts desc, rebases
    desc, file asc. `limit` defaults to 20, is capped at 200, and junk reads as
    20. An unknown project is 200 with `run: null`.
- **Mission Control**: a CONFLICT HOTSPOTS section on `/p/<project>`
  (`console-ui/src/screens/ConflictHotspotsPanel.js`), the top 50, every header
  sortable. Each `#N` links to `/pr/<project>/<N>`. Each file links to its
  GitHub history at the measured sha when the run has a repo and a sha, and is
  plain text otherwise. Branch names (`ticket/x`) are plain text.

## The `conflict_hotspots` MCP tool (contract; the body is a human step)

The operator MCP server lives in the private `example-org/cromford-console`
repo (docs/HUB-RECOVERY-MCP.md, "Human step"), which no build lane can write.
This note is the tool's contract; the route above is its backend.

- Name `conflict_hotspots`, a read tool, no side effects.
- Arguments: `project` (required, `[A-Za-z0-9._-]{1,64}`), `limit` (optional
  integer 1..200, default 20).
- One call: `GET /api/conflict-hotspots?project=<project>&limit=<limit>` with
  the server's bearer. It returns the route's JSON body verbatim.
- A non-2xx or transport failure is surfaced as an error with the status and
  body. It is never read as an empty list: `run: null` is "never measured" and
  only the route can say so.

## What did not change

`bin/conflict-hotspots.sh` is called by path and not edited, so the #5236
dedupe/Mergify-ref fixes land here when that ticket merges.
`docs/CONFLICT_HOTSPOTS.md` is not regenerated; the rows are now the fleet-wide
data source and the doc stays a hand-run artifact.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/conflict-hotspots-fleet.bh-5267-test.sh`,
`cd worker/jobs && node --test test/conflict-hotspots-route.test.js`,
`HARNESS_TEST_SANDBOX=1 bash tests/conflict-hotspots-console.bh-5267-test.sh`.
Live, after the first Sunday run (or `bin/conflict-hotspots-fleet.sh --project
cromford` on the small box):
`curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/conflict-hotspots?project=cromford" | jq '.run.status'`.
