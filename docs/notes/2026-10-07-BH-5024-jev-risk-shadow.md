# Jev, a second opinion on the risk tier, in shadow only (BH-5024)

Doc: MERGE-CONDUCTOR

## What changed

- `bin/jev-risk.sh ask <owner/repo> <pr> <head> <rule-tier> <compare-json>` is
  the only code path that spends on Jev (TypeSafe `jev-latest`). It shows Jev
  the head's diff and the rule tier from `bin/lib/risk-tier.sh` and records a
  choice of `low | medium | high` with a probability. The order is: config,
  local spool, claim, call, spool, settle. With no `jev_risk.api_url` row or no
  `TYPESAFE_API_KEY` it prints `not-configured` and claims and calls nothing.
  `bin/jev-risk.sh question <rule-tier> <compare-json>` prints the exact text
  `ask` sends.
- A spend ledger, the D1 table `jev_risk_calls`, keyed
  `(repo, pr, head_sha, question_version)`. `POST /api/jev-risk/claim` runs
  before every call, `POST /api/jev-risk/settle` after it, and `GET /api/jev-risk`
  lists rows. There are three outcomes. `ok` is a choice plus a probability.
  `empty` is a 2xx with no usable choice: it is billed and terminal. `failed` is a
  non-2xx, a timeout or a connection error, retried up to
  `jev_risk.max_attempts` (2) and then refused with `attempt_cap`. So a head
  that was answered `ok` or `empty` never reaches the vendor again. A settle
  names its claim's `attempts` and is fenced on it: a caller whose claim went
  stale and was reclaimed gets `409 superseded`, so it cannot overwrite the
  answer of the claim that replaced it. A curl failure is recorded as
  `curl rc <n>` (28 is a timeout, 7 a refused connection).
- A paid answer whose settle failed is kept in `state/jev-risk/` and settled
  from there on the next ask, with no second call.
- The shadow hook in `bin/lead-review-enqueue.sh` sits inside the BH-5022
  `risk` block. It runs only for a head classified in this tick, and only
  when `jev_risk.mode` reads exactly `shadow` (trimmed, any case). It calls
  `bin/jev-risk.sh ask` as its own process, bounded by `timeout`
  (`jev_risk.timeout_s` + 10 seconds), and logs
  `jev shadow <status> <tier> <prob> (rule tier <tier>)`. The tick summary
  gains `jev_shadow=<n>`. Jev's answer never changes the tier, the sign-off,
  the priority or the lead request. `jev_risk.max_per_tick` (3) caps the asks
  in one tick.
- The replay pilot: `docs/jev-pilot/replay.py` and `docs/jev-pilot/score.py`
  (new; no earlier copies existed anywhere). The decision rule is a constant in
  `score.py` (`MAX_BLOCK_LOW = 0.02`), committed before any data is read. Jev
  passes only if it calls a lead-BLOCK PR low less than 2% of the time, at or
  below the Haiku baseline's rate, and calls more lead-MERGE PRs low than Haiku
  does, all on the same rows. The Haiku baseline runs through
  `bin/agent-call.sh` with `AGENT_CALL_NO_TOOLS=1` and
  `AGENT_CALL_RUNNERS=claude`, so it answers from the question text alone, as
  Jev does; a refused call (rc 78) stops the run. Run commands are in
  `docs/jev-pilot/README.md`, and a five-PR probe (`--limit 5`, every Jev row
  `ok`, none `empty`) is the required first step.

## Rows

- `jev_risk.mode` = `off` (off | shadow). Seeded off.
- `jev_risk.model` = `jev-latest`, `jev_risk.max_per_tick` = `3`,
  `jev_risk.timeout_s` = `30`, `jev_risk.max_attempts` = `2`,
  `jev_risk.max_diff_chars` = `60000`.
- `jev_risk.api_url` is NOT seeded. This repo has no TypeSafe URL, so nothing
  calls the vendor until an operator sets the row.
- model_routes `jev-pilot.baseline` (hub) is the Haiku baseline the pilot
  resolves through `lane_model JEV_BASELINE_MODEL jev-pilot.baseline`. The seed
  copies model and runner from the hub `review.trivial` route rather than
  writing a model id literal (rules-pack model-id-delta), so it exists only
  where that route does.

## What is still owed, by an operator, after merge

1. Set `TYPESAFE_API_KEY` in the hub's `/etc/harness/env/global.env` and the
   `jev_risk.api_url` row. The TypeSafe request and response shape is an
   assumption: `jev_call` and `jev_parse` in `bin/jev-risk.sh` are the two
   functions to change if the vendor answers differently.
2. Run the pilot on the hub (README, "Real run") and post the score table and
   the `VERDICT:` line on #5024.
3. Only on a PASS, set `jev_risk.mode` to `shadow`. No code lets Jev lower a
   tier. A later wave that does so moves its gate row under the signed
   `risk_tier.` family.
