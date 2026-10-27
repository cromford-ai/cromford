# BH-8592: a fix round that changes no file pushes nothing, and the innocent PR goes back in the queue on the same head

Doc: MERGE-CONDUCTOR, MERGIFY

## Cause

On 2026-10-27 two fix rounds found that a merge-queue ejection was a batch
sibling's fault. Each agent committed `--allow-empty` with a "no change"
message: `7fcdde11` on #8128 and `73aadc64` on #8550. `br_fix_round` tested
only `HEAD = lease` before the push. An empty commit makes HEAD differ from the
lease, so the round pushed it. The head moved, Mergify dequeued #8550 from
batch #8588 (`PULL_REQUEST_UPDATED`), and the batch merged nothing.

## Fix

The code is `bin/blocked-resolver.d/bh-8592-fixround-nochange.sh`. The driver
has four call sites, each `command -v` guarded.
`BR_OPT_OFF=bh-8592-fixround-nochange` turns all of it off.

1. `br_fix_round`, before the "no verified commit" test: `brnc_nochange` reads
   the round's own commits (HEAD minus the PR head, `origin/main` and a stacked
   child's base; merges dropped). It runs only when the agent rc and the verify
   rc are both 0.

   | own files | conflict resolved | tree vs PR head | park | result |
   |---|---|---|---|---|
   | 0 | no | same | any | no change |
   | 0 | no | differs (clean main merge) | `queue-ejected-twice` | no change |
   | 0 | no | differs | any other | pushed, as before |
   | 1 or more | any | any | any | pushed, as before |
   | any | yes | any | any | pushed, as before |

   - On `queue-ejected-twice`, a no-change round is recorded
     `fix-round-nochange` (`fixrounds` + 1). The PR gets ONE comment per head
     with the round's commit messages. Nothing is pushed. The worktree and
     `brfix/<ck>` are dropped. The result to the hub stays `done`.
   - On any other park, a no-change round takes the existing "no verified
     commit" exit. Its detail ends `tree unchanged (N empty commit(s)), not
     pushed`, and the commit messages are posted once per head.
2. `br_fix_round`, right before `hold_push`: `brnc_queued_guard` reads
   `mc_queue_state`. On `queued` the round is NOT pushed. It is recorded
   `fix-round-queued` (`fixrounds` + 1) and `brfix/<ck>` is kept for a later
   round. `merged`, `ejected` and `unknown` push as before; `unknown` writes
   one log line.
3. The requeue, `brnc_settle`, runs on the hub only (no `BR_FIX_HERE`, no
   `LANE_RUN_ID`). It is called from `br_fix_adopt` (`done`), from
   `brnc_round` when the round ran on the hub, and from `br_one` before the
   ladder rung of a `queue-ejected-twice` park. The `br_one` call retries a
   settle that could not read GitHub. Without it the round's `fixrounds` bump
   would send the park to rebuild-fresh. The gates, in order:
   - the knob `BR_NOCHANGE_REQUEUE` (0 = declined);
   - the head is already in `nochange_requeued_heads` (answer `queued`, 0 posts);
   - the repo queues on Mergify;
   - the live head equals the no-change head (unreadable = retried next tick);
   - no `dqwculprit` mark on the head;
   - the conductor row's reviewed sha is the head;
   - `mc_queue_state`: `queued` sets the row QUEUED with 0 requeues,
     `merged` declines, `unknown` is retried.

   Then the marks are written BEFORE the post (BH-636): the head goes in
   `nochange_requeued_heads`, MC_ATTEMPTS gets `requeued <key> <head>`, and
   this head's `reejected` line is cleared once. If Mergify ejects the head
   again, the conductor writes `reejected` again and parks it
   `queue-ejected-twice` as before. Then `mc_requeue_mergify`: rc 0 or 2 sets
   the row QUEUED; rc 3 sets WAIT_CI "awaiting Mergify's witness"; any other rc
   is declined and keeps the mark, so there is no second post. A declined head
   goes in `nochange_declined_heads`, and the ladder takes the park on its next
   rung.

The culprit gate reads `dqwculprit` only, not `mc_ejected_hold`.
`mc_ejected_hold` is also true on a `reejected` mark, which every
`queue-ejected-twice` head carries.

## Knobs

- `BR_NOCHANGE_REQUEUE` (default 1; 0 = record and comment, no requeue).
- `BR_NOCHANGE_NOTE_BYTES` (default 3000, 200..20000): bytes of the commit
  messages in the PR comment.

## Limits

On a Fly lane machine (`LANE_RUN_ID` set) the requeue is not asked. That
machine does not write back the conductor's rows or `attempts.txt`. If the
resolver lane is placed `fly`, a no-change head is recorded and noted but not
requeued, and the park takes its ladder rung.

## Test

`tests/fixround-nochange.bh-8592-test.sh` runs the real driver through
`--fix-here` over a real bare origin, the real `br_fix_adopt` and the `br_one`
block (extracted verbatim). It checks 0 pushes and 1 requeue on the incident's
shape, and 0 requeues when Mergify already holds the PR.
