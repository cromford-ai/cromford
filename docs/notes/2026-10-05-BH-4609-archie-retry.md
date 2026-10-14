# Archie checks: a usable dollar cap, budget stops retry within the hour, unreadable metrics re-check daily (BH-4609)

Doc: OPERATOR-SETUP, MODEL-ROUTES

## Why

Archie's first live checks on 2026-10-05 hit three self-caused failures:

- **I2** stopped on `ARCHIE_LLM_MAX_USD=0.10`. An Opus first turn through the
  claude CLI costs more than that, so every check was a BUDGET STOP. The hub
  settings row `lane.archie.archie_llm_max_usd=0.60` fixed it there. The
  stopped attempt still counted toward `ARCHIE_MAX_ATTEMPTS`, so two stops
  skipped a whole cadence (a week for I2). And the ALERTS line said `cost $?`.
- **I1**'s metric was unreadable (the rework rollup had no `cromford` row
  yet), and an unreadable check advanced a full cadence: one look a week.
- That rollup row was missing because the Monday rework scan reads repos in
  fleet-conf order and hit `REWORK_FETCH_CAP` before it reached cromford.

## What changed

**The default.** `ARCHIE_LLM_MAX_USD` defaults to 0.60 in
`catalog/lanes.d/archie.json` and in `bin/archie.sh` (`${ARCHIE_LLM_MAX_USD:-0.60}`).

**A budget stop retries.** `bin/archie.sh` reads agent-call's `$raw.json`
envelope after a failed call (`archie_budget_stop` in `bin/lib/archie.sh`, the
same structural test agent-call uses). On a budget stop the slot stays open
(no advance) and the `model_failed` event's body becomes
`budget_stop <retry_after> usd=<cap> cost=<n|?>`. The next tick parses it
(`archie_fail_class`) BEFORE the metric read or any spend and skips the slot
until `retry_after`. ONE ALERTS line per slot names the settings row to raise:

    archie: initiative <id> check <due> hit its dollar cap (ARCHIE_LLM_MAX_USD=0.60, cost 0.43); raise the settings row lane.archie.archie_llm_max_usd; retrying every 60m, up to 6 attempts

A budget-stop slot is capped by `ARCHIE_RETRY_MAX` billed attempts (each
counted before its call, as before), then closes to the next cadence with one
`hit its dollar cap <n> times` line. Worst case per slot:
`ARCHIE_RETRY_MAX x ARCHIE_LLM_MAX_USD` = 6 x $0.60 = $3.60. The pre-call write
now carries body `attempt`, so a retry that fails for an ordinary reason falls
back to `ARCHIE_MAX_ATTEMPTS`. A budget-stop write that fails leaves `attempt`
too: the conservative (smaller) cap. No route, `ARCHIE_LLM_MAX_USD=0` and
agent-call rc 74-79 already counted no attempt and still do. No worker or
schema change: the state rides the existing `body` column of the event.

**Unreadable re-checks daily.** An unreadable metric closes its slot with
`advance_to = now + min(ARCHIE_UNREADABLE_RECHECK_H, cadence)` hours, and so
does the repair arm for a closed `unreadable` slot whose advance was lost. Each
re-check is its own slot. Once the metric reads, the next cadence counts from
that check, so a weekly grid moves.

**The rework scan orders repos.** `bin/outcome-metrics.sh` reads
`GET /api/initiatives?status=active&limit=100`, takes each
`csv:logs/outcome-rework-rollup.csv#<col>@project=<p>` metric in id order,
dedupes, and passes the projects to `rework_scan` as an optional 14th argument.
`bin/lib/outcome-rework.sh` moves those repos to the front of `repos.tsv`. An
unreadable read is one `rework: initiatives unreadable; fleet order` line. The
summary line carries `rework_first=<list|->`.

**The BUDGET STOP line has a number.** `bin/agent-call.sh` printed
`${USD:-?}` at top level, where `run_attempt`'s `local USD` is out of scope. It
now reads `$OUT.json`'s `total_cost_usd`, then the new `LAST_ATTEMPT_USD`, then
`?`.

## Knobs (all `lane.archie.*` settings rows)

| knob | default | range |
|---|---|---|
| `ARCHIE_LLM_MAX_USD` | 0.60 (was 0.10) | 0..1 |
| `ARCHIE_RETRY_MAX` | 6 | 1..48 |
| `ARCHIE_RETRY_BACKOFF_MIN` | 60 | 15..1440 |
| `ARCHIE_UNREADABLE_RECHECK_H` | 24 | 1..168 |

Out of range is one warn line in `logs/archie.log` and the default.

## Honest limit

cromford merged 1677 PRs in the 60 days before 2026-10-05, which is more
than `REWORK_FETCH_CAP=1500`. Scanned first, its 60-day backfill still needs a
SECOND Monday run, resuming off the file cache. The ordering guarantees it is
never starved behind client repos; it does not make one run enough. The lever
is the settings row `lane.outcome-metrics.rework_fetch_cap`, or a hand-run of
the lane. The default is unchanged.

Verified by `tests/archie-check-retry.bh-4609-test.sh`,
`tests/agent-call-budget-stop-cost.bh-4609-test.sh`,
`tests/outcome-rework-order.bh-4609-test.sh` and
`tests/archie-initiative-tracer-test.sh` (T6 now expects +24h).
