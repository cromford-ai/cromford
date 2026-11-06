# A schema restamp after a rebase keeps the review verdict (BH-9066, slice C0)

Doc: MERGE-CONDUCTOR

## What changed

`bin/lib/patch-same.sh` has two new functions.

- `patch_same_restamp` (the `restamp-rebase` rung). It answers "same" when the
  new head is the reviewed patch on a newer main, with the PR's schema
  fragments renamed to later stamps and every reference rewritten. It owns only
  the case where the reviewed sha is not an ancestor of the new head;
  `restamp_same` (BH-6842) keeps the descendant case.
- `patch_same_review`: `patch_same || restamp_same || patch_same_restamp`.

The review callers use `patch_same_review` or the rung: the conductor rebind,
`lead_carry`, `ld_classify`, gate 50, `bin/review-prs.sh` and
`bin/review-autopilot.sh`. The CI and test reuse callers stay on byte
`patch_same`. `tests/patch-same-callers.bh-9066-test.sh` pins that split.

The conductor's rebind log line for a restamp now reads
`rebound: <how> (bin/lib/patch-same.sh; no reviewed content change)`.

`bin/patch-same-replay.sh --repo <owner/repo> --last <N>` replays the byte and
review answers over the last N merged PRs. It calls no model. It writes only
`refs/psr/base/<pr>` in the clone it is given, so give it a private clone
(`--clone`).

## The replay base

The replay compares each pair against main as it was before the PR landed. A
merged PR's heads are ancestors of today's main, so a compare against
`origin/main` gives two empty diffs. The r3 script did that: over the last 50
merged PRs it read 28 pairs as "code changed", and every one of those answers
was empty.

The script now reads `merge_commit_sha` with each merged PR. The base is
`<merge>^1` when the last reviewed head is not in it. When a batch or train
merge landed the head first, the base is the parent of the first-parent commit
that landed it. The script walks `git rev-list --first-parent` for that
commit. With git 2.43, `--first-parent --ancestry-path` prints nothing when the
head came in through a second parent, so the script does not use it. No merge
sha, a merge commit the clone cannot fetch, or an empty diff on either head
gives the miss reason `base unresolved`. That pair is never a hit and never
"code changed".

A miss where a head adds a schema fragment now has two reasons: `restamp plus
code change` (a file outside `worker/*/schema.d/` has a different diff) and
`fragment order or suffix changed` (every other file has the same diff).

## Measured

At plan time, 21 of the 28 pairs were classified by hand with the base
`<merge>^1`. 0 pairs differed only by a restamp. 2 pairs differed only in
`.harness/specs/<KEY>/plan.md` (#9046, #8984). 3 pairs differed only in one
catalog file (#9036, #8454 two times). 2 pairs differed only in one test
(#8987, #8943). 1 pair added a new schema fragment (#9046). The other pairs
changed code. 7 pairs (#8720 five times, #8713 two times) landed through a
batch merge and were not classified by hand. The script's batch base covers
them now.

On main, `restamp_same` (BH-6842) already replays a restamp when the reviewed
head is an ancestor (#8987: `lead-replay:b436cecfee50 how:restamp
by:merge-conductor`). So this rung saves a review only for a restamp after a
rebase. On this sample it saves close to 0 reviews. The plan.md-only pairs are
a measured candidate for a later slice.

The lead-reviewed heads per merged PR, from the plan-time run over the last 50
merged PRs: median 1, p90 3, max 6. The ticket's target is p90 1. This slice
alone does not reach it.

The build box for r4 had no GitHub egress, so the corrected replay did not run
there (`bin/patch-same-replay.sh` exit 3, "the merged PR list could not be
read"). Run it after deploy:
`bin/patch-same-replay.sh --repo example-org/cromford --last 50 --clone /tmp/psr-clone`
on a private clone.

## Why

The conductor land-rebase, then the restamp lane, moved a reviewed head with no
change to the reviewed work (#9000, 2026-11-03). Each move bought a new lead
review.

## Not in this slice

The lockfile-only and whitespace rules, and ticket items 2 to 5, are later
slices. A whitespace or lockfile edit is still a change.

## Test change

`tests/lead-delta-restamp.bh-7118-test.sh` L6 said a restamp of a rewritten G
(G not an ancestor of H) is never a replay. In L6, G was rewritten with
`--amend -m` only, so H is G's patch restamped. That is the shape this ticket
makes a replay. L6 now asserts that `restamp_same` still refuses it and that
`ld_classify` answers `replay restamp-rebase`. The new L6b keeps the negative:
a rewrite with a code change, then a restamp, is not a replay.
