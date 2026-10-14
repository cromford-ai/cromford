# A withheld lead-verdict stops every enqueue caller, and unqueues rows labelled before the gate (BH-3806)

Doc: MERGE-CONDUCTOR, MERGIFY

## What happened

BH-3777 made the conductor ask `la_decide` before it classifies a READY
Mergify row. That left three gaps, found in the adversarial review of #3802:

- `mc_enqueue_mergify` still labelled and asked `@mergifyio queue` on rc 1 for
  its other callers: the console Merge button (`bin/poll-commands.sh`),
  `bin/rule-adopt.sh` and the `bin/batch-resolve.sh` train. A Merge-button
  press on a protected-path PR still said QUEUED.
- A PR labelled before the gate existed, with its row QUEUED, never reached
  the gate. `MC_INQUEUE` wins in `mc_classify` before the `CLEAN)` arm. #3798
  and #3799 sat QUEUED on 2026-10-01 with our label and no `lead-verdict`
  status.
- A governed READY row asked `la_decide` twice a tick, once in the gate and
  once in the enqueue. Each call costs two or more REST reads.

## What changed

- **rc 4 from `mc_enqueue_mergify`.** On `la_decide` rc 1 it publishes no
  status, adds no label, posts no `@mergifyio` comment and writes no ask
  ledger. It prints `refused: ` and then the BH-3777 reason (`mc_nhv_reason`),
  which names the protected path and
  `bin/lead-verdict.sh post <slug> <pr> <head> MERGE --source human`. The
  `la_human_needed` warn beat still goes out. rc 4 is never a strike.
  `tests/lead-authority.bh-3683-test.sh` C1 is inverted on purpose: it used
  to pin "the label and the ask still go out".
- **Every caller maps rc 4.**
  - Console Merge button: MRC 15. It acks a terminal `refused` whose result
    reads `refused: <url> needs a human lead verdict before the Mergify queue
    is asked — <reason>`. It is not retried and never says `merge failed`.
  - `bin/rule-adopt.sh`: no `enqueued-*` mark, one
    `rule-adopt-nhv-<n>-<h12>` alert (deduped by `alert_once`), and a
    `needhv=` count on the tick summary. The next tick asks again.
  - `bin/batch-resolve.sh` train: logs
    `train <url> was NOT enqueued: <refusal>`. Train state is unchanged.
  - Conductor READY arm: only a race between the gate and the enqueue reaches
    it. The budget unit goes back, `ae_mark asked` is written so the tier-2
    self-enqueue posts nothing, and the row goes to `NEEDS_HUMAN_VERDICT`
    without the `refused: ` prefix. There is no `mergefail` strike.
  - The requeue paths go through `mc_requeue_mergify`: BH-636 re-entry,
    `bin/lib/mc-stale-dequeue.sh` and `bin/lib/dequeue-watch/act.sh`. They
    get rc 4 too and already read an unknown rc in their `*)` arm as a
    refusal, never a strike. `mc_requeue_mergify` still removes Mergify's
    `dequeued` label before it asks.
- **Unqueue a row labelled before the gate.** In the conductor's `mergify)`
  in-queue arm, `mc_nhv_unqueue` (`bin/lib/mc/classify.sh`) acts when all of
  these hold: our `merge-queue` label is on, no `nhvunqueue <key> <head>`
  mark exists, `la_scope` says governed, the head's combined status has no
  `lead-verdict` in state `success` (`mc_vs_success_on`; a `failure` counts
  as absent), `la_decide` is rc 1, and merge mode is on. It then DELETEs our
  label. The mark is written only after the DELETE lands or answers 404. It
  logs `NHV_UNQUEUED <key> <head>`, and the row is `NEEDS_HUMAN_VERDICT` in
  the same tick through the BH-3777 gate.
  - An unreadable status, rc 0, rc 2 or a non-governed repo does nothing.
  - With merge mode off it logs one `WOULD unqueue` line and changes nothing.
  - A failed DELETE writes no mark and is tried again next tick.
  - A hand re-label of the same head is left alone.
  - Mergify's own `queued` label is never touched, and no
    `@mergifyio dequeue` is posted.
- **One `la_decide` per (PR, head) per tick.** `mc_la_decide` memoises the
  answer, rc 2 included, in the PR's own `pr_worker` subshell, and
  `pr_worker` clears it on entry. The unqueue, the gate and the enqueue share
  it. poll-commands, rule-adopt and batch-resolve never set the key, so each
  of them asks fresh.
- `docs/MERGE-CONDUCTOR.md` gains the `NEEDS_HUMAN_VERDICT` row in its state
  table. `worker/jobs/README.md` counts 14 `MC_STATES` words.

## What did not change

The authority rule (`bin/lib/lead-authority.sh`), `bin/lead-verdict.sh` and
`bin/lib/tier2-autoenqueue.sh` are unchanged. Nothing here posts a human
verdict.

Probe: `grep -E 'NHV_UNQUEUED|NOT enqueued' /root/harness/logs/merge-conductor.log | tail`.
Proven by `tests/mc/nhv-other-callers.bh-3806-test.sh`,
`tests/mc/nhv-already-labelled.bh-3806-test.sh`,
`tests/mc/la-decide-once.bh-3806-test.sh`, O3 in
`tests/rule-adopt.bh-3715-test.sh`, O4 in `tests/batch-resolve-test.sh` and
C1 in `tests/lead-authority.bh-3683-test.sh`.
