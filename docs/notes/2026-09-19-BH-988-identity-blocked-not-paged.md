# An identity-blocked conductor row stops paging the budget and the TTL, and stops calling itself "waiting on a required check"

Doc: MERGE-CONDUCTOR

Follow-up from the head-bound review of PR #908 (BH-800, the per-tick protection
read and push identity), raised MEDIUM twice on 2026-09-19 and non-blocking
there. When the conductor's read says the push identity is not on the base
branch's push allow-list, GitHub answers `mergeState BLOCKED` with no required
check to report and no review to buy. Nothing in this lane moves that row — only
a repo admin does — and it was buying three alerts where it should buy one:

1. `mc_budget_check` paged at the WAIT_CI budget (30m).
2. `mc_stuck_check` paged again at the WAIT_CI TTL (90m).
3. that second line rendered `waiting on a required check to report on this head
   (IDENTITY_NOT_PERMITTED …: … no required checks …)` — a sentence that
   contradicts its own parenthesis.

## What changed

All of it is in `bin/lib/merge-conductor-lib.sh`. `bin/merge-conductor.sh` is not
touched.

**`mc_identity_blocked <reason>` (new).** rc 0 when the row reason is exactly
`IDENTITY_NOT_PERMITTED` or begins `IDENTITY_NOT_PERMITTED ` — a prefix
terminated by the end of the string or by a space, never a substring search.
This predicate suppresses alerts, so every reason it matches by accident is a PR
that stops paging and nobody finds out:
`conflict-unresolvable: bin/lib/IDENTITY_NOT_PERMITTED-notes.sh` carries the
token and is a park the resolver owns, `IDENTITY_NOT_PERMITTEDX` is a different
word, `-` and the empty string are rows with nothing recorded, and all of them
still page.

**`mc_budget_check`** gains a first arm on the existing chain, the same shape the
resolver-owned park already has: no alert, one conductor-log line naming the
alert that IS the page, and the row still falls through to `mc_row_put` /
`mc_ledger_put`, so it still ages and still records its `alerted` mark.

**`mc_stuck_check`** returns 1 after the TTL test and BEFORE `mkdir -p
"$MC_STUCK_DIR"`. Before the marker, not after: the (PR, state, head) triple
stays unspent, so the day an admin permits the identity and the row then
genuinely stalls on a check, it can still page exactly once. rc 1 also means
`bin/merge-conductor.sh` does not run `stuck_rekick`, whose WAIT_CI arm is a CI
close/reopen kick that would not move a row GitHub is refusing on identity.

**`mc_stuck_waiting_on`'s `WAIT_CI` arm** becomes two-way: an identity-blocked
reason prints `a repo admin to permit this identity to push to the base branch
(<reason>)`; every other reason prints today's string byte for byte. The
`mc_stuck_check` guard above makes this unreachable in production today. It is
kept because it is what keeps the sentence true if that guard is ever relaxed or
a second caller appears.

## Which rows this affects

Only rows whose reason is the `IDENTITY_NOT_PERMITTED` prefix. Every other
reason — `checks pending`, `checks none`, `checks flake …`,
`mergeState BLOCKED (required context not green)`, every park — pages exactly as
it did before, at the same budget and the same TTL, with the same words.

## Ordering: this lands behind PR #908

`mc_classify` cannot emit an `IDENTITY_NOT_PERMITTED` reason on `main` yet —
that classifier branch is PR #908's (BH-800). Until it merges this predicate
matches nothing, which is why the suppression is keyed on the ROW REASON rather
than on `MC_IDENTITY_BLOCKED`: the reason is red today and green in both worlds,
and the variable is unset here and set to `0` as the first statement of #908's
own block. The PR declares `Depends on #800 (PR #908)` and
`bin/lib/pr-dep-gate.sh` holds the merge on it.

## Commands

    # the per-ticket suite
    HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-identity.bh-988-test.sh

    # the two suites that own these functions
    HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/conductor-sticky-handoff-test.sh
