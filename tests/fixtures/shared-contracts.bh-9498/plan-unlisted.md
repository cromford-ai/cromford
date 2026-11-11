# Plan: FX-1 — widgets table

## Files to touch

1. `prisma/sql/20261111_widgets.sql` (NEW) — the widgets table.
2. `src/widgets.ts` — reads it.

## Tasks

### Task 1 — the migration
Add `prisma/sql/20261111_widgets.sql`.
VALIDATE: npm test
SATISFIES: "a widgets table"
