# BH-8363 (C0): no suite reads the text of bin/lead-review-enqueue.sh except the tick suites

Ticket: BH-8363 (BH-7236.2, part of #7236, for #5878).
Spec: `.harness/specs/BH-7236/plan.md` (C0 of #7236).
Doc: none

## What changed

No lane runs `bin/lead-review-enqueue.sh` since BH-7235. Its gates run on the
worklist (`bin/lead-review.sh tick`). Five suites still read the script text
with awk or grep. This slice removes those reads. Each removed case has a twin
on the live caller, or it moves to a new suite.

| Suite | Case | Class | Where the behaviour stays pinned |
|---|---|---|---|
| `tests/callers-not-ported.bh-7815-test.sh` | S5 (eval of the `PSCNOTES=` lines) | TWIN | S4 of the same suite (`lgsc_notes` forwards the line, `NOTE ` cut) |
| `tests/pr-body-requires.bh-7378-test.sh` | S6, the enqueue `grep -qF` clause | TWIN | S6 keeps the `bin/lib/lead-gates-selfcheck.sh` clause and the f1/f2 checks |
| `tests/live-probes.bh-5801-test.sh` | E1 (2 asserts) | TWIN | `tests/lead-hub-reconcile.bh-7235-test.sh` P1 and M3 (`bin/pr-state-reconcile.sh` runs the lane) |
| `tests/pr-self-check-test-ownership.bh-6392-test.sh` | E1 (3 asserts) | PORT | K1-K3 of `tests/lead-gates-selfcheck-key.bh-8363-test.sh` |
| `tests/builder-self-check-prepush.bh-6393-test.sh` | S2, the `SCH` awk assert | PORT | K4 of `tests/lead-gates-selfcheck-key.bh-8363-test.sh` |

The new suite drives `bin/lead-review.sh tick` over the worklist fixture. The
PR head edits `tests/x.bh-100-test.sh`:

- K1: title `BH-200: t`: no job, one comment with a `- test-ownership: ` line.
- K2: title `BH-100: t`: no `test-ownership` line.
- K3: a title with no key: no `test-ownership` refusal line.
- K4: title `BH-200: t` and a closes-not-met body: one comment with both rule
  lines. `lgsc_run` narrows no rule.
- M1: `PSC_PR_KEY=""` in a copy of the lib makes K1 red.

No file under `bin/`, `worker/`, `cron/` or `catalog/` changed.

## Why the deletion is a separate slice

21 suites still run `bin/lead-review-enqueue.sh tick`. #8362 (BH-7236.1)
removes those cases. If the script goes first, those 21 suites go red. So the
deletion is the next slice of #8363, and it is `Blocked-by: #8362`.

The deletion slice owns: the script, its `pr`-mode lib, the lane JSON, the cron
stub, the supersede block in `bin/lead-review.sh`, the protected-path seed row,
the comments that name the script, the verification-map rows, and
`tests/lead-enqueue-retired.bh-5870-test.sh`.

`state/lead-review-enqueue/` stays. It is the live state dir of the worklist
gates (`lgsc_hold` writes there).
