# Pre-plan readiness and cadence: the contract (BH-2543 slice 1, BH-2569)

Doc: EVENTS

## What changed

- **Two new stub libs.** `bin/lib/preplan-ready.sh` defines `preplan_ready_on`
  (reads `PREPLAN_READY_ONLY` through `lane_knob preplan-tick`, default 1) and
  `preplan_not_ready` (stub: rc 1, ready, prints nothing).
  `bin/lib/preplan-cadence.sh` defines `preplan_adopt_stats` (stub: rc 1,
  unknown, prints nothing), `preplan_cadence_cut` (stub: rc 1, not cut) and
  `preplan_cadence_allow` (stub: rc 0, allow).
- **Two call sites in the speculative loop of `bin/preplan-tick.sh`.** Both
  libs are sourced fail-open (`[ -r ... ] && . ...`), next to `preplan-lib.sh`.
  - `# >>> preplan readiness (BH-2543)` sits right after the small skip. When
    `preplan_not_ready` answers rc 0 with a reason, the tick logs
    `PREPLAN_SKIP small: not-ready: <reason>` once per (key, reason) through
    `preplan_small_log` and skips the key. It also needs `preplan_small_log`
    to be defined, so a box with the new lib and an old `preplan-lib.sh`
    launches the key instead of skipping it with no line.
  - `# >>> preplan cadence (BH-2543)` sits right before the `pre-plan launch`
    line: `preplan_cadence_allow "$HARNESS" "$P" "$WHY" || continue`, behind a
    `type` guard, so a missing function means allow.
  - Both only `continue`. Neither spends a `PREPLAN_PARALLEL` slot. The legacy
    (non-speculative) path is untouched.
- **Six knobs on the `preplan-tick` lane** (`catalog/lanes.d/preplan-tick.json`):
  `PREPLAN_READY_ONLY` (0-1, default 1), `PREPLAN_ADOPT_FLOOR_PCT` (0-100,
  default 50), `PREPLAN_ADOPT_MIN_SAMPLES` (1-1000, default 10),
  `PREPLAN_ADOPT_WINDOW_DAYS` (1-30, default 7), `PREPLAN_CUT_INTERVAL_S`
  (60-86400, default 1800), `PREPLAN_ADOPT_CACHE_S` (0-3600, default 900).

Nothing behaves differently yet. Every stub returns the answer the tick had
before the gates existed, so every candidate still launches.

## The route the siblings share

Documented here and in the header of `bin/lib/preplan-cadence.sh`. Not built in
this slice; the worker child builds it, the cadence and console children read it.

    GET /api/preplans/adoption?project=<p>&days=<1-30>
    -> {window_days, since,
        projects:[{project, adopted, stale, miss, off, bought, rate}],
        days:[{project, day, adopted, stale, miss, off, rate}],
        recent:[{job_id, ticket_id, project, verdict, detail, created_at}],
        recent_truncated, as_of}

- `bought = adopted + stale`. `rate = adopted/bought`, null when bought = 0,
  never 0.
- `days` outside 1-30 or non-integer is a 400.
- `recent` is capped at 50; `recent_truncated` says whether it was.
- It reads `stage_events` rows with `stage='preplan'` and verdict
  `ADOPTED|STALE|MISS|OFF`.

## For the cadence child

The cadence gate is asked AFTER the stale re-plan block. When it starts
denying, a stale plan will already have been dropped (`rm -rf`) and its
`preplan_replan_allow` stamp spent before the deny. The stub never denies, so
this changes nothing today, but the child should decide whether to ask earlier.

Proved by `tests/preplan-gates-contract.bh-2543-test.sh`.
