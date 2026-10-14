# BH-1384 (BH-1201.3): the act session capped under the model cliff, the decision call pinned to claude

Doc: COST

## What changed

**`bin/agent-call.sh`** — `_ctx_kill_ceiling` takes an optional 4th argument,
the attempt's resolved model, and the claude call site passes `$cm` to it. With
`CONTEXT_KILL_CLIFF=1` and a model that `cost_model_cliff` prices with a cliff
`N`, the session ceiling becomes `min(lane cap, N - CONTEXT_KILL_CLIFF_MARGIN)`
(margin default 10000). Three facts about that:

- It only ever LOWERS a ceiling the lane already declared. A lane with no
  `context_kill_tokens` key stays unbounded — "no key = unbounded" is what the
  other 78 lanes are running on, and a cliff must not quietly bound them.
- A margin at or past the cliff floors the ceiling at 1000 tokens and writes one
  line to `logs/failovers.log` naming the cliff, the margin and the floor. A
  ceiling of zero-or-less would kill the session on its first meter read with
  nothing saying why.
- `$OUT.cliffcap` (`cliff=N ceiling=M model=… margin=…`) is written ONLY when
  the cliff is what lowered the ceiling, and it is removed before every attempt
  alongside `$OUT.ctxkill`. When the lane cap is already the smaller number the
  stop is an ordinary lane-cap kill and is labelled as one.

That marker is what the copy keys on: with it, the lane alert reads
`CLIFF-AVOIDED:` instead of `CONTEXT KILL:` and names the cliff and the model,
and so do the ladder's two `logs/failovers.log` lines. The alert's
`lane-alert.sh --id` is unchanged (`context-kill:$STAGE/$PROJECT/$_sid`), so the
alert state machine dedupes a `CLIFF-AVOIDED:` line exactly as it deduped a
`CONTEXT KILL:` one. The truncation marker appended to `$OUT` also keeps saying
`CONTEXT KILL:` — it is the string `bin/review-autopilot.sh` and
`bin/alert-triage.sh`'s `tail -1` match on, and which bound fired is answered by
the alert, not by the marker.

The claude child is now started with `env -u CONTEXT_KILL_TOKENS -u
CONTEXT_KILL_CLIFF -u CONTEXT_KILL_CLIFF_MARGIN` beside the BH-1019
`-u AGENT_CALL_RUNNERS`. A ceiling belongs to the call that set it: the
responder's act playbook may `setsid run-build.sh`, and a `setsid` child
inherits the environment, so without this a 150,000-token responder ceiling
would be applied to every plan/execute/review session that build starts.

**`bin/watchdog-responder.sh`** — two knobs, read through `lane_knob` so a
settings row moves them without a deploy:
`RESPONDER_CONTEXT_CAP_TOKENS > 0` passes `CONTEXT_KILL_TOKENS` verbatim;
at 0 (the default) the lane passes `CONTEXT_KILL_CLIFF=1` and
`CONTEXT_KILL_CLIFF_MARGIN` from `RESPONDER_CLIFF_MARGIN_TOKENS`. Both are
per-command env prefixes on the two tooled calls, never a script-wide export,
so the decision call and anything else the script runs are not bounded by them.
The two are never passed together — the operator's own number returns before the cliff is
consulted, and arming both would imply the cliff had a vote. A box whose sync
has not landed `bin/lib/lane-gate.sh` resolves to the documented defaults.

The decision call is prefixed `AGENT_CALL_RUNNERS=claude` and its log line is
now `responder decision call (no tools, claude) rc=$DRC`. `agent-call.sh`
refuses `AGENT_CALL_NO_TOOLS=1` on a non-claude primary with rc 78, and
`AGENT_CALL_RUNNERS` replaces a disallowed primary with the first name in the
list *before* that check, so the refusal is unreachable by construction. It is a
per-call prefix, not an export: the act call keeps the whole ladder. The
`VALID=0` fall-open path is untouched — a refused decision call must never
silence this lane.

After the act call, a `$OUT.ctxkill` gets one line in `logs/responder.log`
naming the total, the ceiling and (with a cliffcap) the cliff and the model.
That line says the keys this pass covered are **stamped handled and come back
after the 12h cooldown**, because they are: rc 143 is outside the 74..79
before-billing family the no-cooldown branch tests for, and the killed session
read the evidence and cost money, which is exactly the case the cooldown exists
for.

**`catalog/lanes.d/watchdog-responder.json`** — both knobs registered (int, 0
and 10000, bounds 0..6000000 and 0..100000, unit tokens). `zero_means` is
`null`, not a sentence: `tests/lanes-registry-test.sh` §8 allows only
`null | "off" | "unlimited"`, so what 0 means lives in `note`.

## What this does NOT do

No claude model in `catalog/model-prices.json` carries `cliff_tokens` today —
only `grok-4.6` / `x-ai/grok-4.6` do — and the context kill only meters the
CLAUDE rung, because it reads the session's own transcript. So
`CONTEXT_KILL_CLIFF=1` changes nothing in production until a metered rung has a
cliff: the knob that actually bites the responder's 1.7M-3.7M-token sessions
today is `RESPONDER_CONTEXT_CAP_TOKENS`, and until somebody writes that settings
row the lane's ceiling is the 6,000,000 it already had. The price table is
DB-backed (`bin/update-model-prices.sh` refreshes `state/model-prices.json` from
`GET /api/model-prices`, BH-1032); the catalog copy is the documented fallback,
and this change reads it through the same `cost_model_cliff` resolver rather
than adding a second reader.

The lane itself is OFF on the hub (`bin/harness-ctl.sh off`, 2026-09-21).
Turning it back on is the operator's call and is not part of this.

## Where it is pinned

`tests/responder-cliff.bh-1384-test.sh` — the real `bin/agent-call.sh` against a
scratch `$HARNESS` with a growing transcript and a `MODEL_PRICES` fixture
(section A), the real `bin/watchdog-responder.sh` with a recording agent-call
stub (B), and the real `bin/agent-call.sh` behind the responder with
`RUNNER_TRIAGE=grok` set (C). Every assertion is an artifact: `$OUT.ctxkill`,
`$OUT.cliffcap`, `logs/ALERTS.log`, `logs/failovers.log`, `logs/responder.log`,
`state/responder/handled.json`, `logs/cost.csv`, and the environment the child
recorded. Ten adversarial negatives run a session that WOULD die if the cliff
applied and assert it survives — a null cliff, a string cliff, an unknown model,
an unreadable price table, the flag off, the lane with no ceiling.
