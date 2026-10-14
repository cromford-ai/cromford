# The pre-queue gate runs on the CI pool (BH-4548, #4545 child 2)

Doc: MERGE-CONDUCTOR

## What changed

The tracer's `pq_resolve` hook now exists: `bin/lib/mc-prequeue.d/dispatch.sh`,
sourced by `bin/lib/mc-prequeue.sh`. On a cache miss for (PR, head, main tip)
the conductor dispatches `.github/workflows/prequeue-gate.yml` on the repo and
holds the row READY (`ready-why prequeue-pending`). The run merges the head
onto that main tip and runs `bin/test-impact-gate.sh` on the bh-ci pool,
bounded by the builder gate's own cap and budget knob rows. With the `suites`
input it runs each named suite through `bin/test-suite-run.sh` instead. It
prints one annotation:

    ::notice title=prequeue-verdict::<green|red|no-selection|conflict|could-not-run> main=<sha> head=<sha> suites=<comma list>[ why=<token>]

A later tick finds the run by its exact title (`prequeue pr=<n> head=<sha>
main=<sha>`) and records the verdict in the cache file. `red` parks the row
`prequeue-red: <suites>`. Every other verdict enqueues.

- Before paying for a new run on a miss, the hook settles this head's other
  pending entries. Then it acts on the head's newest completed verdict from
  the last `MC_PREQUEUE_FRESH_S` seconds, whatever main it ran on. A pending
  run inside that window holds the row without a new dispatch.
- A repo without the workflow proceeds with no alert. Every fleet repo except
  cromford lands here, at the cost of one probe per repo per tick.
- `pending` is written before `gh workflow run`, under `flock -n
  locks/prequeue-<slug_>-<num>-<head>.lock`.
- Entries older than 7 days are pruned, at most once per tick.

`bin/test-impact-gate.sh --failed <file>` is new. It writes the suites whose
rc was non-zero, one per line, and is empty on green. Exit codes and stdout are
unchanged.

## could-not-run

A refused dispatch, a run that did not conclude `success`, zero or several
verdict annotations, a malformed one, one naming another head or main, a red
naming no suite, or no run after `MC_PREQUEUE_DEADLINE_S`: each of these is
recorded `could-not-run ... alerted` in one write. Then
`bin/lane-alert.sh --severity warn merge-conductor` fires once:

    <slug>#<num> prequeue gate could-not-run on head <h12> main <m12> (<why>): enqueued without it, the batch is the backstop: <url>

The PR is enqueued anyway. If the why is `dispatch-refused` on every PR, the
GitHub App token the conductor uses probably lacks `actions: write` on the
repo. Grant it, or set `MC_PREQUEUE_GATE=0` for the project to stop the gate.

## Why the workflow name says "smoke"

These runs sit on branch `main`. `bin/main-red-detector.sh` reads every run on
main except names matching `MAIN_RED_SKIP_RE`, default
`(e2e|nightly|smoke|publish|deploy)`. A prequeue run always concludes
`success` once it has printed a verdict, so the detector would read it as
"main is green" and could lift a real queue freeze. The name `Pre-queue smoke
gate (BH-4545)` keeps it skipped. A settings row that drops `smoke` from that
regex brings the problem back.
