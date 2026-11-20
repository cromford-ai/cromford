# BH-9835: project-1 pool suite runs get the throwaway Postgres

Doc: docs/verification-map/entries/BH-9835.md, docs/verification-map/entries/BH-5962.md

## Cause
- The pool suite run is the npm arm of `HARNESS_SUITE_RUN` (`bin/lib/rb/gates.sh`):
  the `npx prisma generate` prelude, then `npm run <script>`.
- project-1 had no `lane.fly-pool.project-1.*` rows, so the throwaway
  Postgres (BH-5962, `bin/lib/pg-test.sh`) was off. The suite ran with no
  `DATABASE_URL`, went red with a Prisma DB signature, and `sp_build_post`
  recorded `could-not-run: DATABASE_URL (suite rc 1)` (TK-353, TK-406, TK-329).
- `prisma generate` does not need the URL. The soft miss is set only on a red
  suite with a DB error signature, so the suite opens a real connection. A
  placeholder URL is not enough (it gives P1001).

## What changed
- Seed `worker/jobs/schema.d/202611191755-bh-9835-project-1-pool-postgres.sql`
  (`INSERT OR IGNORE`; an operator row wins):
  - `lane.fly-pool.project-1.pool_test_postgres` = `1`
  - `lane.fly-pool.project-1.pool_test_setup_cmd` = `prisma db push`
- `pgt_setup` accepts a second fixed value, the exact text `prisma db push`.
  In a repo with `prisma/schema.prisma` or `prisma/schema/`, it runs
  `npx prisma db push --skip-generate --accept-data-loss` under `pgt_env`
  (local URL only, every other DB-address name unset), with the 300 s timeout
  the `npm run` form uses. Lines: `HARNESS_PG_SETUP: prisma db push (rc=N)`, or
  `none (no prisma schema)`. Any other value is refused, as before.
- With the throwaway up, `sp_build_post` gets "DB provided", so a red suite is
  `HARNESS_EXIT: 1` (red), not `could-not-run: DATABASE_URL`.
- The URL is `postgresql://harness@127.0.0.1:<port>/postgres`. No Supabase
  address (project `kxwocreggzngjhymahge` or any other) reaches the setup or
  the suite. Major: 16 (the registry default; the pool image holds only 16).
- `tests/pool-test-postgres.bh-5962-test.sh` P9 now refuses a project-6-os seed
  only. The project-1 seed is pinned by `tests/pool-test-postgres-project-1.bh-9835-test.sh`.

## Out of scope
- Alert 68040, "machines list for pool-project-1 unusable": this is the
  dead-machine sweep's `fly machines list` call. It is a different code path
  (no suite, no DB) and this change does not touch it.

## Turn it off
- Set `lane.fly-pool.project-1.pool_test_postgres` to `0`. To use a repo
  script instead of the push, set `…pool_test_setup_cmd` to `npm run <script>`.

## Proof on a box
- The next project-1 pool build: `grep -E '^HARNESS_(PG|PG_SETUP|EXIT)' builds/project-1-*/harness-suite*.txt`
  shows `HARNESS_PG: up`, `HARNESS_PG_SETUP: prisma db push (rc=0)` and an integer `HARNESS_EXIT`.
