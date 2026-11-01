# BH-8333: a sliced in-app board ticket never closes as done after C0

Doc: VERIFICATION-MAP

## Why

project-1 TK-360 was split into five slices, C0 to C4. The build shipped C0
(example-org/project-1#752, `SLICE: C0 of #cmvmtfpj2000k07kzd588kq7r`). The
close-out said "This ticket is closed" and moved TK-360 to `done`. C1 to C4
were never filed. Three causes:

1. `bin/board-closeout.sh` mapped `PR_MERGED` to `done` for every board build.
   It never read the plan's SLICE line.
2. `slice_remainder_parse` (BH-5961) refused a parent that is not a number. A
   board ticket id is a cuid.
3. `mc_settle_merged` did nothing for a board project after a merge.

## What changed

- `bin/lib/slice-remainder.sh`: `slice_remainder_parse` takes a board id token
  (`[A-Za-z0-9][A-Za-z0-9_-]*`). A token ends at a character a token cannot
  hold, so `#TK-3600` is not `#TK-360`. An issue number keeps its `[^0-9]`
  edge byte for byte.
- `bin/lib/fc-board.sh`: kind `slice`. No contract child, `after` positions
  only, fails open on a board without `dependencies`. Its park comment says
  "Slice C<k> is merged ... Not live yet". `FC_BOARD_PARK=0` files with no
  comment and no move. Decompose and rollout do not change.
- `bin/lib/slice-board.sh` (new): `slice_board_settle`. Order: switch, ledger,
  plan (the record's, else the merged `.harness/specs/<KEY>/plan.md`), token,
  parent read (its key must be KEY), parse, file. Children first. The master
  is never moved before every child exists.
- `bin/slice-board-settle.sh` (new): the CLI around it.
- `bin/board-closeout.sh`: a board build whose plan has a SLICE line for this
  ticket is never moved to `done`. `PR_MERGED` files the children (park 0),
  posts one comment that names them, and moves the master to `in_progress`.
  `deferred:*` exits 1 with nothing posted. `PR_CREATED` stays `review` and
  says the rest is filed at merge.
- `bin/lib/mc/settle.sh`: on a board project, `mc_settle_merged` spawns the
  CLI detached (`--park 1`), with the lock fds closed.
- The six board triage prompts: a SLICE result is never `done`, the
  system-actor exception included.

The merge conductor's key is `<slug>#<n>`, not the board KEY. So the conductor
spawn reads the KEY and the board id from the record's `job.json` (`.key`,
`.ticket_id`), else the KEY from the `ticket/<key>[-r<n>]` branch. With no KEY
it does not spawn and writes one log line. With no `--ticket`, a board id
SLICE token is a candidate, and the parent read must return `<KEY>`.

No new knob. The switch is BH-5961's (`slice-remainder-off`,
`SLICE_REMAINDER_FILE=0`), and the cap is `SLICE_REMAINDER_MAX`.

## Ledger and retention

`<record>/slice-board/` rides the build record and its retention. With no
record, `state/slice-board/<project>-<KEY>-pr<n>/` holds one small directory
per merged board slice PR. A skip deletes its own directory, so a merge that
is not a slice leaves nothing.

## How to check it

- `HARNESS_TEST_SANDBOX=1 bash tests/slice-board.bh-8333-test.sh`
- By hand, on a box: `bin/slice-board-settle.sh <project> <KEY> <pr-url> <build-dir> --ticket <id> --park 1`.
  Read the word, then `<build-dir>/slice-board/settle.log`.

## Not done here

TK-360's children were filed by hand on 2026-10-25 (TK-364 to TK-367). This
change does not backfill. The project-1 app's own deploy audit (TK-135) lives in
example-org/project-1. If it also moves an `in_progress` master with open
children to `done`, that repo needs its own ticket.
