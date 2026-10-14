# The PR a build opens is named after the ticket, and `## What` is cut at the merge base

Doc: RUN-BUILD-GRAPH

## What changed

**`bin/run-build.sh`**, three places, in two new marker blocks and one line.

`# >>> pr title subject` (inside `# >>> pr create ladder`) replaces
`PR_SUBJECT=$(git log -1 --format=%s)` with three rungs: the `.title` in
`$BUILD/ticket-meta.json`, then the newest commit subject that is not
`spec(<KEY>): the plan this build was executed from`, then HEAD's subject —
which is what the line did before, so a build with no ticket meta and nothing
but a spec commit still opens a PR with a name on it. A leading `<KEY>: ` is
stripped from whichever rung wins, because the create prefixes the key itself
and rung 2's subjects already carry it; the 80-character cut is unchanged.

`# >>> pr what list` replaces `git log -12 … "$BASE"..HEAD` with the merge base
against `origin/$BASE`, resolved exactly as `SCOPE_BASE` resolves it a thousand
lines earlier, and filters the spec commit out of the list. An unresolvable
merge base falls back to the ref itself: today's behaviour, never an empty
`## What`.

`PR_BODY_FOR`'s `EB_SUBJECT` now defaults to `${PR_SUBJECT:-}` and only falls
back to `git log -1`. The `:-` is load-bearing, not tidiness:
`tests/pr-body-closes-test.sh`, `tests/evidence-block-test.sh` and
`tests/hotfix-pr-label-test.sh` extract that block verbatim and source it under
`set -u` without setting `PR_SUBJECT`, and their rendered body is byte-identical
after this change.

**`bin/pr-title-backfill.sh`** (new, operator-invoked, no cron lane) retitles the
PRs opened before this landed. Dry run is the default; `--apply` writes.

**`tests/run-build-pr-title.bh-1415-test.sh`** and
**`tests/pr-title-backfill.bh-1415-test.sh`** (new) are the suites.

## Why

The spec artifact stage commits `spec(<KEY>): the plan this build was executed
from` AFTER execute, so at PR-open time HEAD *is* that commit and
`git log -1 --format=%s` was the title. The 2026-09-22 pool wave opened 33 PRs
(#1376-#1414) every one of which was called
`BH-<n>: spec(BH-<n>): the plan this build was executed from`. 68 of the repo's
last 100 PRs matched `: spec(` in their title when this was built; 8 were still
open.

The `## What` list had the sibling defect. `$BASE` is the LOCAL ref,
fast-forwarded once at build start and never again, while the pre-PR block
rebases the branch onto `origin/$BASE`. After that rebase `$BASE..HEAD` is
everything main gained since the local ref last moved — so #1414's What listed
`merge train: 1 approved PRs (#1362)`, `train: #1360` and a `cost:` commit as if
this branch had made them.

## Why a train subject is logged and not filtered

The ticket asks the What list to assert that none of its subjects is a
`merge train:` / `train:` commit. Filtering by text would delete a real commit
from any branch that legitimately made one, and failing the build would discard
a reviewed, pushed, green diff over a body section. So the merge-base cut is
what removes them, and a surviving train-shaped subject writes ONE line to
`$BUILD/pipeline.log`:

```
PR What list still carries a main-train subject after <sha>..HEAD — the base resolution is wrong
```

The check is a bash regex on the variable, never `grep -q` on a git pipe: grep
closing the pipe early answers 141 under `pipefail` and the warning would be
swallowed (BH-1248).

## The backfill, and what it refuses

```
bin/pr-title-backfill.sh [--apply] <slug> <pr-number>...
bin/pr-title-backfill.sh [--apply] --all-open <slug>
```

Per PR: read the PR, require `state == open`, require a title carrying the SAME
key on both sides of `: spec(…): `, read that key's issue, compose
`<KEY>: <issue title, own key stripped, cut at 80>`, PATCH, and confirm the
response body reads the new title back. Anything else prints `FAILED #<n>
status=<http>` and the run exits 1. rc 3 is "nothing was requested" — bad
arguments, no `gh`, or an open-PR list that could not be read, which is never
allowed to look like "no PRs are affected" (#768).

It keeps no watermark, no ledger and no lock. Its own matcher is the idempotency
key: a PR it retitled no longer matches the shape, so a second `--apply` over
the same list writes nothing. Nothing in the harness invokes it; it is run by
hand, dry first.

Refusals, each of which has a test: a closed or merged PR; an ordinary
`BH-<n>: <subject>` title; a subject that merely contains the word "spec"; a
bare `spec(BH-<n>): …` with no key prefix; a title whose two keys disagree
(`BH-1400: spec(BH-1399): …`); an issue that 404s or has an empty title; and an
issue title that is ITSELF the spec shape, which would otherwise write back the
defect it exists to remove.

## Verified

Both new suites red before the change and green after (`$BUILD/red.txt`), each
core behaviour mutation-checked one at a time — twelve mutations, twelve reds,
and the two that first survived are why `tests/pr-title-backfill.bh-1415-test.sh`
seeds every issue a negative could resolve to and carries case 12b. The dry run
was executed as shipped against `example-org/cromford`: 8 open PRs carry the
shape, 7 were skipped, nothing was written.
