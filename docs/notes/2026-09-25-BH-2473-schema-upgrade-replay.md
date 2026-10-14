# CI replays worker schema.sql over main's, the way live D1 gets it

Doc: DB-COORDINATION-SPEC

## What was wrong

#2462 (BH-2303) added `CREATE INDEX … ON cost_rows(lane_id, ts)` to
`worker/jobs/schema.sql`. `lane_id` reaches a live D1 only through
`ensureColumns` (`ADDED_COLUMNS` in `worker/jobs/src/lib/core.js`), and that
runs after the deploy. `bin/harness-sync.sh` `worker_schema_apply` applies
schema.sql before `wrangler deploy`, so on live D1 the index fails with
`no such column`, the deploy is skipped, and every later deploy fails the same
way. CI missed it because every schema test applied the file to a fresh
database, where the CREATE TABLE makes every column.

## What changed

- `bin/worker-schema-upgrade.sh` replays the upgrade. It splits both files with
  `d1_schema_statements` (the splitter `worker_schema_apply` uses), then applies
  every base statement and every head statement, in file order, to one
  in-memory sqlite database with autocommit. Every head statement must apply.
  `--base <ref>` covers every `worker/*/schema.sql`. A worker with no schema.sql
  at the ref is new, so its base is empty. `--files <base> <head>` compares two
  files. rc 0 means every statement applied, 1 means a head statement failed
  (each one is named), and 2 means it could not run. That covers no python3
  sqlite3, an empty or unreadable head, a base that fails on its own, an
  unresolvable ref, or no worker schema at all.
- The `worker-jobs` job in `.github/workflows/harness-ci.yml` runs it over the
  PR's base sha (a push's previous tip, or main on a manual run). A zero sha or
  a failed fetch makes the step red, not skipped.
- `checks/worker-schema-ensure-columns/` is a diff-mode check in
  `bin/checks-run.sh`'s catalog. It fires when one diff adds an `ADDED_COLUMNS`
  tuple and a schema.sql index on that column. It is a fast heuristic for
  merge-sweep and review. The replay is the gate.
- `tests/worker-schema-upgrade.bh-2473-test.sh` reads `worker/jobs/schema.sql`,
  so `bin/test-impact.sh` selects it on any schema.sql change. That makes it
  the pre-PR mirror of the CI step.

## Limit

Main's `ADDED_COLUMNS` are not replayed onto the base. A PR that indexes a
column main adds only through ensureColumns, and not in its CREATE TABLE, fails
the replay even though live D1 has the column. That failure is loud, not
silent. On 2026-09-25 one column sits in that corner:
`merge_trains.train_group` is in `ADDED_COLUMNS` but not in the
`merge_trains` CREATE, so an index on it would fail the replay. The fix there
is to add the column to the CREATE too, which fresh databases want anyway.
