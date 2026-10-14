# BH-1355: the migration gate sees `prisma/` files, and names them

**What happened.** The build Evidence block for `example-org/project-5` PR #3082
(TK-3071) said `migration gate: none`, on a branch that ADDS
`prisma/migrations/manual/2026-09-22-TK-3071-analysis-config-in-flight.sql` (an
`ALTER TABLE … ADD COLUMN IF NOT EXISTS`) and changes
`prisma/schema/misc.prisma`. No damage that time — project-5's
`migrate-manual.yml` applies added files on merge, and the code degrades with
the column absent — but the gate exists so a reviewer is TOLD a PR carries
schema, and a `none` on a PR that adds SQL is the gate lying.

**Cause.** The gate's entire file detection was one pathspec in
`bin/run-build.sh`:
`git diff --name-only --diff-filter=A "$BASE"...HEAD -- 'scripts/migrations/*.sql'`.
Anything under `prisma/` was invisible to it, so `ADDED_SQL` was empty,
`EVID_MIG` stayed `none`, `gates.json` recorded `"migration":"none"` and
`bin/evidence-summary.sh` printed `| migration gate | none |`.

**The fix.** `bin/lib/migration-files.sh` is a new sourceable lib holding the
two queries the gate needs and the reason they differ:

- `migration_files_changed <base> <dir>` — what the EVIDENCE names. Added or
  changed (`--diff-filter=ACMR`, so a rebase-renamed Prisma folder still counts;
  deletions do not, that is `bin/scope-gate.sh`'s business)
  `scripts/migrations/*.sql`, anything under `prisma/migrations/**` including
  `manual/`, any `*.sql` under `prisma/`, and `prisma/schema.prisma` /
  `prisma/schema/*.prisma`.
- `migration_sql_added <base> <dir>` — what the appliability classifier LINTS.
  Byte for byte the query it has always run: ADDED `scripts/migrations/*.sql`.

The classifier's scope did not move, deliberately. That allowlist is the app's
own `/api/internal/migrations` endpoint contract; Prisma's apply path was never
written against it, and linting `prisma/**/*.sql` would force tier 2 on every PR
carrying a Prisma-generated `DROP INDEX`. Widening the lint is a policy change
for its own ticket. A `prisma/` file is therefore reported and never linted.

**The new word.** `gates.json` `.migration` gains `present`: migration-shaped
files in the diff, none of them linted. It is not `clean`, which means "the
classifier passed" — saying that about SQL nothing judged would be the second
lie on the same row. Precedence, widest first, is
`none` → `present` → `clean` → `flagged` / `gate-failed`, so the classifier's
verdict still outranks the file list.

**What a reviewer now sees.** One `pipeline.log` line when anything was found
(`MIGRATION GATE: N migration file(s) in diff: <paths>`), `.migration_files` in
`gates.json` (`[]` when empty), and the Evidence row naming them:
`| migration gate | present — prisma/migrations/manual/2026-09-22-x.sql, prisma/schema/misc.prisma |`.
The list is `clean 400`-bounded and table-safe — branch names are
client-authored text. The one-line `Digest:` keeps only the word, because paths
would blow its 512-char cap. A `gates.json` written before this ticket has no
`migration_files` key, reads as `// []`, and renders exactly as it always did.

**Verification.** `tests/migration-gate.bh-1355-test.sh`, 45 assertions over a
real fixture repo: the lib against all six path shapes and the negatives
(section A), the `# >>> migration gate` block extracted from `bin/run-build.sh`
and run over a branch that adds ONLY
`prisma/migrations/manual/2026-09-22-x.sql` with a stub classifier that records
its argv (section B — the stub must NOT be invoked, the tier must not move), the
`# >>> gates json` block over all five words (section C), and the rendered
Evidence row plus `--json` including the old-record and hostile-path cases
(section D). Mutation-checked: narrowing the pathspec back, dropping the
`present` word, reverting the row, dropping the `pipeline.log` line and renaming
the `gates.json` key each turn the suite red.

**Not changed:** `bin/check-migration-appliable.sh`, the tier it forces,
`bin/merge-sweep.sh`'s reader of `migration-gate.txt`, hotfix-migrate,
migration-autopilot.

Doc: RUN-BUILD-GRAPH
