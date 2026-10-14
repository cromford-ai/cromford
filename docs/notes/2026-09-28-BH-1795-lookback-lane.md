# The lookback lane now has a collector: one week of repeat failures in one bundle

Doc: TRUST-PROGRAM

BH-3326 (BH-1795.1, part 2 of 5). The weekly `lookback` hub lane
(`bin/lookback.sh`, `45 6 * * 1`) already ran its driver and logged
`collector not installed`. This ships `bin/lookback-collect.sh`, the step that
reads what went wrong in the window and hands the driver a bundle. Clustering,
the two filers and the 30-day follow-up are still sibling slices.

## The lane, driver to collector

`bin/lookback.sh` runs

    bin/lookback-collect.sh --days "${LOOKBACK_DAYS:-7}" --out state/lookback/<YYYY-MM-DD>/bundle.json

The collector reads its clock once. The window is `--since <iso>` when given,
otherwise NOW minus `--days` (default `LOOKBACK_DAYS`, 7), and ends at NOW. It
writes the bundle shape documented in `bin/lib/lookback-common.sh`
(`window`, `items`, `sources`, `incomplete`, plus a top-level `truncated`)
through `<out>.tmp` and `mv`. Items are sorted by source, project, ticket. Each
item's `id` is the first 12 hex chars of `sha1(source|project|ticket|pr|reason)`.

Exit codes: 0 when at least one source was read, 1 when none was (the driver
then writes one ALERTS line and exits 75), 2 for a usage error (no `--out`, a
`--since` that is not a date or is in the future, a non-integer `--days` or
knob). The collector writes nothing but the bundle and costs nothing: bash, jq,
two worker GETs and GitHub REST reads.

Every source leaves a record under `.sources.<name>`: `{ok, n, truncated, error?}`.
A read that fails is `ok:false`, never zero items, and it makes `.incomplete`
true. So does a skipped record (an unparseable blocked-resolver json, named in
`error`) and a read that hit its row ceiling. The source records are `reopen`,
`abandoned` (the ledger read), `br_records` (the blocked-resolver files),
`fix_rounds`, `alert_family`, `postmerge_fail` and `revert`. A local file that
does not exist yet (`logs/reopens.csv`, `logs/ALERTS.log`,
`state/blocked-resolver/`) is an empty read, because its writer creates it on
first use. One that exists and cannot be read is `ok:false`. An empty
`JOBS_URL` makes the two worker sources `ok:false` with `jobs not configured`.

`files[]` on an item is the newest `builds/<project>-<ticket>-*/changed-files.txt`
(the evidence.md planned-vs-changed block is derived from that file), else the
PR's file list from `GET /repos/<slug>/pulls/<n>/files` (first 100), else `[]`.
A path is never guessed, and a failed GitHub read gives `[]`.

Every GitHub read goes out on that repo's App token when the box mints them
(`bin/lib/gh-app-auth.sh`, reset between repos), else on the box's own `gh` login.

## Knobs

All four are `lane.lookback.*` settings rows, applied by `lane_env_apply lookback`;
the collector checks each is a whole number.

| knob | default | what the collector does with it |
|---|---|---|
| `LOOKBACK_DAYS` | 7 | window length when `--days` and `--since` are absent |
| `LOOKBACK_ALERT_MIN` | 3 | fewest summed occurrences of one alert family |
| `LOOKBACK_REREVIEW_MIN` | 2 | fewest re-reviews on one blocked-resolver record |
| `LOOKBACK_BUNDLE_MAX_ITEMS` | 400 | item cap; past it the newest (by `at`) are kept, `truncated` and `incomplete` are true |

## What counts as a repeat failure

1. **`reopen`**: a row of `logs/reopens.csv` whose `date` (day resolution) falls
   in the window. Reason `reopened: <from> -> <to>`.
2. **`abandoned`**: a `ledgers(kind=abandoned)` row with status `abandoned` and
   `updated_at` in the window (read as `GET /api/ledger?kind=abandoned&limit=1000`;
   a non-2xx or a body without a `ledgers` array is an outage). Also a
   `state/blocked-resolver/<project>/<rkey>.json` record modified in the window
   with outcome `ABANDONED`, unless the ledger already gave that project and
   ticket (the ledger row wins, so one abandonment is one item).
   **`parked`**: the same records with outcome `CI_PARKED`. Other outcomes
   (`RESOLVED_MERGED`, `CI_SUPERSEDED`, `HELD`, ...) are not failures.
3. **`fix_rounds`**: a blocked-resolver record modified in the window with
   `fixrounds >= 2` (fixed by the ticket, not a knob) or
   `rereviews >= LOOKBACK_REREVIEW_MIN`, whatever its outcome.
4. **`alert_family`**: `GET /api/alerts?since=<window seconds>&limit=500`
   (rows whose `last_seen` is in the window), grouped by family and project. The
   group counts when the sum of its rows' `count` is at least
   `LOOKBACK_ALERT_MIN` and its latest `last_seen` is in the window. Lane is the
   family up to its first `:`.
5. **`postmerge_fail`**: a `logs/ALERTS.log` line
   `<stamp> [<project>] POST-MERGE PROD QA FAILED for <KEY> (<sha8>, <PR url>): <rest>`
   stamped in the window. The `NOT RUN` and `BLOCKED` lines do not count.
   **`revert`**: per fleet repo (`fleet-conf.sh --projects`, deduped on the
   slug), a commit from `GET /repos/<slug>/commits?since=<from>&per_page=100`
   whose subject starts with `Revert ` or `Rollback` (the `bin/rule-miner.sh`
   query). A GitHub failure on any repo makes `revert` `ok:false` and names the
   repo; 100 commits back marks it truncated.

## Why the per-row alerts list and not `/api/alerts/families`

The issue named `/api/alerts/families`. That route needs a `lane` (a
`claimed_by` prefix) and returns `{family, last_claimed_at, n}`, where `n` counts
rows and there is no `last_seen`. The per-row list through `alerts_list` carries
each row's `count` and `last_seen`, so the collector sums those itself.
