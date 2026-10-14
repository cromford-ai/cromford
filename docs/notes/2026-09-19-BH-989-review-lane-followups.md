# BH-989 — the review lane reads the standing-review ledger only when the local cache cannot answer

Doc: MERGE-CONDUCTOR

BH-989 carried three findings from the BH-872 review (#891), all in
`bin/review-prs.sh`. **Two of the three shipped on #891 itself**, in its own fix
rounds, before this branch was rebased onto it — so only D3's local-cache half
lands here. What was dropped, and what replaced it, is recorded below so the
ticket's acceptance can be read against what is actually on the branch.

**D3 (shipped here) — the per-tick read.** `pulls/N/reviews` was read, paginated,
for every open harness PR on every tick, ahead of any local check: ~55 open PRs ×
2 ticks/hour ≈ 110 reads/hour per box, for a lane that walks past most of those
PRs. #891 round 1 (Nit 7) put the read behind `gh_budget_low review-prs`. This
adds the free half: the read is skipped outright when `.ledger_sha` already
equals this head.

`.ledger_sha` is a new per-PR watermark meaning "a dismissal pass at this head
completed with nothing left standing that had to go". It exists because a
PIPELINE PR never gets a `.sha` row — nothing reviews it — and those are ~45 of
the ~55 open harness PRs, so without a watermark of their own the cache could
never answer for any of them. `rp_dismiss_own` now returns rc 1 when a dismissal
was refused, and the watermark is written only when the reviews list was readable
**and** that rc was 0: a deferred read, an unreadable list or a refused dismissal
leaves no watermark and the next tick asks again. A kept at-head row is not a
failure — it is the verdict the keep-sha deliberately leaves standing.

**The budget-low path (the #891 fix round's finding, closed differently).** A tick
that defers the dismissal must cost a TICK, never a DISMISSAL. The head moves to
H2, the first tick at H2 finds the budget low so the pass never runs, and the
ledger gate reads anyway (it is the money gate), buys the review and records
`.sha = H2`. If the cache skip were keyed on `.sha`, every later tick would
short-circuit and a legacy `operator` CHANGES_REQUESTED at H1 would keep the PR out
of Mergify's queue until H3. This branch's answer is the key itself: the skip is
on `.ledger_sha`, which that tick never wrote, so the next healthy tick reads and
dismisses. (The version of this branch written against the pre-rebase parent
instead hung a second dismissal pass off the ledger gate's read; on the parent
that gate is `rp_rehydrate`, which makes its own read in its own shape, so the
key-choice above is what carries the guarantee. Case 6b pins both ticks.)

The skip is deliberately **not** on `.sha`. A head can be reviewed on a tick
whose dismissal pass was deferred (budget low) or refused; skipping on `.sha`
would leave a stale-head blocking row standing until the branch moved again.

The watermark carries no `.verdict`, so `merge_retry` returns at its first check
on a row that has only that key, and `bin/review-autopilot.sh` (which reads
`.sha`) is unaffected. The ledger gate (`rp_rehydrate`) is deliberately NOT
budget-guarded: it is the last dedupe check before a paid review and it already
runs only on a cache miss.

**D1 (dropped — shipped by #891 round 1, Important 4).** The ticket asked for a
self-authored APPROVE to stop 422-ing. #891 took the first of the two fix shapes
the ticket offered: an `--approve` now goes out on the lane's DEFAULT credential,
which is never the PR's author, so GitHub is never asked to refuse it, and the
post's stderr is captured so a refusal logs its reason. That is strictly better
than this ticket's alternative (degrade the APPROVE to a COMMENT review), because
the PR keeps a real APPROVED row and Mergify's `github-review-approved` becomes
true. `rp_self_authored` and `harness_pr_is_app_login` are therefore not added.

**D2 (dropped — shipped by #891 round 1, Important 3).** The ticket asked that
`rp_dismiss_own` stop dismissing the row bound to the CURRENT head on PRs this
lane reviews itself. #891 decides whether a PR is a pipeline PR FIRST and passes
`rp_dismiss_own` a keep-sha — empty on the pipeline path, the current head on a
hand PR — in one pass. `rp_pipeline_dismiss` is therefore not added; a second
dismissal pass would only re-do what the one call already does. Cases 2 and 3 of
the suite below are kept as regression cover for that behaviour, which D3's
watermark now depends on.

**State keys touched:** `state/<project>.pr-reviews.json` gains `ledger_sha`.
**Suite:** `tests/review-prs-followups.bh-989-test.sh` (38 assertions), run with
`HARNESS_TEST_SANDBOX=1`. Red before green on the parent tree: 3 assertions fail
(cases 4 and 5 — no watermark, and tick 2 reads the ledger again). `tests/review-prs-dedupe-test.sh` is untouched
and is the regression pin for the pipeline path and for the D1/D2 behaviour above.
