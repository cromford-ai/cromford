# Lane volume caps (dollars per day, evidence bytes, and a cliff that refuses)

**What it is:** three bounds on the hub's LLM lanes, all read from
`bin/lib/lane-caps.sh` over `catalog/lane-caps.conf`, plus a fourth in
`bin/agent-call.sh` that stops a price-driven reroute becoming a price increase.

It exists because of one day. On 2026-09-20, 00:00–12:20Z, `logs/cost.csv` stage
`alert-triage` carried **208 rows and $793**, against $39–$61 a day for the five
days before it. Nothing was broken in a way a log could show:

| day | rows | USD |
|---|---|---|
| 09-15 | 187 | $40 |
| 09-16 | 233 | $54 |
| 09-17 | 298 | $49 |
| 09-18 | 215 | $39 |
| 09-19 | 366 | $61 |
| **09-20 (12h)** | **208** | **$793** |

The configured `RUNNER_TRIAGE` (grok, ~$0.02 a session here) projected past the
xAI cliff, BH-656's routing correctly skipped it, and the ladder below it went on
to `codex/gpt-6-astra` (81 rows, $392) and `openrouter/anthropic/claude-fable-5.1`
(97 rows, $396) at ~$4 a session. 150 of the 192 sessions concluded
`handled=0 escalated=0 noise=1` — about $4 to call a stale heartbeat noise —
while every tick logged `deferred 485 families to next tick`. The session cap
(`TRIAGE_MAX_FAMILIES=4`) held the entire time. **A session cap is not a spend
cap.** The only stop available to the operator was `TRIAGE_MAX_FAMILIES=0`,
which turns the whole de-noising layer off.

## The five bounds

| bound | where it runs | knob |
|---|---|---|
| daily dollars per lane | `lane_day_cap_tripped` at the top of `bin/alert-triage.sh` (hub cron \*/10), `bin/alerts-medic.sh` (\*/30) and `bin/watchdog-responder.sh` (\*/20) | `catalog/lane-caps.conf` → `flags/lane-caps.conf` → `LANE_USD_CAP_<LANE>` (`off` = uncapped) |
| daily noise-only sessions per lane (BH-1168) | `lane_noise_cap_tripped` at the top of `bin/alert-triage.sh` AND again before each family's call; `lane_noise_record` reads the session's own `handled=N escalated=N` summary | the `noise <lane>` rows of the same files → `LANE_NOISE_CAP_<LANE>` (`0` = stopped, `off` = unbounded) |
| evidence bytes per prompt | `lane_evidence_cap` in `bin/alert-triage.sh` and `bin/alerts-medic.sh`; `RESPONDER_EVIDENCE_CAP_BYTES` in `bin/watchdog-responder.sh` now defaults through `lane_cap_bytes` | same file, third column → `LANE_BYTES_CAP_<LANE>` |

`lane_evidence_cap` returns **rc 2** when not one COMPLETE record fits the cap
(round 2, I4): the marker is still printed, but the rc says there is no evidence
here, and both callers then buy NO session — the triage lane re-spools the family
at its pre-tick stamp, the medic marks nothing SEEN — with one
`EVIDENCE CAP TOO SMALL` page per lane per UTC day, because a skip that repeats
until a human raises the cap and says nothing is the same dead-feed shape as a
$4 session that read nothing.

Rows in `catalog/lane-caps.conf` may carry inline `# comments`; everything from
the first `#` is cut before the row is split (round 2, N1). `lane_day_usd` reads
the last `LANE_CAPS_SCAN` (4000) rows of `cost.csv` and writes a
`lane-caps.log` line when that window's oldest row is already dated today, i.e.
when the day total may read LOW (round 2, N2); those degrade lines are deduped
per lane per UTC day **per message**, so a second, different fault is not
swallowed by the first (round 2, N3).
| deterministic settlement | the `DETERMINISTIC SETTLEMENT` block of the splitter in `bin/alert-triage.sh` | `TRIAGE_STALE_AKEYS` (empty by default), `TRIAGE_STALE_TTL`, `TRIAGE_RESOLVED_PATTERNS` |
| refuse instead of descend | `cliff_refuse_enabled` + the `CLIFF REFUSAL` gate in `bin/agent-call.sh`; the `CLIFF REFUSAL` block of `bin/alert-triage.sh` defers | `cliff_refuse` on the lane in `catalog/context-budgets.json` → `LADDER_CLIFF_REFUSE` → `flags/cliff-refuse-off` |

## The day total prices what the vendor did not

`lane_day_usd` does not sum column 13 and stop. A row with token counts and a
**blank** `cost_usd` — which is what these three lanes have been writing, and
what put "unpriced" in the ticket title — is priced through `cost_price_tokens`,
the repo's one pricing formula, cliff included. A cap that read a blank cost as
$0.00 would be a cap that never fires on exactly the lanes it was built for.
`tests/lane-caps.bh-1039-test.sh` §D asserts the library's number equals
`cost_price_tokens`'s for the same row, so this can never become a second
formula.

## Nothing is dropped when a lane stops

Each gate sits **before** the lane consumes anything:

* `alert-triage` checks before the collector drains `state/alert-quarantine.jsonl`
  (and before the deferral spool is drained), so every alert is still where it
  was;
* `alerts-medic` checks before the groom and the `/api/alerts/open` fetch — the
  console is its queue and it re-offers oldest-first;
* `watchdog-responder` checks before `stale-owed-tickets.sh`, and `handled.json`
  is only written after a pass runs.

One `DAILY SPEND CAP` line goes to `ALERTS.log` per lane per UTC day (144 ticks
must not mean 144 pages), naming the spend, the cap, the conf file and the
one-run release valve.

## The noise budget bounds the pointlessness, not the bill (BH-1168)

A session concluding `handled=0 escalated=0` costs full price and produces
nothing — 150 of the 192 sessions above, and **every one** of the 11 that the
clamped session cap let through on the 16:10–21:20Z tail. The dollar cap only
catches that after the day's money is gone, so the fifth bound is counted in the
unit that was actually wrong.

`lane_noise_record alert-triage <handled> <escalated>` runs after each bought
session, reading the summary from the session's own output (never the lane log,
which is cut at 200 characters). `handled=0 escalated=0` bumps
`state/lane-noise-<lane>.count`; **anything the session actually did resets it
to 0**, so a lane that starts finding real problems again is not still stopped
on this morning's noise. Both fields must parse or nothing is written: a session
that died is neither a noise verdict nor a useful one, and a broken runner must
not be able to stop the lane. Only BOUGHT sessions reach it — deterministic
settlement, the cliff refusal and the gate refusal all `continue` first.

The counter is ONE file per lane holding `<YYYY-MM-DD><TAB><n>`, written
`tmp`+`mv` under a sub-second `flock`; another day's stamp reads 0 and is
overwritten, so there is nothing to prune. A missing file is a real 0. A file
that is present and unreadable — a directory, a truncated row — **fails open**:
`lane_noise_count` answers rc 2, the lane RUNS, and the degrade is declared in
`logs/lane-caps.log`.

`lane_noise_cap_tripped` is checked twice: at the top of the tick, before any
collection, and again before each family's call, so the tick that crosses the
budget stops inside itself instead of buying `TRIAGE_MAX_FAMILIES-1` more.
Families past the budget are re-spooled at their pre-tick stamp, exactly like an
rc-74 gate refusal — nothing is dropped and nothing is marked seen by a session
that never ran. One `NOISE BUDGET` page per lane per UTC day names the count,
the budget, the conf file and `LANE_NOISE_CAP_<LANE>=off`.

## Settlement is a verdict, never an absence

**Both rules are POSITIVE**: each points at a specific line IN THIS BATCH that
makes the settled line redundant.

- `superseded` — a strictly newer beat with the SAME AKEY is in this batch, so
  the older one describes a moment the newer one has already replaced. The
  newest beat of every akey always survives to a session.
- `resolved` — the family's newest line is the EMITTER'S OWN RETRACTION.

**A retraction is a structured fact, not a word in the prose (round 2, B1).**
The first draft ran `\bRESOLVED\b|has recovered|…` over the whole quarantine
line — and because `family()` keys on that same text, a matching family
consisted only of matching lines, so "the newest line" was vacuous and the rule
reduced to "text matches → settled". Two emitters put the word inside a FIRING
line: `bin/fleet-slo.sh:271` ends every SLO BREACH with "…clears itself with a
RESOLVED line.", and `bin/blocked-resolver.sh:2444` parks a rung with "no
repo/branch could be **resolved** for …". Both were settled at $0 and logged
"condition cleared" — a false verdict on a live alert.

So the STRUCTURED FIELD decides: `resolved:true` (or `alertstate:"resolve"`),
which is what `bin/lane-alert.sh:107` and `bin/pipeline-health.sh:749/820/1008`
— every retraction emitter in this repo — write, and what `bin/beat.sh:227`
already reads to keep the remediator off a retraction. The text rule survives
only for a retraction carrying neither field, ANCHORED with `.match()` to the
start of the beat's own `.line` (`RESOLVED …`, `[pipeline-health] RESOLVED …`),
never as a substring. `TRIAGE_RESOLVED_PATTERNS` replaces that anchored default
and is compiled inside `try/except re.error`: a typo costs the knob, never the
tick.

**A splitter that dies re-spools.** The collector DRAINS every box's quarantine
and the deferral spool into `$WORK` before the splitter runs, so any exception
in it used to leave both split files empty over an already-consumed batch and
the lane logged "all N line(s) are repeats of families triaged <6h ago" — a
total loss behind a reassuring line. A non-zero splitter rc now puts the whole
batch back on `state/alert-triage-deferred.tsv` and says so.

**Age is not a rule.** The first draft settled anything older than
`TRIAGE_STALE_TTL` whose TEXT matched `stale|heartbeat|…`, on the premise that
such a class "re-beats while it holds". That premise is false for the very
emitters the pattern matched: `bin/fleet-heartbeat.sh:78` emits `hb-stale` ONCE
behind `state/stale-$h` and clears it only on recovery, `bin/merge-queue.sh`'s
`mq-stale` is a one-shot, and `bin/pipeline-health.sh`'s `stalepr` re-raises at
21600s against a 3600s TTL. A watcher that died at 02:00 and sat behind the
485-family backlog would have been logged NOISE-STALE and never restarted.

An operator who has VERIFIED that an emitter re-raises faster than the TTL can
opt it in by AKEY PREFIX: `TRIAGE_STALE_AKEYS=health:sweepstall:` (comma
separated, empty by default, matched against the akey and never the payload).

Every settled line gets a `NOISE-STALE (deterministic, no model call)` line in
`logs/alert-triage.log` carrying the rule and the alert text that justified it —
the same verdict a session's STEP 0 would have written, for $0.

## The refusal is bounded

**The refusal is a price comparison, not a reflex.** `cliff_refuse_costlier`
prices the rung below and the skipped runner at the SAME projected context
(cliff included) and refuses only when the rung below is dearer; when it is
cheaper the ladder descends exactly as BH-656 intended.

**It prices the model that rung would ACTUALLY run (round 2, I2).** Every rung
remaps: codex runs `${CODEX_MODEL:-gpt-6-astra}`, fireworks runs
`$FIREWORKS_MODEL`, openrouter runs the `anthropic/` slug, and only a `claude`
rung runs the stage's argv `$MODEL`. The gate priced `$MODEL`, so it refused a
cheap fireworks rung and approved a descent onto codex running an opus model —
the 2026-09-20 shape. `ladder_model_for` (the same expressions `run_attempt`
uses) and `cliff_next_runner` (the same guards the ladder uses) name the rung
and its model, and the failovers line names both.

**And it covers the tier-2 cliff too (round 2, I3).** The gate ran only after
the PRIMARY's cliff, so a lane whose primary FAILS and whose tier-2 grok then
cliff-routes walked on to the fallback and OpenRouter with `cliff_refuse` on —
the same ladder, one rung later, while logging "continuing down the ladder".
The identical gate now runs after the tier-2 block, and the failovers line says
`CLIFF REFUSE (tier-2)`. That matters because a
refused call writes no cost row and `cliff_projected_context` is the median of
the last ten rc-0 rows — a lane that only ever refuses can never move the number
it refused on. An unpriceable rung refuses (the one reader here that does not
fail open: descending on a rung nobody can price is the $793 shape itself).

**The exit path is the floor retry.** A strong-tier cliff is retried ONCE on the
housekeeping floor lane, which has no cliff at this size and costs cents: that
both triages the family and writes the rc-0 row that lets the projection fall.
`TRIAGE_CLIFF_FLOOR_RETRY=0` turns it off.

When every rung refuses, refusals are counted per family in
`state/alert-triage-cliff.json` and the family is re-spooled with its PRE-TICK
stamp restored (popping the stamp would make a repeat look brand new and buy it
the strong tier). Past `TRIAGE_CLIFF_MAX_REFUSALS` (3) its lines are PARKED in
`state/alert-triage-cliff-parked.tsv` — not dropped — and ONE `CLIFF REFUSALS`
line per LANE per UTC day goes to `ALERTS.log`, naming the config that fixes it
and the `cat … >>` that re-queues the parked lines. A session that runs resets
that family's count to 0.

## How to drive it

```
tests/lane-caps.bh-1039-test.sh          the library: conf grammar, env overrides,
                                         the marker, the priced day total, one page
tests/triage-volume-caps.bh-1039-test.sh the real bin/alert-triage.sh end to end
tests/lane-day-cap.bh-1039-test.sh       the real alerts-medic / watchdog-responder
                                         gates, and bin/agent-call.sh's refusal
tests/triage-noise-budget.bh-1168-test.sh the noise budget: the library's counter,
                                         reset and fail-open, and the real
                                         bin/alert-triage.sh stopping at the budget
```

On a live hub: `logs/alert-triage.log` shows `NOISE-STALE (deterministic, no
model call)` lines and, when a bound trips, `STOPPED on the lane's daily spend
cap` or `STOPPED on the lane's noise budget`;
`state/lane-noise-alert-triage.count` holds `<day><TAB><n>` moving with the
sessions, and `bin/harness-ctl.sh show alert-triage` carries the
`LANE_NOISE_CAP_ALERT_TRIAGE` knob row; `logs/failovers.log` shows `CLIFF REFUSE`; `logs/lane-caps.log` holds the
fail-open degrades (an unreadable ledger reads $0.00 and the lane keeps running —
a bound that stops a lane because a file was missing would take out the
de-noising layer exactly when it is needed).
