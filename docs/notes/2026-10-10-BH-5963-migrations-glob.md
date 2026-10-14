# A project's migration SQL can live outside scripts/migrations (BH-5963)

Doc: DB-COORDINATION-SPEC

## What happened

example-org/project-6 keeps its migration SQL in `prisma/sql/`. Three harness readers looked only at the
literal `scripts/migrations/*.sql`, so a project-6 PR that added `prisma/sql/0003_x.sql` read as "adds no
migration files".

## What changed

1. **One knob, one reader.** The settings row `migrations_glob.<project>` holds `<dir>/*.sql`. No row
   means `scripts/migrations/*.sql`, the old literal. `bin/lib/migrations-glob.sh` reads it (`mg_glob`,
   `mg_dir`, `mg_first_named`). A value that is not a relative `<dir>/*.sql` with no `..`, or a row the
   worker cannot read, uses the default and writes one stderr line.
2. **`bin/hotfix-migrate.sh`** looks for the PR's added SQL under the row's glob in the endpoint and
   `none` shapes. A row glob is passed to git with `:(glob)` magic, so `*` does not cross `/`. The "adds
   no migration files" line now names the globs it used and where the endpoint glob came from.
3. **`bin/scope-gate.sh`** reads the project from `$BUILD/job.json` and protects the row's dir IN
   ADDITION to `scripts/migrations/`. A planned migration in either dir makes both the plan's territory.
4. **The reviewed-merge sweep's MIGRATION GATE alert** names the first flagged file under the row's
   dir. It now uses `grep -h`: before, the two-file grep put the file name in front of the path
   (`…/migration-gate.txt:scripts/migrations/x.sql`).
5. **`bin/size-scope.sh` is unchanged.** It has no migrations literal in code, and `prisma/sql/*.sql`
   already counts as product code.
6. **Seed.** `worker/jobs/schema.d/0019-bh-5963-migrations-glob.sql` sets
   `migrations_glob.project-6-os` = `prisma/sql/*.sql` (`INSERT OR IGNORE`).

## Not changed

`bin/lib/data-lane.sh`, `bin/check-migration-appliable.sh`, `bin/migration-autopilot.sh`,
`bin/lib/migration-files.sh`, `bin/apply-migrations.sh`, `bin/readiness-report.sh` and
`bin/check-migration-prs.sh` still use the literal. project-6-os is not in hotfix-migrate's endpoint
list, so with the row set a project-6 hotfix now answers no-path (rc 5) instead of rc 4.

Set it: `bin/jobs-client.sh setting-set migrations_glob.<project> '<dir>/*.sql'`
