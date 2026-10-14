# The pre-queue isolation gate, tracer slice (BH-4545 / BH-4547)

Doc: MERGE-CONDUCTOR

## What changed

The merge conductor now asks `pq_gate` (`bin/lib/mc-prequeue.sh`) before it
marks a READY head ready or enqueues it. It asks only on a tick that can
enqueue (merges on), only on a repo with a merge queue, and never for a row
that is already QUEUED. The call sits after the ticket-hold check and before
`ae_mark`, the merges-off return and the merge budget. So a hold or a park
spends no merge unit, and the tier-2 self-enqueue never sees the head.

The gate reads the base branch's tip over REST, then one verdict file:

    state/merge-conductor/prequeue/<owner_repo>_<num>_<head>_<main>[_<fp>]
    <state> <dispatched_at> <run_id|-> [alerted] <suites, comma-joined>

- `red` naming at least one suite: the row parks `BLOCKED_HUMAN` with reason
  `prequeue-red: <suites> on main <m12> — the head merged onto current main
  fails them`. It reads BLOCKED_AGENT, because `prequeue-red` is in
  `mc_resolver_owns`. It is also in `mc_handoff_owns`, so the park is sticky:
  the row isn't re-classified READY every tick, and it clears when the head
  moves, the PR closes or the resolver releases it. The tick logs one
  `PREQUEUE_RED` line per (PR, head, main). It writes no label, no comment and
  no `@mergifyio`.
- `green`, `no-selection`, `conflict`, `could-not-run`, any unknown word, or a
  `red` that names no suite: proceed, as before.
- No file or `pending`: a `pq_resolve` hook decides if one is loaded. If none
  is loaded, the gate proceeds.
- Main tip unreadable (any REST failure, a quota refusal included): the row
  stays READY with ready-why `prequeue-pending` "main tip unreadable, asked
  next tick". No alert is sent.

Nothing in this slice writes a verdict. Production behaviour is unchanged
except for one REST GET of the base-branch commit per READY row per merging
tick. That changes once a sibling drops a `pq_resolve` hook into
`bin/lib/mc-prequeue.d/`.

## Knobs

`MC_PREQUEUE_GATE` (0 turns the gate off) is read here. `MC_PREQUEUE_FRESH_S`,
`MC_PREQUEUE_DEADLINE_S`, `MC_BATCH_SOLO` and `MC_BATCH_SOLO_MAX_MEMBERS` are
registered now and read by the sibling hooks through `pq_knob`. Each is a
`lane.merge-conductor[.<project>].<name>` settings row.

## Still owed by siblings

- The resolver has no class for `prequeue-red` until #4549. Until then a park
  gets `br_action none` from the resolver and pages at the BLOCKED_HUMAN TTL.
- Nothing produces verdicts until #4548.
