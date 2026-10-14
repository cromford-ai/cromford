# The pre-queue gate reuses a fresh verdict when main moves (BH-5572)

Doc: MERGE-CONDUCTOR

## What changed

The gate in `bin/lib/mc-prequeue.d/dispatch.sh` already used a verdict on the
same (PR, head) for an older main tip, inside `MC_PREQUEUE_FRESH_S`. It aged
that verdict from its DISPATCH time. A run is read back one or two ticks after
its dispatch, and a tick takes 12-19 min. So a green verdict was often stale
the moment the conductor read it, and each main move dispatched
`prequeue-gate.yml` again. On 2026-10-08 #4034 was dispatched at 14:29, 15:11
and 15:46Z and never enqueued.

With `MC_PREQUEUE_REUSE=1` (the default), on a miss for the current main:

- A finished verdict ages from when the conductor recorded it: the mtime of
  its file in `state/merge-conductor/prequeue/`. `pq_settle` writes a finished
  entry once. A pending run still ages from its dispatch.
- The newest verdict inside `MC_PREQUEUE_FRESH_S` decides. A red that names a
  suite parks the row `prequeue-red`, as before.
- Any other verdict counts only if the head still merges into main.
  `pq_merge_test` runs `mc_merge_tree` (one bounded git fetch, then a local
  `git merge-tree`) under the project's git lock. Clean: proceed, no
  dispatch. Conflict: the gate answers `rebase` and the row goes to
  `NEEDS_REBASE` with reason `prequeue reuse: head <h8> conflicts with main
  <m12>: <paths>`. No answer (`MC_MERGE_TREE=0`, old git, fetch failed, lock
  busy): the dispatch-time rule decides, as before.
- Before a dispatch, `pq_dispatch_veto` asks whether the conductor will refuse
  this head later in the same tick: a standing BLOCK (`bg_scan_read`, only
  while `BLOCK_GATE_ENFORCE=1`), or a lead PR with no lead MERGE row
  (`to_lead_merge_hold`). If so, nothing is dispatched or written, and the
  gate answers `defer`. The READY arm goes on, so the lead fence or the block
  gate refuses the head as before (refusal comment, CI-block hook, Mergify
  dequeue). If neither refuses it, the new `# >>> prequeue defer` block holds
  the row READY with ready-why `prequeue-pending` and the next tick
  dispatches. A `defer` head gets no `ae_mark ready`. A read that fails is no
  veto. Held, stacked and dependency-held rows stop before the gate is asked.

`MC_PREQUEUE_REUSE=0` restores the earlier gate: dispatch-time ages, no merge
test, no veto, no new log lines.

## Log lines (`logs/merge-conductor.log`)

    PREQUEUE reuse #<n> head=<h12> verdict-main=<m12> current-main=<m12> age=<N>s verdict=<word> -> <proceed|red|rebase|merge-test-unanswered (<why>)>
    PREQUEUE skip-dispatch #<n> head=<h12> current-main=<m12> reason=<standing BLOCK on the thread|lead PR waiting on a lead MERGE row>

## Knob

`MC_PREQUEUE_REUSE` (int flag, default 1) in
`catalog/lanes.d/merge-conductor.json`. Per project:
`lane.merge-conductor.<project>.mc_prequeue_reuse`.

## Tests

`tests/prequeue-reuse.bh-5572-test.sh` runs whole conductor ticks against a
local git origin (R1-R9). `tests/mc/prequeue-dispatch.bh-4548-test.sh` L5a/L5b
now pin the dispatch-time rule under `MC_PREQUEUE_REUSE=0`.
