# BH-10071: an empty gh-budget cache ended the resolver's candidate list

Date: 2026-11-25. Ticket: #10071 (nightly red on main `2b56f1c753`).

## What failed

`tests/resolver-human-step.bh-6536-test.sh` failed on main with 4 lines: 2 times `setup: tick 1 must park HELD, got ''`, then R5 and R6. Each merge queue batch that ran this suite failed. PR #9975 was ejected for it on 2026-11-25 07:46Z.

## Cause

`_ghb_cache_valid` in `bin/lib/gh-budget.sh` did arithmetic on the output of jq. For an empty cache file jq prints nothing and exits 0. The shell then stopped with `now -  : syntax error: operand expected`. In the blocked-resolver this runs inside `RAW=$(br_candidates)`, so the subshell ended and the rows that `br_from_builds` had printed were lost.

## Fix

The function reads `fetched_at` into a variable and returns 1 when the value is not a number. An empty or unparsable cache is now "not valid", which starts a new read.

## Proof

- Red before the fix, on the remote test host: `gh-budget-empty-cache: 13 passed, 3 failed` (E1, E3, E8) and `resolver-human-step.bh-6536: 13 passed, 4 failed`.
- After the fix: 7 suites, 0 failing (the new suite, the resolver suite and 5 gh-budget suites).

## Not found

Which commit first made the suite red on main. No commit after 2026-11-18 changed `bin/lib/gh-budget.sh`.
