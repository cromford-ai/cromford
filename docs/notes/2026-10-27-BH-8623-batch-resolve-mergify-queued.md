# BH-8623: batch-resolve does not read Mergify's queue rule as own CI, and the pure rebase pushes nothing to a PR Mergify holds

Doc: MERGE-CONDUCTOR, MERGIFY

## Cause

At 16:06Z on 2026-10-27, `bin/batch-resolve.sh` read a CANCELLED run of
Mergify's `Rule: queue on the harness label (queue)` check on #8570 as the PR's
own CI being red. `mrt_own_red` dropped check runs only by the name ERE
`BATCH_CI_IGNORE` (`^(Mergify|Publish share mirror)`), and the queue-rule name
does not match it. The lane then rebased #8570 through `mrt_rebase_pure` and
force-pushed it. `mrt_rebase_pure` made no Mergify read before the push. The
push dequeued #8570 (`PULL_REQUEST_UPDATED`) and dissolved batch #8620.

## Fix

All of it is in `bin/lib/mc/train.sh`, plus two caller arms.

1. `mrt_own_red` skips every check run of the `mergify` app, whatever its name.
   A run with no `app` object falls back to the name ERE that
   `mc_mergify_check` reads (`^Mergify|^Queue:|\(queue\)`). A run of any other
   app is own CI, so a job named `lint (queue)` still counts.
   `BATCH_CI_IGNORE` still applies on top.
2. `mrt_rebase_pure` takes an optional 9th arg, the PR URL. When the repo's
   provider is `mergify`, it asks `mc_mergify_holds` once, after the rebase and
   before `hold_push`. If Mergify holds the PR, it pushes nothing and returns
   the new rc 4. An unreadable answer pushes as before (the BH-8021 precedent).
   With no URL there is no read.
3. `bin/batch-resolve.sh` passes the URL. On rc 4 it removes its
   `rebased.txt` line, so the rebase budget is not spent, and it does not
   batch or park the PR this pass.
4. `bin/lib/br/opt/mechanical.sh` (`_brm_conflict`) passes the URL. On rc 4 it
   returns 1 with no counter and no record: today's ladder owns the PR.

`mrt_head_green` (the freeze lift) keeps its old filter: a pending queue-rule
run there only holds a freeze longer.

Test: `tests/batch-resolve-mergify-queued.bh-8623-test.sh`.
