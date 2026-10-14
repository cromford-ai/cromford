# A batch that failed only on a no-verdict shard re-queues its PR once (BH-6336)

Doc: MERGE-CONDUCTOR, MERGIFY

## What happened

- 2026-10-12 22:06Z: batch draft #6316 held PR #5443 alone. The job `Tests, traced (shard 5/8)`
  was cancelled. `bin/ci-verdicts.sh` printed "shard 5/8 left no verdict", so
  `Tests cannot touch a real harness` and `Pure-logic gate fixtures` went red. The other 13
  checks passed. Mergify ejected #5443.
- The BH-636 re-entry arm called the single-PR draft `solo` (BH-4428). `fr_reentry_gate` could
  not attribute a job-named failure, so the verdict was `unknown`, and `unknown` on Mergify's
  UNSTABLE head never re-queues. The PR waited until a person re-queued it by hand. On the next
  tick the BH-4428 rule posted a culprit comment ("Mergify tested this PR alone … and it failed")
  on a PR that did nothing wrong. The new suite's red run on main shows both.

## What changed

1. **A new classifier.** `bin/lib/mc-noverdict.sh` (new, sourced by
   `bin/lib/mc-batch-eject.sh`). For the newest Mergify dequeue bound to the head, it reads each
   failing batch run: its jobs page and its `--log-failed` text (bounded by `FLAKY_LOG_MAX`).
   A run is `noverdict` only when:
   - every failed job that is not `Tests, traced (shard i/N)` (a fan-in) prints at least one
     error line, and each error line, except "Process completed with exit code N.", is a
     `bin/ci-verdicts.sh` "shard i/N left no verdict" line; and
   - every failed `Tests, traced (shard i/N)` job is a shard that such a line names.
   Anything else is `real`: a failed test, a trace hit, a failed plan job, "ran 0 tests", a
   failed lint job, a fan-in with no error line. A run whose jobs or log cannot be read in full
   is unread, and one unread run makes the whole batch unread.
2. **The re-entry gate asks it first.** `bej_reentry_gate` calls `nv_gate` after its
   merge-state check and before `bej_verdict`:
   - every run `noverdict`, the main-red freeze down, the head's own checks green: rc 0. The
     arm's existing tail does the requeue (the `requeued` mark, merge mode, the BH-6161
     pre-queue gate, the tick budget, `mc_requeue_mergify`). `fr_requeue_note` posts the PR
     line "re-queued: Mergify's batch draft #D failed only because CI shard(s) k/N left no
     verdict … That is an infra retry, not a failure of this PR. This head gets one retry."
     Nothing goes to the flake ledger. No `bejv` line is written, so no culprit mark and no
     fix round follow.
   - `noverdict` under the freeze, or on a head that is not green: the row waits.
   - a failing run's jobs or log cannot be read: the row waits with "whether batch draft #D
     left no verdict could not be read this tick". The third unread tick on a head hands it to
     the BH-4428 rule.
   - nothing here can classify it (the dequeue comments cannot be read, a failing check is not
     an Actions run, or the readers are not loaded): the BH-4428 rule decides at once.
   - `real`, or no failing runs: the BH-4428 rule decides, unchanged.
   The arm's other checks still run around it. A human `@mergifyio dequeue` after the head still
   makes it the culprit (BH-5819), and `MERGES=0` only logs "would REQUEUE".
3. **One retry per head.** The cap is the arm's existing `requeued` mark: a re-queued head never
   reaches the gate again, and its second ejection is `queue-ejected-twice` as before.
4. **A second no-verdict ejection pages once.** `mc_eject_fix_now` (`bin/lib/mc/queue.sh`) first
   calls `nv_twice_note`. For a head this lib re-queued, it classifies the NEWEST dequeue:
   - `noverdict`: it writes `nvtwice` and then sends ONE critical alert, "<url> left no verdict
     twice on <head12> (batch drafts #D1, #D2; shard(s) k/N). A CI runner is failing. This is an
     infra incident, not this PR."
   - `real`, or no failing runs: it writes `nvtwice` and sends no alert.
   - unread, or Mergify's first comment is still the newest: nothing is written and the next
     tick asks again. The third such tick writes `nvtwice` and sends the alert with "could not be
     confirmed" wording.
   The fix round itself is unchanged: the resolver ladder (BH-6000) still runs after the alert.

## State and log lines

All in the conductor's `MC_ATTEMPTS` file:

- `nvv <key> <head> <comment id> <word> <draft> <run ids,> <shards,>`: the verdict per (head,
  dequeue comment). The gate reads the first one for a head and does no read after that.
- `nvunread <key> <head>`: one per unread gate tick (at most 2).
- `nvtwice <key> <head>`: the second-strike answer, written before the alert.
- `nvtwiceunread <key> <head>`: one per unread second-strike tick (at most 2).
- Log lines, once per head through `_bej_log_once` (`bejlog <key> <head> <WORD>`):
  `NOVERDICT_RETRY`, `NOVERDICT_UNREAD`, `NOVERDICT_TWICE`.

## Switches

No new knob. `MC_QUEUE_REENTRY=0` turns off the whole re-entry arm, this branch included.

## Decided, not asked

- The ticket allows "re-run the failed shard once, or requeue the PR". This change re-queues the
  PR. Mergify already ejected it, so a re-run of the closed draft decides nothing.
- A second no-verdict ejection keeps the BH-6000 fix round and adds one alert. The ticket names
  only "ejects and alerts". Skipping the fix round for that head would change the resolver
  ladder.

## Tests

`tests/mq-no-verdict-retry.bh-6336-test.sh`: the classifier's decision table (T1-T15) over
fan-in logs written by the real `bin/ci-verdicts.sh`, and N1-N8 through the real
`bin/merge-conductor.sh`.
