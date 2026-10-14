# BH-4664: external PRs in the blocked-resolver (BH-4667 is the tracer)

Doc: PR-OWNERSHIP, BR-OPT

## Why

the operator asked on 2026-10-05 that third-party PRs (collaborator-1 on project-4 and project-3)
get the same pipeline as harness PRs. Until now `bin/blocked-resolver.sh` only
looked at PRs the harness wrote. A reviewer's CHANGES_REQUESTED on an
outsider's PR, or a branch that went dirty, had no consumer.

## What changed (BH-4667, this slice)

`bin/lib/br/opt/external.sh` is a new optional module. `br_candidates` calls its
source last, and `br_one` hands its rows to its gates.

**Eligibility.** The project's knob is above 0. The PR is open and not a draft,
it was updated inside `BR_REVIEW_LOOKBACK_SECS`, and its author is not one of
ours (`harness_pr_author_match`; with that helper missing the project is
skipped, because unknown ownership is never external). Then either a standing
CHANGES_REQUESTED speaks for its head (`br_review_newest`, the same read
harness PRs get), which gives reason `external-changes-requested`, or
`mergeable_state` is `dirty`, which gives `external-dirty`. The row's ticket
key is `-`, so `br_one` never derives a key from an outsider's branch name.

**Gates** (`br_xpr_gate`, every refusal is rc 3 with nothing written):

- the PR is re-read once and must still be open, and the knob is re-read
- D3 push right: the head repo is this repo, or a fork with
  `maintainer_can_modify`. A null head repo is a failed read, not "no push
  right". With no push right, `br_xpr_nopush` runs if a module defines it.
- D4 quiet: the head commit's committer date must be at least
  `author_quiet_min` minutes old, or the line is
  `AUTHOR_ACTIVE <slug>#<n> head=<h8> committed <m>m ago (quiet window <q>m) — retried next tick`.
  A head authored as the harness git identity (`GI_EMAIL`) counts as quiet.

A row that passes gets `external=true` stamped on its record, and the gate
exports `BR_XPR_HEAD BR_XPR_REF BR_XPR_SLUG BR_XPR_NUM BR_XPR_AUTHOR
BR_XPR_ROUNDS` for the hook.

**Knobs.** `external_pr.fix_rounds.<project>` (env fallback
`EXTERNAL_PR_FIX_ROUNDS`, default 0 = off) and `external_pr.author_quiet_min`
(env `EXTERNAL_PR_AUTHOR_QUIET_MIN`, default 60). The D1 row wins, then env,
then the default. A settings outage reads the default and never the env.
`worker/jobs/schema.sql` seeds project-4 and project-3 at 1 and the quiet window at
60. A project that is off logs `external fix rounds off for <p> (<src>)` once
per tick.

**The belt.** An external PR is never closed, rebuilt or abandoned by this
lane, and that holds with every external module missing:

- `br_is_external` is true for an `external-*` reason, a gate that passed in
  this row's subshell, or a record stamped `external=true`
- `br_fix_terminal`, `br_abandon` and `br_rebuild_fresh` check it first. They
  call `br_xpr_terminal` if a module defines it, and otherwise log
  `external PR — never closed or rebuilt; left for the author` and return 3.
  `br_abandon` never answers 0 for an external row, even when the hook did:
  `br_abandon_rebuild` and cirepair read its rc 0 as "closed and ABANDONED
  recorded", and would tell the ticket so or close the earlier parked PR
- `br_close_pr` reads the PR author. A positive outsider read is rc 3 with a
  `refused:` line, and no comment and no PATCH. A read that answers with no
  login keeps the old path; a read that FAILS is rc 75, like the state read.
  Its callers read rc 3 as "parked for the author, nothing recorded", never as
  the rc-75 retry, and `br_abandon` and `br_rebuild_fresh` pass the 3 up
- Every parked arm sets `BR_XPR_PARKED`, and `br_one` reads it after the
  dispatch the way it reads `BR_REBUILD_WAITING`: rc 3, no `PER_TICK` slot, so
  an outsider PR that reaches the ladder from another source cannot spend its
  project's share every tick
- `br_fix_terminal_word` says `PARKED for the author instead`

`br_one` returns rc 3 (no rung, no `PER_TICK` slot) for an external row when
the module is absent, a gate refuses, or no hook is installed:
`external <reason> <slug>#<n>: no handler installed`.

## The hooks, and who fills them

| hook | module | status |
|---|---|---|
| `br_xpr_fix` | `extfix.sh` | sibling, not yet shipped |
| `br_xpr_rebase` | `extrebase.sh` | sibling, not yet shipped |
| `br_xpr_nopush`, `br_xpr_terminal` | `extpark.sh` | shipped, BH-4669 (BH-4664.2) |

All four names are already in `BR_OPT_MODULES`. An absent file is skipped
silently. What each hook does is that sibling's to document when it lands.

## Hand back (extpark, BH-4669)

`bin/lib/br/opt/extpark.sh` tells the author once per head, and it never
closes, enqueues or abandons. Both hooks re-read the PR, so they bind to the
head the author holds now. They write the `pr_attempts` row (`ext-nopush` or
`ext-park`, keyed on that head) BEFORE the comment, which gives these outcomes:

- A row already there means silence.
- A ledger outage or a failed put posts nothing.
- A comment that fails after its put deletes the row, so the next tick
  retries. If the delete fails too, the head stays silent and one line says so.
- An unreadable or closed PR posts nothing.

- `br_xpr_nopush` (a fork with maintainer edits off) posts: "The harness can't
  push to this branch (it's a fork with maintainer edits turned off), so this
  one is yours. The review above lists what to change." Its rc is ignored.
- `br_xpr_terminal` reads the record's `fixrounds` against
  `br_fix_cap … review-changes-requested` (`BR_REVIEW_FIX_ROUNDS`, default 2)
  for every reason. Below the cap it logs `round <n> of <cap> spent; waits for
  the next head, nothing closed` and answers rc 0, which `br_abandon` still
  maps to 3. At or over the cap it posts "Over to you, @<author>. …", records
  an `external-parked` attempt on the record key it was given (`$2`; `$6` is
  never read, because `br_abandon` passes a sentence there), and answers rc 3
  with `BR_XPR_PARKED` set, so `br_one` spends no `PER_TICK` slot.

A new head pushed after a hand-back is a new key. If the cap is still spent,
that head gets one more hand-back. `tests/external-pr-handback.bh-4669-test.sh`
covers the hand-back: X4 through a real lane tick, and X5 through the lifted
`br_fix_terminal`, `br_abandon` and `br_rebuild_fresh`.

## Known cost

Each push a sibling makes to an external head moves the head, so it buys one
more head-bound review from `bin/review-prs.sh`. The gates cost two GETs per
row that reaches them (the PR and its head commit). The source costs one open
list per opted-in project per tick, behind `gh_budget_low`.

## Proof

`tests/external-pr-source.bh-4667-test.sh` drives a real tick on a fake-gh
project-3 PR, plus the belt per function.
