# BH-9500: an all-inconclusive evidence block does not end APPROVE (2026-11-11)

Slice C3 of #9441, scope item 4.

## Problem

The lead review abandoned 36 PRs whose acceptance claims were almost all
INCONCLUSIVE (29/29, 18/18, 16/16). The in-build review approved each of them
at tier 1. The PR body printed `(VERDICT: APPROVE)` as a fixed string. The
evidence scorer (`bin/lib/evidence.sh`) wrote the counts to
`$BUILD/evidence.json`, and no step after the review lenses read them.
`bin/lib/rb/result.sh` demotes the tier only when `EVIDENCE_GATE_ENFORCE=1`
(default 0).

## Rule

After the lenses (`bin/lib/rb/review.sh`, region `evidence inbuild cap
(BH-9500)`), `bin/lib/evidence-inbuild.sh` reads `evidence.json`.

- "All inconclusive": the file is readable, `total` >= 1 and
  `inconclusive == total`. Any CONFIRMED or REFUTED claim, total 0, or an
  unreadable file changes nothing.
- If the review ends `VERDICT: APPROVE`, the lib appends one marked block to
  `review.md`: one `- [NOTE] not verified here: claim <n>: <claim> (<reason>)`
  line per claim, a sentence that the review reports MERGE-WITH-NOTES, then
  `TIER: 2` and `VERDICT: APPROVE`.
- The reason is the scorer's own note for the claim (for example
  `harness suite could not run (harness-suite.txt)` or `no artifact named`).
  The scorer does not know "no database" or "no browser", so the lib does not
  guess them.
- The PR body says `(VERDICT: MERGE-WITH-NOTES, 0 of <N> acceptance claims
  proven)` in place of `(VERDICT: APPROVE)`.
- `pipeline.log` gets one `EVIDENCE INBUILD CAP:` line per build.

## What stays APPROVE, and why

The machine verdict line in `review.md` stays `VERDICT: APPROVE`. About 15
readers gate on that word (merge sweep, rebase train, classify, the worker's
builder approve). REVIEW LEVELS says a check this box cannot run is a NOTE and
the verdict does not wait on it. A BLOCK would spend a fix round on a check no
fix can run, and the build would end ABANDONED.

The teeth are the tier. `bin/lib/rb/pr.sh` reads `tail -2 review.md` for
`TIER: 1`. It now reads `TIER: 2`, so the build never self-merges at tier 1 on
zero proven claims. The lead review judges it.

## Knob

`EVIDENCE_INBUILD_CAP` (`catalog/lanes.d/_lib.evidence-inbuild.json`, lib id
`evidence-inbuild`), default 1. Set 0 for log only: `review.md` and the PR body
do not change, and `pipeline.log` says `not enforced`. A value that is not
on/off enforces and writes one ALERTS line. The code fallback is
`EI_DEFAULT_ENFORCE=1`.

## Out of scope

The ledger verdict detail, the board close-out comment text and the board-bot
`pr_created` APPROVE field stay as they are (other slices of #9441).

## Test

`tests/evidence-inbuild.bh-9500-test.sh`.
