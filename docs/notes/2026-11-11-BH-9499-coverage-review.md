# Coverage review: the in-build review answers the plan's coverage rows (BH-9499)

Doc: PLAN-CONTRACT

## Why

The lead review blocked 88 tickets on `wrong-data` in 14 days. Each block was a
ticket requirement the diff did not deliver, and the in-build review had
approved it. The lead-review checklist ran only in the lead lanes
(`bin/lead-review.sh`, `bin/inbuild-lead-review.sh`), after the PR existed.
`LENS_APPROVED` read the level cap and the spec trace, and nothing read the
plan's `## Requirements coverage` rows. A ticket body without `Spec:` lines (most
tickets) got no ticket-shaped check in the build at all.

## What changed

This is slice C2 of BH-9441 (scope item 3). It reads the rows that C0
(`bin/lib/coverage-rows.sh`) counts for the plan gate.

1. `cr_plan_row_list <plan>` prints the coverage rows, one per line, through the
   same walk `cr_plan_rows` counts with. One definition of a row.
2. `bin/lib/coverage-review.sh`:
   - `cv_review_note` builds the `COVERAGE REVIEW (lead checklist, BH-9499):`
     block of GATES_NOTE: the checklist version and its numbered items, the row
     rule, the rows as `R1..Rn`, and a `NOT IN DIFF: R<n> names <paths>` hint
     for a row whose backticked paths the diff does not change.
   - `cv_enforce`, called in `LENS_APPROVED` right after `st_enforce`, reads the
     `COVERAGE-ROW:` lines of the latest pass and turns an APPROVE into a BLOCK.
   - `cv_rereview_note` asks the merged re-review to emit the whole block again.
3. `bin/lib/rb/review.sh` has three call sites only: the source line and the
   `cv_enforce` call, the `# >>> coverage review (BH-9499)` region, and the
   re-review sentence.

## The row line

```
COVERAGE-ROW: R<n> | <requirement> | <delivered|missing|contradicts|elsewhere> | <evidence> [| wrong-data|core-flow-broken]
```

- `delivered` needs a file:line. `elsewhere` needs the ticket or slice.
- There is no `partial`. Split the row, and mark the undelivered part `missing`.
- These BLOCK: `missing`, `contradicts`, a row with no line in the latest pass,
  `delivered | -`, `elsewhere | -`, any other status. Each reason is one
  `- [BLOCK <class>] COVERAGE-GATE: R<n> <requirement>: <why>` line, then
  `VERDICT: BLOCK`. The class is `wrong-data`, or `core-flow-broken` when the
  fifth column says so. `bin/findings-log.sh` records each line as a BLOCK row.
- Lines in a code fence, quoted lines, and lines from an earlier pass do not
  count. Rows before a restated `SPEC-TRACE-GATE: ok` verdict count.

## When it does nothing

- The plan has no `## Requirements coverage` section, or the section has no
  rows: GATES_NOTE and review.md are byte-identical.
- The verdict is not APPROVE, or review.md is unreadable.
- The security and refute lenses are never judged.

## Knobs

`catalog/lanes.d/_lib.coverage-review.json`, id `coverage-review`:

| knob | default | meaning |
|---|---|---|
| `COVERAGE_REVIEW_ENFORCE` | 1 | 0: one `COVERAGE-GATE: would BLOCK` pipeline.log line, the verdict stands |
| `COVERAGE_REVIEW_ROWS_MAX` | 40 | rows past it are `NOT JUDGED` and not enforced |
| `COVERAGE_REVIEW_CHECKLIST_MAX_BYTES` | 16000 | over it, or 0, the note names the checklist file instead of inlining it |

A bad value enforces and writes a `COVERAGE-GATE: knob warning:` line.

## Test

`tests/coverage-review.bh-9499-test.sh`.
