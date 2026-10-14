# A failed batch is re-run one member at a time (BH-4550, #4545 child 4)

Doc: MERGE-CONDUCTOR

## What changed

When Mergify ejects a PR from a failed multi-PR batch draft, the BH-636
re-entry arm's gate (`bej_reentry_gate`) now asks `bs_batch` first
(`bin/lib/mc-prequeue.d/batch-solo.sh`, sourced by the tracer's hook loop).
`bs_batch` reads the draft once: its members and base from the title, the base
as 40 hex, and the failing suites S from the draft's failed
`mergify/merge-queue/*` runs through `flaky_run_tests_strict`. It then
dispatches `prequeue-gate.yml` with `suites=S` for each member's head on that
base, and reads each run's verdict back on a later tick.

For the PR being asked about:

- `reproduces`: its solo run is red on S, every member has a verdict, and at
  least one member is clean. The row is parked `BLOCKED_HUMAN` (shown as
  BLOCKED_AGENT) with reason
  `prequeue-red: <S> (reproduced alone on <base12>, batch #<draft>)`, a sticky
  resolver hand-off. Under the main-red freeze it is not parked; #4428 decides.
- `clean`: its solo run is green. It is re-queued once per head through the
  arm's existing `requeued` branch, with the freeze and green-head guards a
  bystander has.
- `pending`, `could-not-run`, or no solo run at all: #4428's rule decides,
  unchanged. A bystander is still re-queued on its first tick.

No solo run when `MC_BATCH_SOLO=0`, the repo has no `prequeue-gate.yml`, merge
mode is off (nothing is dispatched), the draft is stacked or held one PR, it
held more than `MC_BATCH_SOLO_MAX_MEMBERS` PRs (one `BATCH_SOLO_SKIP` line), a
failed run's log could not be read in full, or a failing name is not a
`tests/(mc/)?X.sh` path (a `job:` name or a test title).

## Why

#4428 decides from what Mergify's dequeue comment says. Running the batch's
own failing suites against each member alone, on the batch's own base, tests
the question directly instead of reading it off a comment. The witness rule exists because on 2026-10-04 main itself was red:
every solo run would have been red, and parking all of them would have been
the #4428 incident again.

## State and knobs

- Member verdicts use the tracer's store with a suites fingerprint suffix,
  `prequeue/<owner_repo>_<num>_<head>_<base40>_<fp12>` (fp = first 12 hex of
  the sha1 of S, one per line). `pq_dispatch` took an optional sixth argument
  for it, so a solo run never lands on the plain gate's key.
- Draft facts: `prequeue/batchsolo_<owner_repo>_<draft>`, `ok <base40> <S,>
  <members>` or `skip <reason>`. A failed read is not cached.
- `bin/merge-conductor.sh`'s re-entry arm now takes the row's state from
  `FR_STATE` when the gate sets one (only this park does); everything else is
  `WAIT_CI` as before.
- Knobs `MC_BATCH_SOLO` (1) and `MC_BATCH_SOLO_MAX_MEMBERS` (13) were
  registered by the tracer.
