# A PR Mergify did not name goes back in after a batch ejection (BH-4428)

Doc: MERGE-CONDUCTOR, MERGIFY

## Why

On 2026-10-04 ten PRs were ejected from Mergify batches between 01:36 and
11:17Z. Nine were innocent, every one green on its own head. Each sat on
`WAIT_CI queue-ejected — push a fix` until a human requeued them by hand, and
nothing merged to main from 11:33Z to about 18:30Z.

The BH-636 re-entry arm's only gate was `fr_reentry_gate` (BH-3776). It
attributes a batch failure by failing suite name against the PR's files. The
check that failed, `Pure-logic gate fixtures`, is a job name, so the verdict
was `unknown`, and `unknown` on the UNSTABLE head Mergify leaves behind never
re-queues. Mergify's own verdict sits in the same dequeue comment and was
never read.

## What the payloads said

Read 2026-10-04 (`gh api repos/example-org/cromford/issues/<n>/comments`,
`pulls/<draft>`):

| PR | identifying draft | draft title |
|---|---|---|
| #4121 | #4279 | `checking #4121 on main (a00ade0)` |
| #3981 | #4290 | `checking #3981 on main (a00ade0)` |
| #4050 | #4258 | `checking #4050 on main (a00ade0)` |
| #3995 | #4269 | `checking #3995 on main (a00ade0)` |
| #4049 | #4335 | `checking #4049 on main (a00ade0), stacked on #4187` |
| #4002 | #4236 | `checking #4002 on main (9d50520), stacked on #3994` |
| #4197 | #4358 | `checking #4197 on main (d926f29)` |

Every one ends `❌ **Checks failed** · on draft #N · identified as the failing
PR`, on a single-PR draft, and most failed the same check on the same base
`a00ade0`. #4121 later passed alone on `89f7dd8` and merged. Main at `a00ade0`
was red, and Mergify's bisect named every PR it tested alone. So the ticket's
literal rule (named, or alone, is the culprit) would have rescued none of the
nine. The `sharedred` verdict below is the evidence-based downgrade for that.

## What changed

`bin/lib/mc-batch-eject.sh`, sourced by the conductor after
`mc-foreign-red.sh`. `bej_reentry_gate` replaces the arm's `fr_reentry_gate`
call when the lib is present, with the same contract. It reads the newest
dequeued `mergify[bot]` comment bound to the head (by created_at,id), and the
title of the draft named on its LAST `Checks failed` line:

| verdict | rule | what the arm does |
|---|---|---|
| `culprit` | named on a multi-PR draft, or tested alone with fewer than `MC_BATCH_EJECT_SHARED_MIN` PRs alone on that base sharing a failing check | `fr_reentry_gate` exactly as before; when it does not re-queue, ONE PR comment per head (`bejculprit` mark first) naming the draft, each failing check and its run link. A PR tested alone gets it on the tick after its verdict was first read |
| `sharedred` | tested alone, and at least `MC_BATCH_EJECT_SHARED_MIN` (default 2) distinct PRs were tested alone on the same base with a failing check in common (`bejsolo` ledger) | no culprit comment. Re-queued once per head when the main-red freeze is down, the head's own checks are green, and the base branch has moved off that base (one branch read; a failed read waits) |
| `bystander` | the draft held two or more PRs, this one was not named, `Failing checks:` present | re-queued once per head when the freeze is down and the head's own checks are green (CLEAN, or UNSTABLE only through Mergify's checks) |
| `unknown` | no dequeue comment for this head, a failed read, no `Failing checks:` (conflict, review) | `fr_reentry_gate` exactly as before |

The requeue is the arm's own branch: BH-636's `requeued` mark first, the tick
budget, `mc_requeue_mergify`, and one `re-queued: …` PR line through
`fr_requeue_note`. A second ejection of the same head never reaches the gate
(`BLOCKED_HUMAN queue-ejected-twice`, shown BLOCKED_AGENT), and neither does
`MC_QUEUE_REENTRY=0`. A `stacked on #P` number is never a member. Every new
WAIT_CI reason keeps the `queue-ejected` prefix the daily digest and the
blocked-resolver read.

State, all in `state/merge-conductor/attempts.txt`: `bejsolo <slug> <base>
<check> <key>`, `bejv <key> <head> <word> …` (the verdict, read once per
head), `bejculprit <key> <head>`, `bejlog <key> <head> <word>`. Log lines:
`BATCH_EJECT_BYSTANDER`, `BATCH_EJECT_SHAREDRED`, `BATCH_EJECT_SHAREDRED_WAIT`,
`BATCH_EJECT_CULPRIT`.

## Composes with BH-4329

BH-4329 (`bin/lib/mrb-detect.sh`) keeps the main-red flag down when main's own
run at the batch base passed. This lib only READS that flag and writes nothing
the detector reads. If the flag is down while main is red, `sharedred` still
waits until main has moved off the red base before it re-queues anything.

## Known limits

- The `sharedred` ledger only sees PRs the conductor tracks. A PR tested alone
  on a red base before any sibling was gets its culprit comment one tick later.
  If siblings show up after that, it is still re-queued as `sharedred`, and
  the comment stays on the PR.
- BH-636's own requeue path still does not check the main-red freeze. Only the
  two new verdicts do.

Verified by `tests/mc-batch-eject-bystander.bh-4428-test.sh`, which drives the
real conductor on the real #4121, #3981 and #4049 payloads.
