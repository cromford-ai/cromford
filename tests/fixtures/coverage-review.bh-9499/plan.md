# Plan: FX-9499 (fixture for tests/coverage-review.bh-9499-test.sh, not a real ticket)

## Tasks

### Task 1 — the rows screen
VALIDATE: bash tests/fixture-rows.sh
SATISFIES: the three scope items

## Requirements coverage

| Requirement (quoted) | Task | Test |
|---|---|---|
| "The rows screen lists the fixture rows" | T1, `src/list.ts` | tests/list.test.ts |
| "Each row has the `name` field" | T1, `src/rows.ts` | tests/rows.test.ts |
| "The empty state says no fixture rows" | T1, `src/empty.ts` | tests/empty.test.ts |

## Acceptance tests

| a | b |
|---|---|
| x | y |

- tests/fixture-rows.sh

KIND: feature
SIZE: S
