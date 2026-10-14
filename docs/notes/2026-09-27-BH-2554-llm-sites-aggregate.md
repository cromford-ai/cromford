# GET /api/metrics/llm-sites answers one real row per LLM site

Doc: LLM_CALL_SITES, COST

## What changed

- `worker/jobs/src/routes/llm-sites.js` no longer answers the BH-2553 stub. It
  runs ONE constant GROUP BY over `cost_rows WHERE ts >= <now-7d>`, grouped by
  `stage, lane_id, runner, billing_mode`, and one read of the settings rows
  `lane.%.llm_%` and `lib.call-guard.%`. It answers
  `{sites, windows:{since_7d, since_24h, today}, as_of, incomplete}` with one
  entry per `catalog/llm-sites.json` site, in catalog order, in the shape the
  route's header comment documents. It writes nothing.
- `worker/jobs/src/lib/llm-sites.js` (new, pure) turns the groups, the settings
  rows, the baked-in `LANES_REGISTRY` and `catalog/context-budgets.json` into
  those rows.

## Rules the route applies

- Rows per site come from `siteAttribution()`: a `lane` site counts its stages'
  rows stamped with its lane or with no lane; a `signature` site counts its
  stages' rows; the `*` site (`agent-call`) counts every row and is the only
  fleet total; a `none` site counts nothing and its money fields are `null`.
  An attributed site with no rows is a measured `0` / `{by_runner:{}, total:0}`.
- Money is summed from priced rows only. An unpriced row (`cost_usd` NULL) adds
  1 to `unpriced_7d` and nothing to `by_runner`. `cash_7d` is
  `billing_mode='metered'`, `notional_7d` is `'subscription'`, and
  `unknown_billing_7d` is everything else, NULL included. `today_usd` is since
  UTC midnight.
- Refusal classes: `gate` is a `row_source='refused'` row whose note does not
  start `refused:call-guard` (a NULL note counts as gate); `guard` is a note
  starting `refused:call-guard`; `context_kill` is a note containing
  `context-kill:` or `cliff-avoided:`.
- A settings row with actor `registry-seed` is the default, not an operator
  value, the same rule `routes/lanes.js` applies. `guard_k`, `guard_enforced`
  and `cap_usd_day` read the non-seed row, else the registry default.
  `knobs_bound` lists the lane's `LLM_*` knobs that have a non-seed row.
- `kill_tokens` is the smallest positive `context_kill_tokens` among the
  project-less `context-budgets.json` entries for the site's stages, else
  `null` (badge `no_kill`).

## Failure semantics

- The aggregate failing is the only 500 (`{"error":"llm-sites aggregate failed"}`).
- The settings read failing answers 200 with `guard_k`, `guard_enforced`,
  `cap_usd_day` and `knobs_bound` all `null` and `"settings"` in `incomplete`.
- An operator `call_guard_max_map` row with a token that is not `stage=K`, or
  an operator `llm_usd_cap_day` row that is not a number, answers the registry
  default and names `guard_k` / `cap_usd_day` in `incomplete`.

## Drift noted

The ticket cites `_ctx_kill_ceiling` at `bin/agent-call.sh:1106-1127`; it now
sits at 1143+ and also honours `lib.context-kill.*` settings rows. This route
follows the ticket's rule (project-less entries, min over matching stages) and
does not read those rows.

Tests: `worker/jobs/test/llm-sites.bh-2554.test.js`, run by
`tests/llm-sites-aggregate.bh-2554-test.sh`.
