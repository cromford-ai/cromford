# Guardrail: RLS on every CREATE TABLE

**Iron law:** every Supabase project runs RLS deny-by-default on all `public`
tables, and every migration that CREATEs a table enables it in the same file.

**What it catches:** a `.sql` migration containing `CREATE TABLE` with no
`ENABLE ROW LEVEL SECURITY` anywhere in the same file.

**Tool:** shell (`check.sh`), not semgrep — see the header comment for why. The
condition is a whole-file absence assertion, which a pattern matcher expresses
badly and reviewers then misread.

```bash
guardrails/rls-on-create-table/check.sh                 # auto-discovers migration dirs
guardrails/rls-on-create-table/check.sh path/to/dir     # or explicit targets
```

**Applicability:** any repo with SQL migrations against Supabase/Postgres.
Prisma-only repos that never emit `.sql` migrations get "nothing to check" and
rc 0 — honest, and a reason to reach for `prisma migrate diff` in the adoption
ticket rather than to pretend coverage.

**Known limitation, stated plainly:** the check is per-file, not per-table. A
migration that creates two tables and enables RLS on one passes. Closing that
needs table-name extraction across quoting styles and `IF NOT EXISTS` variants;
the per-file form catches the class that actually happens (a whole migration
written with no RLS line at all) without pretending to more precision than it
has.

**Escape hatch:** `skip-guardrail` label + `GUARDRAIL_JUSTIFICATION` (see
`../README.md`).
On a Mergify batch draft the hatch reads each source PR and exempts only the
files a hatched source PR changed; the step needs the `GUARDRAIL_HEAD_REF`,
`GUARDRAIL_PR_AUTHOR`, `GUARDRAIL_DRAFT_BODY` and `GH_TOKEN` env lines (see
`../README.md`, "On a Mergify batch draft").
