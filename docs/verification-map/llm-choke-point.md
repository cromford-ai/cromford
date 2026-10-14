# Every model call is counted, and the ones that go through the choke point can be refused before the money is spent

**What it is:** BH-1141 phases 1 and 2 — `catalog/llm-sites.json` +
`docs/LLM_CALL_SITES.md` (the census of every place this fleet invokes a model),
`tests/llm-call-ratchet-test.sh` (the grep ratchet that keeps it true),
`bin/lib/llm-gate.sh` (three knobs consulted **before** the vendor call, wired
into `bin/agent-call.sh` at the whole-call boundary and again at the top of
`run_attempt`), and `GET /api/metrics/llm-spend` (the D1 aggregate the daily USD
cap is compared against).

**Why it exists:** the operator, 2026-09-20 — *"identify any and all points where LLM
calls are used and make sure we monitor them for costs and operations and
pathway … all LLM costs must be gated in a way we can see the costs and control
the pathway and the operation."* That morning `bin/alert-triage.sh` had spent
$793 in twelve hours by descending a ladder that costs ~100x the standing lane
(grok cliff → codex → Fable over OpenRouter), and nothing in the fleet could
have stopped it before the money was gone: no per-lane pathway control, no daily
ceiling that runs before the call, and refusals indistinguishable from billed
failures. `bin/agent-call.sh` was *supposed* to be the one place a model call
happens — and nothing checked that claim, so `bin/orchestrate.sh` had been
calling `codex exec` and `grok -p` with a 1800s timeout and no cost row at all.

**The five decisions that shape it:**

1. **Before the call, never after.** The whole-call gate sits ahead of the phase
   row and ahead of every `run_attempt`; the per-rung gate is the first thing
   `run_attempt` does after the no-tools contract. A guard that runs after the
   response has arrived has already spent the money and still reviews as
   correct — the shape
   [`~/.claude/rules/metered-api-dedup.md`](../../CLAUDE.md) is written about,
   and the shape `tests/llm-gate-test.sh` asserts against by checking whether
   the fake vendor process **executed**, never by grepping the source.
2. **Fail open, always.** No registry, no `lane-gate.sh`, no `jq`, no worker, an
   unreachable D1, a box whose sync has not landed the library — every one of
   them leaves the call running exactly as it runs today, with one throttled
   line in `logs/lane-gate.log`. Every lane in this fleet runs today with no
   gate at all; that is the behaviour a failure has to degrade to. A spend
   control that stops the fleet when a database blinks costs more than the spend
   it guards.
3. **A lane is resolved exactly, never approximately.** The lane a call belongs
   to is the registry lane whose `cost_project_filter` *is* this project; only
   when no lane claims the project does the stage's null-filter lane answer, and
   only when there is exactly one. A lane registered with several stages
   (`stats.cost_stage` as an array, run-product) is matched on any of them, and
   its cap sums the day's spend over all of them (BH-2304). That is `GET /api/lanes/status`'s own rule,
   which keys ambiguity on the exact `stage|filter` pair — so a cap is compared
   against the number the lanes page attributes to that lane. The round-1 review
   caught the alternative: matching `filter == null OR filter == project` in one
   pass made `run-triage` collide with all three filtered triage lanes, so
   `lane.alert-triage.llm_usd_cap_day` was a row nothing ever read and nothing
   logged it — the cap on the lane that spent the $793, silently never firing.
4. **Unset is unlimited.** `LLM_LANE_ENABLED` defaults to 1, `LLM_RUNNER_ALLOWED`
   to empty (every rung — today's ladder), `LLM_USD_CAP_DAY` to 0. A fleet with
   no settings rows behaves byte-for-byte as it did before this landed, and the
   negative cases in the suite are what prove it.
5. **A refusal is a row, not an absence.** Every gated refusal writes a
   zero-cost `row_source=refused` row carrying `refused:<reason>`, through the
   same `cost_append` every billed row goes through, so it rides the existing
   mirror into D1. "The lane went quiet" and "the lane is being stopped" are
   different events, and an operator has to be able to tell them apart.

**The honest limits, said out loud:**

- The gate covers `bin/agent-call.sh` and `bin/claude-cost.sh` (BH-2534: the
  orchestrator's primary turn as lane `orc-monitor`, greenfield, box-chat's
  `-c` rung), which runs the same `llm_gate_precall` / `llm_gate_runner_ok`
  and K3 before claude starts and exits 74 on a refusal. The sites
  `catalog/llm-sites.json` marks `gated: none` are **not** gated by this, and
  neither is a box with no `bin/lib/cost-row.sh`, where claude-cost execs
  claude directly. `docs/LLM_CALL_SITES.md` is that list, published rather
  than implied.
- **Phase 3 has landed (BH-2303): cost rows carry `lane_id`, and every LLM
  lane in `catalog/llm-sites.json` exports `AGENT_CALL_LANE`.** The gate asks
  `GET /api/metrics/llm-spend?lane=<id>&stage=…`, which sums the rows stamped
  with that lane plus the rows written before `lane_id` existed (by their old
  `(stage, project)` signature), so `review-prs`, `review-autopilot` and
  `merge-conductor` each have their own cap, runner list and on/off switch. A
  call that names no lane resolves exactly as below and stamps the resolved
  id (`stage-review`, …) on its row. The name is the CALL's, never a child's:
  agent-call does `export -n AGENT_CALL_LANE` (no vendor CLI, and no `setsid
  run-build.sh` a session starts, inherits it) and `bin/run-build.sh` unsets it
  at entry, so a build a triage session launches is its own lane. Proof: `tests/llm-lane-id.bh-2303-test.sh`
  and `worker/jobs/test/llm-spend-lane.bh-2303.test.js`.
  BEFORE BH-2303 a cost row carried `(stage, project)` and nothing that named a
  lane, so those three all landed as `stage=review` and a lane-scope cap summed
  the *signature*. What follows still describes a call with NO lane name:
  - **A lane with no project filter sums its whole stage, fleet-wide.**
    `run-triage`'s cap is measured against `alert-triage` + `alerts-medic` +
    `watchdog-responder` + `run-triage`, because all four price as
    `stage=triage`. The per-project row (`lane.run-triage.<project>.…`) is the
    ceiling that sums only that project.
  - **`review` and `execute` are shared, and `bin/harness-ctl.sh` cannot
    address them.** Several lanes share `review` and `execute` (the registry
    says which; `GET /api/lanes/status` lists them as `cost_shared_with`), so a
    call on those stages resolves to the synthetic `stage-review` /
    `stage-execute`. `harness-ctl set stage-review …` is refused (`no lane`) on
    purpose: it is not a registry lane, and a CLI that invented one would let an
    operator believe they had capped `review-autopilot` alone. The knob is set
    for those stages by writing the raw settings key —
    `lane.stage-review.llm_usd_cap_day` via the console or
    `PUT /api/settings` — or by `LLM_USD_CAP_DAY` in `env/global.env` on the
    box. (Every catalogued lane now names itself, so this applies only to a
    caller that does not.)
- **A refused lane still writes a row per tick.** The *log* line is throttled;
  the ledger is not. A disabled lane on a `*/2` cron adds ~720 zero-cost
  `row_source=refused` rows a day to `logs/cost.csv` and D1. That is deliberate
  — the refusals are the record that the lane is being stopped rather than
  broken — but they are excluded from `unpriced_calls_24h` (`bin/cost-rollup.sh`)
  so they cannot drown the number the cost-capture-parity rule watches.
  Coalescing them is a later phase.
- **There is a SECOND daily dollar cap, in a different file, on the same three
  hub lanes.** `catalog/lane-caps.conf` (BH-1039) carries `lane alert-triage 5
  20000`, `lane medic 90 …`, `lane responder 150 …`; `lane_day_cap_tripped` in
  `bin/alert-triage.sh`, `bin/alerts-medic.sh` and `bin/watchdog-responder.sh`
  reads it from **this box's own `logs/cost.csv`** and stops the whole pass
  before the lane even fetches its queue. `LLM_USD_CAP_DAY` is per lane, read
  from **D1**, and refuses per call. They do not know about each other, so **the
  lower of the two is what an operator actually gets**: setting
  `LLM_USD_CAP_DAY 25` on `alert-triage` does not move its $5/day file cap, and
  raising `lane-caps.conf` does not lift a D1 cap. The `GATE REFUSED before the
  call:` line says this too. Folding one into the other is phase 3 work; until
  then, check both files before concluding a lane is stopped for the reason you
  think it is.
- **The cap is blind to this box's un-mirrored spend, by up to one push
  cycle.** `llm_gate_spend_today` asks D1, and `bin/cost-rows-push.sh` mirrors
  `logs/cost.csv` on a 10-minute cadence, so rows written since the last push
  are not in the number the cap compares against. The bound is the arithmetic:
  at the incident's ~$66/h on one lane that is **~$11 per lane per box** of
  invisible spend at the worst moment — on exactly the box doing the burning.
  A cap set to stop a runaway will therefore stop it up to ten minutes and
  ~$11 late, not instantly. Reading the local rows after the push cursor would
  close it, and is deliberately NOT done here: a cap that reads one box's own
  file is the bug `tests/llm-gate-test.sh` case 5 exists to pin (a $900 local
  row must not refuse a fleet day that cost $0.20). The real close is a
  push-on-write or a shorter cadence, in phase 3.
- **`LLM_RUNNER_ALLOWED` is per LANE, with the same sharing caveat as the cap.**
  Pinning `review` to claude pins `review-autopilot`, `merge-conductor` and
  `review-prs` together, because all three resolve to `stage-review`. The
  per-CALL-SITE form is `AGENT_CALL_RUNNERS` (BH-1019), which refuses with rc 2
  before the ladder starts and is the right tool when only one caller should be
  pinned.
- **Who DEFERS on a refusal, and who fails the ticket.** Reading rc 74 as
  before-billing is a per-caller property, and only these callers have been
  taught it: `bin/review-autopilot.sh` (no key, no cap charge, retries next
  tick), `bin/lib/preplan-lib.sh` (the attempt is not counted),
  `bin/alert-triage.sh` (the family is re-spooled at its pre-tick stamp),
  `bin/alerts-medic.sh` (the family is left unconsumed and its 6h brake stamp
  released) and `bin/watchdog-responder.sh` (no 12h cooldown stamped). The
  BUILD lanes do not: `CC()` in `bin/run-build.sh` reads any nonzero rc as a
  stage failure, so a refusal on `plan`, `execute`, `review` or `fix` **fails
  that stage** and hands the ticket to the resolver/rebuild ladder. That is
  survivable (the ticket is rebuilt when the lane is back) but it is not free —
  so capping or disabling a build lane is a decision about tickets, not only
  about dollars. Teaching `run-build` the family is phase 3.
- **A refusal never hides a call that was billed.** On a mixed ladder — the
  primary RUNS, fails and is billed, and the rungs below it are refused —
  `bin/agent-call.sh` exits with the **billed attempt's** rc, not 74, leaves the
  vendor's own error text in `$OUT`, logs `DEAD` rather than `GATED`, and the
  survival-lane blocks ask the gate before they page, so a rung the lane may not
  reach wakes nobody. The refused rungs still leave their zero-cost rows and
  their `failovers.log` lines. Round 2 of the review caught the alternative: a
  trailing 74 told every caller above that a billed failure was free to retry,
  which is an unbounded billed retry loop built by the spend guard itself.
- **A gated refusal is rc 74**, a member of `bin/agent-call.sh`'s before-billing
  family (74–79: nothing called, nothing billed). It is not rc 2, because rc 2
  is also a vendor CLI's own generic error and `bin/review-autopilot.sh` reads
  an unrecognised rc as a billed death — it would charge its daily cap and write
  a terminal key for a call nobody made. `bin/review-autopilot.sh`,
  `bin/lib/preplan-lib.sh` and `bin/alert-triage.sh` all read 74 as
  before-billing; `alert-triage` additionally re-spools the family at its
  pre-tick stamp, so turning the lane off does not throw its alerts away.
- Phases 3–5 of #1141 (pricing parity per pathway, the Mission Control page,
  the deterministic replacements) are **not** in this. The inventory names the
  replacement candidates; it does not ship one.
- The issue's phase-2 list also names `max_context_tokens`. It is deliberately
  **not** a knob here: that ceiling exists already and is enforced *inside* the
  call — `context_kill_tokens` in `catalog/context-budgets.json`, metered live
  by the BH-653 context kill. A second knob meaning the same thing in a second
  file is the two-spellings failure BH-1132 was written about. Moving it to a
  settings row is a knob migration, not a gate.

**How an operator reaches it:**

| Surface | Where | What it says |
|---|---|---|
| the census | `docs/LLM_CALL_SITES.md` | every call site, whether it goes through the choke point, whether it is priced, whether anything can refuse it. GENERATED and git-ignored since BH-1268 — run `bin/llm-sites-build.sh` if your checkout has no copy |
| the data behind it | `catalog/llm-sites.json` | the same, queryable. COMPOSED and git-ignored since BH-4987: the committed sources are `catalog/llm-sites.d/` (`_head.json`, `0000-base.json`, and one `NNNN-<id>.json` per added site). Add or edit a fragment, then run `bin/llm-sites-build.sh` |
| stop one lane's spending | `bin/harness-ctl.sh set <lane> LLM_LANE_ENABLED 0` | settings row `lane.<id>.llm_lane_enabled` |
| pin a lane to one pathway | `bin/harness-ctl.sh set <lane> LLM_RUNNER_ALLOWED claude` | the only rungs the ladder may reach for that lane |
| cap a lane's day | `bin/harness-ctl.sh set <lane> LLM_USD_CAP_DAY 25` | dollars for the UTC day, summed from D1 `cost_rows` |
| cap one project of a lane | `bin/harness-ctl.sh set <lane> LLM_USD_CAP_DAY 5 <project>` | settings row `lane.<id>.<project>.llm_usd_cap_day`; a second ceiling, never an inherited one |
| what the gate did | `logs/failovers.log` | `GATE REFUSED before the call: …` / `GATE REFUSED rung '<runner>': …` |
| what it could not read | `logs/lane-gate.log` | one throttled line per lane when a cap is set and D1 did not answer |
| the refusals themselves | `logs/cost.csv`, D1 `cost_rows` | `row_source=refused`, `cost_usd=0`, `note=refused:<reason>` |
| the numbers | `GET /api/metrics/llm-spend?stage=&project=&since=` | `{usd, calls, refused}` for the window |
| cap a stage several lanes share | settings key `lane.stage-review.llm_usd_cap_day` (console / `PUT /api/settings`) | `review` and `execute` resolve to a synthetic id `harness-ctl` will not accept — see the limits above |
| which lanes take the `set` above | `bin/harness-ctl.sh show <lane>` | the eleven lanes whose calls reach `bin/agent-call.sh` declare the three `LLM_*` knobs in `catalog/lanes.json` |
| the OTHER daily cap on the hub triage lanes | `catalog/lane-caps.conf` | BH-1039's per-lane dollars/bytes, read from this box's `logs/cost.csv`; the lower of the two caps wins |
| the escape hatch | `LLM_GATE_DISABLE=1` | the previous invocation, verbatim |

**How it is driven:**

| Suite | What it runs |
|---|---|
| `tests/llm-gate-test.sh` | the REAL `bin/agent-call.sh` against a scratch `$HARNESS` with fake CLIs that leave a file behind when they run: unset-is-unlimited, a disabled lane, a rung outside `runner_allowed` (and the negative — no list still descends), the cap refusing before the call, the cap reading D1 and not the box's own `cost.csv`, fail-open on an unreachable worker, the escape hatch, and the library sourced with nothing around it. Round 1 added the three that reach production: a cap row on a *filtered* lane refuses its own call and not the null-filter lane's (plus the real `catalog/lanes.json` resolving `(triage, alert-triage)` → `alert-triage`, `(triage, project-1)` → `run-triage`, `(review, cromford)` → `stage-review`), `bin/harness-ctl.sh set <lane> LLM_*` accepted for all three knobs, and rc 74 read as before-billing by the shipped blocks of `review-autopilot.sh`, `preplan-lib.sh` and `alert-triage.sh`. Round 2 added the mixed ladder: a BILLED primary failure followed by refused descents must exit with the primary's rc, keep the primary's output in `$OUT`, write no `tier-3`/`SURVIVAL` page and call `beat.sh` not at all — and `bin/alerts-medic.sh` must consume no alert on a refusal |
| `tests/llm-call-ratchet-test.sh` | the scanner against planted fixtures (caught) and prose/`command -v`/string literals (not caught), then the whole repo: no vendor call outside `bin/agent-call.sh` that is not allow-listed with a reason, every allow-listed file present in the catalog, every catalog marker still findable, and the doc in sync with its source |
| `worker/jobs/test/llm-spend.test.js` | the aggregate route: the SUM, the default UTC-day window, refusals counted separately, `0` rather than `null` on an empty window, and the bearer |
