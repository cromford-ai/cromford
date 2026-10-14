# The rebase train runs the caller check before it rebinds the approval (BH-6718)

Doc: MERGE-CONDUCTOR, RUN-BUILD-GRAPH

## The gap

`bin/rebase-train.sh` rebased a DIRTY approved PR onto main, ran typecheck and
unit tests, pushed, and rebound the approval to the new head. Typecheck does
not see shell, SQL, JSON or untyped JS. So a rebase onto a main that added a
caller of an interface the PR changed (the #4332 class) carried the approval
onto a head nobody reviewed.

## What changed

- After the unit-test verify and before the push, the `# >>> caller check
  (BH-6718)` block runs `bin/caller-check.sh` (BH-5791) on the rebased head,
  with `--base $(git merge-base origin/<base> HEAD)` and the record's
  `plan.md` (`/dev/null` when the record has none). The output goes to
  `$D/callers-rebase-train.txt`.
- rc 0 with `noreason=0 gone=0`: push and rebind, as before. Log line
  `caller check: <summary> — the approval carries over`.
- `gone>0` or `noreason>0`: push, no rebind (`$D/reviewed-sha` and the ledger
  row stay on the old head), and one
  `bin/lead-verdict.sh request <owner/repo> <pr> <new sha> --notes "rebase-train: caller check found <n> callers (<names>)"`.
  A failed request is logged (`lead review request failed (rc=N)`) and not
  retried.
- The check could not run (non-zero rc, an unreadable CALLERS line, or the
  lib or CLI missing): push, no rebind, no request. Log line
  `caller check: could-not-run (...)`.
- `CALLER_CHECK_MAX_LINES=0` (the BH-5791 off switch): push and rebind, as
  before, with one `caller check: off` line.
- The final line says `NOT rebound, the sweep waits for a review of the new
  head` when the approval did not move.

The push is never blocked. A head that is not rebound is held by the sweep's
head-bound check until a review binds it.

## Not covered

The check lists only interfaces that the PR's own diff changes. When main
renames or removes an interface and the PR adds a NEW call to the old name,
the result is `interfaces=0` and the approval carries over.

## Evidence

`grep 'caller check:' logs/rebase-train.log` on the box that runs the train.
Verified by `tests/rebase-train-caller-check.bh-6718-test.sh`.
