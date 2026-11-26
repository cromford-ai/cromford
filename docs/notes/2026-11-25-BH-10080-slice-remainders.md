# BH-10080: a slice remainder on an in-app board is never lost, and never claimed when not filed

Doc: VERIFICATION-MAP

## What happened

Three project-2 remainders were lost on 2026-11-24/25:

1. TK-618 merged slice C0 as PR #903. Its plan had no `SLICE: C<k> of #` line, so `slice_board_settle` answered `skip:no-slice` and filed nothing.
2. TK-604 C0 merged as #913, a hand-opened PR. It had no build record and no `ticket/<KEY>` branch, so the conductor spawned no settle. A settle by hand answered `skip:no-plan`, because the PR had no merged spec.
3. TK-594 (#899) and TK-638 (#922) had a SLICE line with a prose rest. The parser answered `none`, the settle answered `unknown:none`, and on the conductor path nothing posted a comment. The last word on the thread was "When it merges, we file the remaining slices".

## What changed

- `slice_board_marker` (`bin/lib/slice-board.sh`) is a weak slice marker: `SLICE: C0` with no `of #`, a `SLICE-REASON:` line, `This plan builds slice C0`, or a `<KEY>: C0`, `(C0)` or `slice C1` PR title. It is read only when there is no strong SLICE line.
- A strong SLICE line with a prose rest, or a weak marker, files ONE "Rest of <KEY>" child. The items are the plan's coverage rows that the merged slice did not cover (`sco_coverage`), else the master's own scope (`_sco_scope_items` over its description). Every row covered is `unknown:covered`. Nothing readable is `unknown:none`. There is no LLM call.
- A hand-opened PR with no merged spec uses its PR body as the plan. With no KEY in the title, the body must name the ticket.
- `mc_settle_merged` takes the board KEY from the PR title when there is no record and no `ticket/` branch.
- `bin/merged-ticket-advance.sh` holds a weak-marker slice too. When the ledger has no terminal file, it spawns `bin/slice-board-settle.sh --ticket <id> --park 1`. The summary line ends `slice-settle=N`.
- A master that already has children answers `exists:<keys>` (rc 0) and files nothing. A second lock, `state/slice-board/.lock-<project>-<KEY>-pr<n>`, keeps a record ledger and a state ledger of one merge apart.
- With park 1, `unknown:*`, `exists:*` and `deferred:file-failed` post ONE note on the master. The note says the rest is NOT filed (or where it is) and who files it. The owner is the knob `SLICE_BOARD_FILE_OWNER` (settings row `lib.slice-closeout.slice_board_file_owner`, default `the operator`). Only `fc_file_board` says "We filed", and only for children it recorded with a board id.
- `bin/board-closeout.sh` words `exists:` and names the owner on `unknown:`. It writes `<build>/slice-board/noted`, so the conductor posts no second note. The PR_CREATED comment adds "If we cannot file them, we say so here."

## Changed test premises

- `tests/slice-board.bh-8333-test.sh` S9: a spec 404 now reads the PR body as the plan (`unknown:none`, not `skip:no-plan`). S6: a failed filing now posts one "NOT filed yet" note, and still no move and no "We filed".
- `tests/merged-ticket-advance.bh-9865-test.sh` S9: a SLICE-REASON-only plan is now held as a slice.
- The three merged-ticket-advance suites expect the new `slice-settle=N` field.

Drive: `HARNESS_TEST_SANDBOX=1 bash tests/slice-board-remainder.bh-10080-test.sh`.
