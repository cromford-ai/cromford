# The rule-miner reads a digest, runs as stage `mine` on its route's runner, and refuses over its ceiling

Doc: CONTEXT-COMPOSITION

BH-1764 (BH-1749.2). All in `bin/rule-miner.sh`, plus the rule-miner row of
`catalog/llm-sites.json`.

## What was wrong

The miner called `agent-call.sh triage rule-miner "$MINER_MODEL"`. As stage
`triage`, `bin/agent-call.sh` picked the runner from `RUNNER_TRIAGE`, which is
`grok` on the hub, so the fable route was silently replaced. Every run since
2026-08-31 in `cost.csv` is `rule-miner,triage,grok,grok-4.6`. The prompt also
said "Read every bundle": the 2026-09-21 run read 8.05M input tokens for $1.99.

## What it does now

1. **Digest only.** After the inventory is built (and after the zero-incident
   exit), the miner runs
   `rule-miner-digest.sh <findings.log|/dev/null> inventory.tsv digest.md digest-ids.txt`
   in `state/rule-mining/<date>/`. The prompt points the session at `digest.md` and
   tells it not to open the bundle files or `logs/findings.log`. A digest that
   fails (nonzero rc or an empty `digest.md`) stops the run: rc 1, one LOG line,
   one ALERTS line, no agent call, nothing marked seen. `mark_seen` now appends
   `digest-ids.txt`, so an incident the digest left out comes back next week.
   `RULE_MINER_DRY=1` also prints `digest: <path> (~N tokens)`.
2. **Own stage, route runner.** `MINER_RUNNER` is the runner on rung 0 of the
   `rule.miner` route (`lane_model_ladder`). No route is the existing rc-75 skip.
   A runner other than `claude` is refused before the lock or any gathering:
   rc 75, one ALERTS line (`rule.miner routes to runner <r>; only the claude
   runner is context-metered, so the ceiling cannot be enforced`). The call is
   `AGENT_CALL_RUNNERS="$MINER_RUNNER" agent-call.sh mine rule-miner …`, and the
   job row is `mine/rule-miner/$MINER_RUNNER`.
3. **Pre-call ceiling gate**, just before the call:
   `PROJECTED = (bytes(PROMPT) + bytes(digest.md) + bytes(build-discipline.md) + bytes(checks/README.md if it is a file)) / 4`.
   `CEIL` is the `rule-miner` lane's `ceiling_tokens` in
   `${CONTEXT_BUDGETS:-$HARNESS/catalog/context-budgets.json}`. It fails closed:
   an unreadable catalog, a missing lane, or a ceiling that is not a positive
   JSON number all refuse, with `ceiling=unknown`. On refusal: the log line
   `CEILING REFUSED projected=<n> ceiling=<c> — no agent call made`, one ALERTS
   line naming `RULE_MINER_DIGEST_MAX_TOKENS` and the lane's `ceiling_tokens`,
   `job_event … mine CEILING_REFUSED`, then exit 1. Nothing is marked seen.
4. **Priced spend line.** `_miner_spend_line` reads `logs/cost.csv` by column
   name from the file's own header. It takes rows where `project` is exactly
   `rule-miner`: this run's rows (`ts >= RUN_T0`) give
   `context_tokens=Σ(input_toks+cache_read)` and `cost_usd=Σcost_usd`, and the
   last 7 days give `week_spend_usd`. An empty `cost_usd` makes that figure
   `UNPRICED`, no rows is `none`, and never `0.00` for either. The line is
   appended to every log line after the call: no draft, NO_RULE, malformed,
   PR adopted, PR step failed, PR opened.

## What this makes stale

The `rule-miner` lane row in `catalog/context-budgets.json` is now LIVE: a call
site uses stage `mine`, so its `context_kill_tokens` and `cliff_refuse` apply in
`bin/agent-call.sh`. The row's own notes still say the lane is pending or inert.
They are not edited here, because that file belongs to the contract slice.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/rule-miner-ceiling.bh-1749-test.sh`. Live
check: the Monday `logs/rule-miner.log` line carries `context_tokens=` and
`week_spend_usd=`, `cost.csv` shows `rule-miner,mine,claude`, and no new `CLIFF:`
line appears.
