# BH-3935: the PR-owner age ladder (BH-3929.3)

Doc: PR-OWNERSHIP

**What changed.** `po_stale` (`bin/lib/pr-owner/stale.sh`) is no longer a stub.
On every sweep it ages an OWNED or EXTERNAL PR that has a conductor row which is
not READY/QUEUED/MERGING or terminal. The clock is the newest of three dates: the
head commit, the newest verdict, and the PR's `created_at`. When the clock passes
`pr_stale.rebase_hours`, the PR is rebased through `mc_rebase`. At
`pr_stale.replan_days` the conductor row parks `BLOCKED_HUMAN stale-replan: …`.
At `pr_stale.close_days` the hook posts one plain comment, closes the PR, and
moves the ticket back to todo. Each rung runs once per head, through a D1
`pr_attempts` row (`stale-rebase|stale-replan|stale-close`), and logs one
`STALE_RUNG` line in `logs/pr-owner-sweep.log`.

**The resolver's rung.** `bin/lib/br/opt/stale.sh` (`br_opt_stale_rung`, a new
optional module, `stale` in `BR_OPT_MODULES`) takes the `stale-replan` park. It
writes a `KIND: stale-replan` build note and enqueues one fresh build. Once the
re-plan's PR exists it closes the stale PR as superseded, unless the stale PR's
head moved. `br_ladder_class` and `br_reason_of` gained a `stale-replan` arm in
both copies. `br_one` returns 3 for a stale park when the module is off, so
the park never reaches a model-call rung. `bin/lib/rb/plan.sh` frames the note
as an automatic re-plan, not as an adjudication ruling.

**Shared cap.** `br_ci_replan_floor` now counts `KIND: stale-replan` notes as well
as `KIND: ci-replan` ones. So `BR_CI_REPLAN_MAX` limits the automatic re-plans of
a ticket whichever ladder asks for them.

**Decided here.** The ticket named `br_ci_supersede_parked` for the supersede.
That function only closes a head one of the CI-repair rounds pushed, which a
stale PR never has, so the stale module does its own supersede: the same
successor read and `br_close_pr`, behind an unchanged-head guard. The PR's
`created_at` joins the clock, so a PR opened today on an old commit is not
rebased at once. Rungs 1 and 2 skip a park the resolver already owns. Rung 3
does not, so an exhausted park still ends.
