# Plan: FX-2 — near misses

## Files to touch

1. `prisma/sql/0001_base.sql` — an existing migration, edited.
2. `prisma/sqlite/x.sql`, `prisma/sql/x.sql.bak`, `src/prisma/sql/x.sql` — partial matches.
3. The bare dir `prisma/sql/` is named here.

```
prisma/sql/fenced_only.sql
```

## Tasks

### Task 1 — edit
Edit `prisma/sql/0001_base.sql`.
VALIDATE: bash scripts/check.sh prisma/sql/validate_only.sql
SATISFIES: "an edit"

## Sibling claims (not touched)

- FX-9 adds `prisma/sql/sibling_only.sql`.

## Verify (run, not edited)

- `bash scripts/check.sh prisma/sql/verify_only.sql`
