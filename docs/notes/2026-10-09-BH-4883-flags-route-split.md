# BH-4883: flags worker route + D1 table only (split from #4332)

Slice 1 of 2 of BH-4153. the operator split it on 2026-10-06: the worker side ships and
deploys first, so #4332 can carry a live production probe of `/api/flags`
before any lane reads its pauses from the worker (the BH-1000 rule).

## What ships

The seven worker files from #4332 (branch `ticket/bh-4153`), applied onto main
unchanged except one schema comment:

- `worker/jobs/schema.sql` and `CREATED_TABLES.harness_flags` in
  `worker/jobs/src/lib/core.js`: the `harness_flags` table keyed (scope, name),
  its name index, and the one-time `INSERT OR IGNORE` backfill from
  `pause_flags`.
- `worker/jobs/src/lib/harness-flags.js`: `FLAG_PORTED_RE` and the row helpers.
- `worker/jobs/src/routes/flags.js`: GET list and one, PUT and the new DELETE.
- `worker/jobs/test/route-table.d/200-flags.txt`: `DELETE /api/flags`.
- `worker/jobs/README.md`: the four route rows.
- `worker/jobs/test/flags-db.bh-4153.test.js`: W1 to W10 from #4332, plus W11.

Nothing under `bin/`, `console-ui/` or `tests/` changes. No shell reader or
writer switches over in this slice.

## Why it is additive for current callers

- A name outside the ported families (`paused-*`, `automerge-disabled[-*]`,
  `lanedown-*`) runs the old PUT body verbatim (W4).
- A ported fleet-scope write mirrors into `pause_flags` in the same batch, so
  `checkPause` and every worker reader of `pause_flags` is unchanged (W7).
- The shell readers on main (`bin/lib/jobs/flags.sh` `_flag_row`,
  `bin/lib/lane-switch.sh`) read only `.flag.active` and `.flag.updated_at`.
  Both stay present and track every set, clear and re-set (W11, new here).

## Deploy and probe (Done-when of #4883)

`bin/harness-sync.sh` applies `schema.sql` statement by statement, then
deploys. The probe to paste on #4883 and #4332 after the deploy:

    curl -sS -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/flags?prefix=paused-"
    curl -sS -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/flags/paused-project-3"

The first must answer `200` with rows in the full shape (`scope`, `set_at`,
`cleared_at` present). That proves `harness_flags` exists and the backfill ran.
The second answers `200` or `404`, never `5xx`.
