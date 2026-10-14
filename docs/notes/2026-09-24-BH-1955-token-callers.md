# Every board caller resolves its token the same way, and a prisma repo's suite gets its client first

Doc: BOARD-API-CONTRACT

## What changed

- **New `bin/lib/board-creds.sh`.** `board_token_var` and `board_base_var` sit on
  `bin/lib/internal-token.sh` (BH-1953), which still decides which variable is
  which. They add the refusal every caller now shares. If there is no match, two
  matches, or the env file can't be read, they print nothing and return 1. They
  also write one ALERTS line through `flags/alerted-token-<project>-<day>`, the
  same flag `bin/internal-token-for.sh` writes. So a broken env file gets one
  line per project per day across every caller and sweep. The line has
  variable names only, never values.
- **Four callers dropped their own `grep | head -1`.** These are
  `bin/triage-gate.sh` (the generic in-app arm), `bin/run-decompose.sh`,
  `bin/run-build.sh` (`TICKET_FP`, `TICKET_META`) and
  `bin/file-health-ticket.sh`. The old regex had no digits, so `project-32_` never
  matched and triage-gate died on `${!}`. It also took the first of two tokens
  without a word.
- **One fail-CLOSED exit in triage-gate.** Everywhere else the gate fails open.
  But an unresolvable token or base on the generic arm (none, two, an empty
  value, or no lib) now prints `SKIP token-unresolved` and fetches nothing.
  Under `--buildable` it prints `BLOCKED token-unresolved`, and under
  `--pending` it exits 1. `bin/board-closeout.sh` and `bin/fly-dispatch.sh` read
  BLOCKED as defer. The four named arms (project-1/project-2/project-3/project-4) are
  unchanged.
- **run-decompose and file-health-ticket build their board URLs from
  `fc_board_base`** (fleet.conf column 4), so neither file has a board path
  literal left. The last `/api/board` in run-decompose went in BH-982 (`3d8c3f6`)
  and BH-1340 (`8d63cea`). This change removes `BASE_VAR` from the re-map reads.
- **run-build keeps its fail-open gates.** A refused token means no board call
  and the documented "no snapshot", not a stopped build.
- **HARNESS-VERIFY prelude.** The npm arm of `HARNESS_SUITE_RUN` runs
  `npx prisma generate` before the suite when `prisma/schema.prisma` or
  `prisma/schema/` exists. It records `HARNESS_PRELUDE: npx prisma generate
  (rc=N)` or `HARNESS_PRELUDE: none (no prisma schema)` in the suite file and in
  pipeline.log. A failed generate is evidence and never a stop. evidence.md
  prints a `repo suite prelude` row only when that line exists, so older records
  render the same as before.

## Not in this change

`fc_board_base` (`bin/lib/file-children.sh`) and `bin/decompose-parent-close.sh`
still read `*_API_BASE` with their own regex. So a project whose base is
`*_APP_BASE` or has a digit prefix still can't file a health ticket. It now
says so with a `FAIL:` line.

Pinned by `tests/token-callers.bh-1955-test.sh` and
`tests/verify-prelude.bh-1955-test.sh`.
