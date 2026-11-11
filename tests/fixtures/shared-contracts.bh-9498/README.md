# tests/fixtures/shared-contracts.bh-9498

Fixtures for `tests/shared-contracts.bh-9498-test.sh` (BH-9498).

- `repo/` — a repo with one project-6-shaped contract (`migration-tenancy-header`, `new`, `prisma/sql/*.sql`) and one existing migration `prisma/sql/0001_base.sql`. The suite copies it into its scratch dir.
- `bad-rows.tsv` — one row per BAD reason, then one valid tool-registry-shaped row.
- `plan-unlisted.md` — adds `prisma/sql/20261111_widgets.sql` and has no `## Shared contracts` section.
- `plan-listed.md` — the same plan with the section.
- `plan-near-misses.md` — paths that must NOT trigger the contract.
- `plan-no-trigger.md` — a plan with no contract path.
