# BH-5526: a runaway spend ceiling per lane, seeded from p99, refusing only at a ticket boundary (slice C3)

Doc: COST

**Why.** The ticket asks for one hard ceiling per lane at about 3x its p99
daily spend, stored as a DB settings row and seeded from the measured p99. It
must catch a loop and never fire on a normal busy day. It must never stop a
ticket midway: over the ceiling, no NEW ticket, build or review starts on the
lane, and work already started finishes.

**What changed.**

- The settings row `spend.ceiling.<lane>.day_usd` is the ceiling: dollars the
  lane may spend in the UTC day, every stage and every project. A value > 0
  arms it. `off`, `0`, junk or no row is no ceiling. The longest key is 46
  characters, under the worker's 64.
- `llm_gate_precall` in `bin/lib/llm-gate.sh` checks it. The spend is
  `GET /api/metrics/llm-spend?lane=<lane>` with no stage (rows stamped
  `lane_id=<lane>`, the same unit as the C2 p99 table). No row makes no read.
  `spent >= ceiling` refuses with
  `spend-ceiling lane=<l> spent=$X ceiling=$Y key=spend.ceiling.<l>.day_usd`.
- The check runs AFTER the `LLM_GATE_IN_TICKET` return. So:
  - a fly-pool call inside an admitted build with no `RESULT` is never refused
    by it (plan, execute, review, fix and qa all run);
  - the build launch gate (`# >>> budget launch gate`, `bin/lib/rb/gates.sh`)
    refuses a fresh build with `RESULT BUILD_DEFERRED spend-ceiling lane=fly-pool …`
    and no `ADMITTED`; a resume of an admitted dir is not checked;
  - any other call (a review lane, triage, postmerge-qa, replan-check on an
    ended build) is its own start and `bin/agent-call.sh` refuses it with rc 74,
    `AGENT_CALL_REFUSED llm-gate spend-ceiling …` and a $0 `refused` cost row.
- One alert per (lane, UTC day, box): `[spend-ceiling] lane <l> spent=$X ceiling=$Y …`,
  id `spend-ceiling:<lane>:<YYYYMMDD>`, claim file
  `flags/alerted-spend-ceiling-<lane>-<YYYYMMDD>`. The launch gate does not add
  its per-project `llm-cap-launch` alert for this reason.
- `pool_lane_failure` in `bin/fly-pool.sh` reads ` spend-ceiling ` as the
  lane's condition, so the pool does not count it against the ticket.
- New `bin/spend-ceiling-seed.sh` and a new `# >>> spend ceiling seed` block in
  `bin/pipeline-health.sh`, right after `# <<< spend alerts`. Once per UTC day
  it reads `state/spend-alerts/baseline-<YYYYMMDD>.tsv` and writes a row for
  each lane with `SPEND_CEILING_MIN_DAYS` (7) or more days and p99 > 0, at
  `SPEND_CEILING_P99_MULT` (3) x p99 rounded up to the cent, actor
  `spend-ceiling-seed`. Only registry lane ids and `stage-<s>` ids get a row;
  a stage-fallback key such as `execute` does not.
- Insert-if-absent: a row that exists, with any value and any actor, is never
  rewritten. A seeded row stays until a person changes it.
- The marker `state/spend-alerts/ceiling-seeded-<YYYYMMDD>` is written only on
  seeder rc 0. A partial failure raises one `spendceilingseed:fleet` alert a
  day and retries next tick; rows already written are kept.
- Knobs on the `pipeline-health` lane: `SPEND_CEILING_SEED` (1),
  `SPEND_CEILING_P99_MULT` (3), `SPEND_CEILING_MIN_DAYS` (7; the block reads a
  value under 7 as 7).

**Fail open.** A junk row, no settings cache, no jobs client or an unreadable
spend ALLOWS the call and writes one throttled `logs/lane-gate.log` line.

**How to raise or lift a ceiling.**

1. Raise: `bin/jobs-client.sh setting-set spend.ceiling.<lane>.day_usd <usd>`.
2. Lift for one lane: write the value `off`. The seeder keeps it.
3. Lift for the fleet: turn on the switch `spend-ceiling-off`
   (`switch.spend-ceiling-off` row, or `flags/spend-ceiling-off` on a box).
4. Preview the seed on the hub:
   `bin/spend-ceiling-seed.sh --dry-run --baseline state/spend-alerts/baseline-$(date -u +%Y%m%d).tsv --mult 3 --min-days 7 --registry catalog/lanes.json`
   prints `would-seed` lines and writes nothing.

**What did not change.** `LLM_USD_CAP_DAY` and its in-ticket rule (C0), the
budget-stop caps, the cost autohalt's spend hold (C1) and the C2 spend alerts.
A value of 0 is no ceiling here; the lane kill switch is still
`LLM_LANE_ENABLED=0`.

**Not in this slice.** The Mission Control view (C4) and the project-2
unpriced calls (C5).

**Tests.** `tests/spend-ceiling.bh-5526-test.sh`.
