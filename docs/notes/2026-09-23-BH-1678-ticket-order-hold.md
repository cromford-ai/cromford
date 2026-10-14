# BH-1678: the merge queue follows the child issue's Blocked-by and Order

Doc: MERGE-CONDUCTOR

## What changed

- `pdg_ticket_deps <slug> <issue>` in `bin/lib/pr-dep-gate.sh` is no longer a stub.
  It reads the issue body over REST and prints the `Blocked-by: #N` parents, with the
  same discipline as `PDG_DEP_RE`: anchored after markdown noise, `>`-quoted lines
  ignored, fenced blocks and inline code blanked. An unreadable issue answers rc 2.
- `pdg_hold` has a ticket half. It runs only when all of these hold:
  `PR_DEP_GATE_TICKET` is not 0, the slug's fleet.conf row has board_prefix `-`, and
  the PR body links its ticket with a `Closes #I` line. Then:
  - an OPEN `Blocked-by` parent of #I holds the PR (rc 0). The lanes log
    `HELD by the PR-dependency gate … it declares Blocked-by #N`;
  - when #I is `Part of #P` with `Order: n of m` and n > 1, a sibling of #P with a
    lower Order holds the PR while that sibling has an open PR whose row in the
    conductor's `pr-state.tsv` is exactly READY or QUEUED. BLOCKED_*, WAIT_*, no row,
    no open PR or a closed sibling never holds;
  - a failed issue, sibling-list or pulls-list read is rc 2, which every lane holds on.
- Anything else is the body-only `Depends on #N` gate, unchanged, with no extra read.
  `Blocked-by` in the PR body is never read.

## Why

The 2026-09-23 project-5 wave queued contract #3215 beside the children that edit
the same registry files. The decomposer writes `Blocked-by` / `Part of` / `Order` on
the child ISSUE, and `pdg_hold` only read the PR body.

## What this supersedes

`docs/MERGE-CONDUCTOR.md` §8 still calls `PR_DEP_GATE_TICKET` reserved and says
"today 0 and 1 behave identically". That stopped being true here: 0 now turns the
ticket half off. `docs/verification-map/entries/BH-1669.md` still describes
`pdg_ticket_deps` as a stub for the same reason. The ticket did not allow editing
MERGE-CONDUCTOR.md, so this note is the correction.

## Costs

Only a child on an issues board pays: one issue-body read per PR per call, plus one
paginated open-issues list and one paginated open-pulls list when Order is 2 or more.
All REST, no GraphQL.
