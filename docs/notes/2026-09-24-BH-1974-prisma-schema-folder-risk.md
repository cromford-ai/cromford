# Schema-risk patterns match Prisma's folder layout

Doc: review-tier

## What changed

Every copy of the schema-risk alternation said `schema\.prisma`, which only
matches a file named `schema.prisma`. A repo on Prisma's multi-file layout
(`prisma/schema/<domain>.prisma`, like project-5) could change its schema and
the diff tiered T1. It got neither the security lens nor the refuter, and it
stayed merge `TIER=1`, so it was eligible for tier-1 auto-merge.

All eight copies now carry `prisma/schema/.+\.prisma$` right after
`schema\.prisma`:

- `bin/lib/review-tier.sh`: `RT_RISKY_RE` and `RT_HIGHRISK_RE` (review tier).
- `bin/run-build.sh`: `RISKY=` (security lens), `HIGHRISK=` (refuter) and
  `PAT=` (merge tier and the console's `TIER_HIT` reason).
- `bin/lib/rb/review.sh` and `bin/lib/rb/pr.sh`: the dormant stage-module
  twins of those three. Nothing calls `rb_review`/`rb_pr` yet (BH-478), so they
  change now to keep the split from reopening the gap.

Nested folders match (`prisma/schema/scan/runs.prisma`). The prefix is
unanchored, so a monorepo path like `apps/api/prisma/schema/x.prisma` matches
too. `.prisma` is anchored at the end, so `prisma/schema/x.prisma.bak` does not.
`prisma/seed.ts`, `prisma/schema/README.md` and `src/lib/prisma.ts` stay out of
the schema/money class.

Pinned by `tests/review-tier-prisma-folder.bh-1974-test.sh`.
