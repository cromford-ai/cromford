# A fix-main-red head skips the pre-queue verdict; a carried green names both mains; the gate-off path falls back on an untested head (BH-8769, absorbs BH-8801)

Doc: MERGE-CONDUCTOR

## What changed

1. **The hotfix skip.** `pq_gate` (`bin/lib/mc-prequeue.sh`) asks a new hook,
   `pq_hotfix_skip` (`bin/lib/mc-prequeue.d/hotfix-skip.sh`), first. It
   answers yes when all four are true:
   - `MC_MAIN_RED_LABEL` is set (default `fix-main-red`, the existing knob);
   - the repo's queue provider is `mergify`;
   - `ec_requeue_gate` is not in the call stack (the eject requeue never skips);
   - the READY row's labels (`RAWLBL`, which `pr_worker` holds in its dynamic
     scope) hold that label, csv-exact and case-sensitive (the
     `main_red_exempt` match). `fix-main-red-2`, `Fix-Main-Red` and `hotfix`
     do not skip.

   On yes, the gate takes the BH-8062 gate-off path in both gate modes. There
   is no cache read, no `pq_resolve`, no `prequeue-gate.yml` dispatch, no
   group join and no BH-8801 fallback. `pq_restamp`, `pq_mignum` and
   `pq_fastlint` still run when they can act, and their hold or red still
   wins. The proceed publishes `prequeue-verdict` success with the text
   `skipped (fix-main-red: the hotfix queue runs this head alone)`. The
   conductor writes one `PREQUEUE_SKIPPED head=<12> reason=...` line per
   (PR, head). The attempt line `pqskip <slug>#<num> <head>` dedupes it.

   Why: the Mergify hotfix queue runs a fix-main-red PR alone in a batch of 1
   on main. That run is the test. The skip has no knob, by the ticket.

2. **The carried status text.** When the BH-6924 impact reuse
   (`pq_impact_reuse`) carries a green or no-selection verdict from main A to
   main B, it writes a `.reuse` sidecar next to the entry. `pq_status_gate`
   now reads it and publishes `green on main <A12>, carried to main <B12>`.
   The attempt key is `pqst <slug> <head> success carry <B>`, so a head that
   got success on main A posts once more for main B. A missing or malformed
   sidecar keeps the old text `green on main <B12>`.

3. **The carry knob.** Row `lane.merge-conductor.mc_prequeue_carry` (fragment
   `catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_CARRY.json`, default
   1, code fallback 1 in `PQ_KNOB_DEFAULTS`). At 0, `pq_resolve`
   (`bin/lib/mc-prequeue.d/dispatch.sh`) does not ask `pq_impact_reuse`, and
   the gate is dispatched again. `MC_PREQUEUE_IMPACT_REUSE=0` and
   `MC_PREQUEUE_REUSE=0` still turn the carry off too. Off always wins.

4. **The gate-off fallback (BH-8801).** With `MC_PREQUEUE_GATE=0` and
   `MC_PREQUEUE_FALLBACK` not 0, and no hotfix skip, `pq_gate` reads the PR
   body once (`_pq_gate_record`, call `gate-record` under the call budget) and
   finds the selection-gate marker for this head with `LR_GR_RE`
   (`bin/lib/lead-review/gate-record.sh`, not changed).
   - `rc=0`, `no-selection`, `off`: the gate-off path as before.
   - `rc=could-not-run`, or no marker for this head: one
     `PREQUEUE_FALLBACK <slug#num> <head> gate-record=<could-not-run|missing>`
     line, then the gate-on path (cache read, `pq_resolve`, dispatch, group).
     A `could-not-run` marker for the head wins over another marker for it.
   - Body unread: one `PREQUEUE_FALLBACK_UNREAD <slug#num> <head>` line and
     the gate-off path as before (#8801: "No other behavior of the gate-off
     path changes").
   Knob row `lane.merge-conductor.mc_prequeue_fallback` (fragment
   `MC_PREQUEUE_FALLBACK.json`, default 1, code fallback 1).

## Rollback

- Carry: set `lane.merge-conductor.mc_prequeue_carry` to `0`.
- Fallback: set `lane.merge-conductor.mc_prequeue_fallback` to `0`.
- Skip: there is no row. Revert the PR.

## Why N6 stays green (the r4 red)

r4 put the carry check at the top of `pq_impact_reuse`.
`tests/merge-conductor-prequeue-nonblocking-test.sh` N6 sources the real
`impact-reuse.sh` and stubs `pq_knob` with `*) echo 0`, so the stub turned the
carry off and N6 read `ir=none`. This change reads the knob in the caller
(`pq_resolve`) and does not edit `impact-reuse.sh`.

## Why bin/merge-conductor.sh is not edited

The skip reads `RAWLBL` by dynamic scope, as `bin/lib/mc-stale-dequeue.sh`
and `bin/lib/mc/rebase.sh` already do. So this change and #8781 touch no
common file and can land in any order.

## Suites whose premise changed

The suites below run the conductor with `MC_PREQUEUE_GATE=0` to keep the
pre-queue gate out of the way, or pin the exact gate-off path. With the
fallback on (default 1) the gate reads the PR body there. Each one gets
`MC_PREQUEUE_FALLBACK=0` (or the row at 0) beside `MC_PREQUEUE_GATE=0`. No
assertion is removed or softened.
`tests/prequeue-gate-row.bh-8062-test.sh`,
`tests/mc/prequeue-isolation.bh-4545-test.sh`,
`tests/mc/prequeue-verdict-status.bh-5429-test.sh`,
`tests/conductor-worker-steps.bh-6346-test.sh`,
`tests/mc-step-timeout.bh-6351-test.sh`,
`tests/merge-path-stall.bh-4918-test.sh`,
`tests/prequeue-call-bound.bh-7029-test.sh`.
