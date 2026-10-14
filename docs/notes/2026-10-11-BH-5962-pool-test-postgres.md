# A throwaway Postgres for the pool suite run (BH-5962)

Doc: docs/verification-map/entries/BH-5962.md

## The problem

The pool test runner had no Postgres. A repo whose unit suite needs
`DATABASE_URL` recorded `HARNESS_EXIT: 1` in `harness-suite.txt`. The review
blocks on a nonzero exit. project-6-os TK-3, TK-34, TK-35 and TK-36 were
blocked this way, and CI, which starts Postgres 16, passed all four.

## What changed

1. `bin/lib/pg-test.sh` (new). `pgt_enabled` reads the fly-pool knob
   `POOL_TEST_POSTGRES` for `$PROJECT` through `lane_knob` (row, env, registry
   default 0). Only exactly `1` is on. `pgt_start` runs `initdb` and
   `pg_ctl start` from `/opt/pgtest/bin` in a `mktemp` dir, as `nobody` when
   root, on 127.0.0.1. Before it starts anything, it checks that the major the
   image holds equals the knob `POOL_TEST_POSTGRES_MAJOR` (default 16). On a
   mismatch it writes `could-not-start` and starts nothing.
   `pgt_setup` reads the knob `POOL_TEST_SETUP_CMD`. It is empty by default,
   and then no setup runs. Its only accepted form is `npm run <script>`, with
   `<script>` declared in the target repo's own package.json. Anything else is
   refused, because a settable row never carries a command. `pgt_stop` stops
   the server and deletes the dir.
2. `HARNESS_SUITE_RUN` (`bin/lib/rb/gates.sh`, npm arm) calls it after the
   prelude. The setup script and the suite get the `pgt_env` prefix:
   `env -u <name>` for every exported name that can carry a database address
   (`*DATABASE_URL*`, `*DIRECT_URL*`, `*DB_URL*`, `POSTGRES*`, `PG*`,
   `SUPABASE_DB*`), then `DATABASE_URL` and `DIRECT_URL` set to the local URL.
   A pool machine exports the box's whole project env into the build
   (`fly/builder-runner.sh` load_env), so a prod `DIRECT_URL` (Prisma
   `directUrl`, which `migrate deploy` uses) must not reach `db:apply`.
   The teardown runs before `HARNESS_EXIT`, on every suite exit. The
   impact-gate arm (cromford itself) is not changed.
3. `fly/Dockerfile` bakes the pinned `@embedded-postgres/linux-x64`
   16.14.0-beta.17 tarball into `/opt/pgtest` (block `bake-pgtest`, sha256
   checked, `bake_verify postgres 16.14`). The pin is `bin/lib/pgtest-pin.sh`.
4. Nothing is seeded. A project is turned on with settings rows after merge
   (spec of 2026-10-11). For project-6-os:
   - `lane.fly-pool.project-6-os.pool_test_postgres` = `1`
   - `lane.fly-pool.project-6-os.pool_test_postgres_major` = `16`
   - `lane.fly-pool.project-6-os.pool_test_setup_cmd` = `npm run db:apply`
     (or the repo's own setup script name)

## The record

Lines in `$BUILD/harness-suite*.txt`:

- `HARNESS_PG: up (PostgreSQL <ver>, throwaway, postgresql://harness@127.0.0.1:<port>/postgres)`
- `HARNESS_PG: could-not-start (<reason>)`: the suite runs with no URL, as before.
- `HARNESS_PG_SETUP: npm run <script> (rc=N)`, `none (<why>)` or `refused (<why>)`.
- `HARNESS_PG: torn down`

`pipeline.log` gets `HARNESS-VERIFY <phase> postgres: <last HARNESS_PG line>`.
None of these lines stops the build. `HARNESS_EXIT` stays the suite's own exit
and the last line.

## Limits

- The `bake-pgtest` block was not built with docker on the build box. Its RUN
  steps were replayed by hand, and the suite's P11 ran against those binaries.
  The first proof on a pool machine is a project-6-os build whose
  `harness-suite.txt` shows `HARNESS_PG: up` and `HARNESS_EXIT: 0`.

- The image holds one major, 16 (`bin/lib/pgtest-pin.sh`). The default of
  `POOL_TEST_POSTGRES_MAJOR` is 16 because the ticket says so (the TK-3 build
  ran an embedded Postgres 16). No harness build reads another repo to confirm
  it. A second major needs a second pin and image block.
- A box without `/opt/pgtest` (any non-Fly box, or an image baked before this
  change) writes `could-not-start (no postgres in /opt/pgtest/bin)`.
- A SIGKILL mid-suite leaves the postmaster until the Fly machine stops. On a
  long-lived box the `/tmp/pgtest.*` dir is left for the `/tmp` sweep
  (`docs/verification-map/tmp-sweep.md`).
