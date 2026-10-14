# BH-4596: an approval rebound to a moved head republishes the lead-verdict status

Doc: MERGE-CONDUCTOR

## What changed

- `mc_rebind_publish <key> <project> <slug> <num> <url> <head> [reviewed]` in
  `bin/lib/mc/settle.sh`. Both rebind arms call it right after they rebind:
  `rebind_patch_id` (patch-id or `bin/lib/patch-same.sh`, BH-2310) and
  `rebind_no_overlap` (`bin/lib/mc/rebase.sh`, W2-D). On a Mergify repo, with actions
  and merges on and `mc_la_decide` rc 0, it POSTs `lead-verdict` success on the new head
  with the description `harness verdict rebound from <old12> to <new12>`. It runs once per
  (PR, head): the attempts line `vsrebind <key> <head>` records the success. Log word:
  `VS_REBIND_PUBLISHED`.
- **It carries, it never clears.** The rebind publishes only when the row is QUEUED (the
  incident shape) or the old head already carried `lead-verdict` success. On any other row,
  READY above all, it logs `lead-verdict not carried to <head8>: the row is <STATE> …` and
  POSTs nothing. A READY row may be held by the conductor itself (main-red freeze, PR
  dependency, unread-diff hold, base guard, budget), and its own `mc_enqueue_mergify`
  publishes once those gates pass. A success ahead of them would let Mergify queue the PR
  through the hold, or have `bin/pipeline-health.sh` page about a correctly held row.
- **Owed and retried.** A failed POST, an undecidable lead authority (`mc_la_decide` rc 2)
  or merges off writes `state/merge-conductor/vs-owed/<key>` (`<head>\t<reviewed>\t<url>`)
  and one log line: `VS_REBIND_OWED on <head8>: <reason> — retried next tick`, or
  `WOULD publish … owed until they are on` when merges are off (once per head, not once
  per tick for the length of the pause). `pr_worker` in
  `bin/merge-conductor.sh` calls the helper on every tick with actions on, before the rebind block, so a
  rebind is never retried in its own tick. With no owed file that is one stat and no gh
  call. The owed file is paid while its head is still the head and still approved. If the
  head moved, or the approval is no longer bound to it, the file is dropped
  (`VS_REBIND_DROPPED`). `mc_la_decide` rc 1 (protected path, revoked authority) never
  publishes. It removes the owed file and leaves the head to the NEEDS_HUMAN_VERDICT gate.
- **TTL backstop.** `stuck_rekick` has a `QUEUED` arm, `mc_vs_ttl_republish` in
  `bin/lib/mc/classify.sh`. It runs only on a Mergify repo, with an APPROVE bound to this
  head (reviewed == head, which includes the BH-3778 lead MERGE). It reads the head's state
  with the new `mc_vs_state_on` (`success|failure|error|pending|absent`, rc 2 unread):
  - `absent` or `pending`: write `vsttl <key> <head>` first, then POST success
    (`harness verdict on <head12> republished at the <STATE> TTL`). Log `VS_REPUBLISHED`.
    A failed POST is logged and not retried. The STUCK page already went out.
  - `success`: logged as present, so the hold is something else. Nothing POSTed.
  - `failure`/`error`: a lead or human BLOCK is never overwritten. Nothing POSTed.
  - unread: one log line. Nothing POSTed.
  Every other repo, and every other state, logs exactly what it did before. READY is
  deliberately left out, for the reason in the carry rule above: past its TTL it may be a
  row the conductor is holding.
  `stuck_rekick` takes optional args 13-15 (`verdict reviewed provider`). A caller that
  passes 12 gets the old answer in that arm.
- A head move that is not a rebind publishes nothing and carries nothing over. It goes to
  the detached re-review as before.

## Why

GitHub keys a commit status by sha, so a rebound head had no `lead-verdict`. A Mergify
row stays QUEUED across the push, because the labels survive it and `mc_mergify_inqueue`
reads a QUEUED row with our label as in the queue. So `mc_enqueue_mergify`, the only
conductor publisher, never ran for the new head. Mergify waited on
`check-success = "lead-verdict"` until a person posted it (#4375, #4415, #4357). The TTL
page fired, and `stuck_rekick` logged that QUEUED had no re-kick.

## Edges

- A crash between a 2xx and the `vsrebind` mark costs at most one more identical success
  POST. That is idempotent on GitHub and free.
- The TTL arm is single-shot per (PR, head). A failed republish, or a TTL tick that lands
  while merges are off (the `WOULD republish` line), is not retried for that head. The
  STUCK alert stands.
- If the row later drops to READY and `mc_enqueue_mergify` runs, it POSTs its own success,
  as it always did.
- Not covered by the rebind publish: the other `reviewed-sha` writers (`mc_rebase`'s
  own-push rebind, `train.sh`, the re-review APPROVE, `bin/blocked-resolver.sh`). Those
  rows pass through READY and `mc_enqueue_mergify`. The QUEUED TTL arm is the backstop if
  one strands in the queue.

## Where it is pinned

`tests/mc/rebind-publishes-status.bh-4596-test.sh` runs the whole conductor against a
stub gh that keeps commit statuses. Cases: R1-R8 (rebind publish, owed retry, stale owed
head, non-rebind move, merges off, native queue, overlap rebind, a READY rebind under the
main-red freeze that carries only an existing success) and T1-T6 (TTL republish on QUEUED
and none on READY, already green, lead failure, unread, no bound verdict, a READY row the
main-red freeze holds gets zero status POSTs).
