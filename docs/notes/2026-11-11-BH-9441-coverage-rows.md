# Coverage rows: the plan gate counts the coverage table against the ticket's Scope (BH-9441)

Doc: PLAN-CONTRACT

## Why

In 14 days the lead and security reviews blocked 88 distinct tickets on
`wrong-data` (33 of them in cromford). Each block was a ticket requirement
the diff did not deliver, and the in-build review had approved it. A plan whose
`## Requirements coverage` table skips a Scope item builds a diff that skips it
too. Before this change nothing compared that table with the ticket:
`bin/plan-gate.sh` skipped the section whole.

## What changed

This is slice C0 of BH-9441 (scope item 1).

1. `bin/lib/coverage-rows.sh` counts two things.
   - A scope item: a top-level list item (`1.`, `1)`, `-`, `*`, `+`, indent 0-1)
     under a ticket BODY heading whose text starts with the word "Scope", up to
     the next heading at the same or a higher level. "Out of scope" and
     "Scoped ..." do not match. Fenced lines and sub-bullets do not count.
     Comments never count: a comment author must not be able to change a gate.
   - A coverage row: under the plan's `## Requirements coverage` heading, a
     table row that is not the header and not the `|---|` separator, or a
     top-level list item.
2. `bin/plan-gate.sh`, with `PLAN_GATE_TICKET` set, prints
   `PLAN_COVERAGE: ok (<r> row(s) for <n> scope item(s)) | short | unread`.
   A ticket body with no Scope list gets no line, so its gate output does not
   change.
   Short prints
   `  UNTRACED: coverage — '## Requirements coverage' has <r> row(s), the ticket's Scope has <n> item(s)`
   and exits 2. The existing single repair pass runs, then PLAN_MALFORMED.
3. `bin/lib/rb/plan.sh` tells the planner the item count through `UI_PLAN_NOTE`
   (region `coverage rows note`), adds `cr_repair_note` to the repair prompt, and
   names the gap in the PLAN_MALFORMED reason (`cr_why_note`).
   `prompts/stages/plan.md` does not change.

The gate counts rows. Whether each row quotes the ticket and names a file and a
test is the review's job (child slice C2).

## Knob

`COVERAGE_ROWS_ENFORCE` (`catalog/lanes.d/_lib.coverage-rows.json`, lib id
`coverage-rows`): 1 (default) refuses; 0 prints a `NOTE: coverage` line and
`PLAN_COVERAGE: short (not enforced, COVERAGE_ROWS_ENFORCE=0)` and never refuses.
The code fallback is `CR_DEFAULT_ENFORCE=1`.

## Left for child tickets

- C1: scope item 2, `## Shared contracts`.
- C2: scope item 3, the lead-review checklist lens row by row against this table.
- C3: scope item 4, an all-inconclusive evidence block never reports APPROVE.
- C4: scope item 5, the digest metric with its 14-day baseline.
- C5: scope item 6 (comment), the 14-day one-shot size report on #6025.

Test: `tests/coverage-rows.bh-9441-test.sh`.
