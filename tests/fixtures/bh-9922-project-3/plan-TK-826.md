# Plan — TK-826: credits ledger for event credits

## Files to touch

- `prisma/schema.prisma` — add a new model CreditLedger (id, memberId, amount, createdAt).
- `src/lib/credits/ledger.ts` — write a ledger row per credit change.

## Tasks

Add model CreditLedger and the writer.
