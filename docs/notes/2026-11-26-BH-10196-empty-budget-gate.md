# 2026-11-26 BH-10196: no timed GET on an empty GitHub budget; pr-owner-sweep lists from the record

Doc: GH-REST

## What changed

- `bin/lib/gh-rest-empty.sh` (new) holds the empty-budget rule. `_gh_quota_gate`
  in `bin/lib/gh-rest-ledger.sh` now gets the method from `gh_rest` and asks the
  rule first.
- The rule refuses a `GET` when all of these are true:
  - the shell is a timed lane run: `LANE_GATE_RUN` is set and `WAKE_LAUNCH` is not `1`;
  - the per-lane switch is on;
  - the reading `state/gh-rest-ledger/.quota-<bucket>` of the bucket this call
    spends says remaining `0`, with a reset that is still in the future.
- A refusal is rc 75 with `GH_REST_REASON=quota-reserve` (the word callers
  already treat like a rate limit). No request is sent and no ledger row is
  written. GitHub would have answered 403 to the same call.
- One line goes to `logs/gh-rate.log` per lane, process and reset window:
  `[gh-empty-budget] lane=<id> bucket=<bucket> core remaining 0 until <reset>: GET refused before the request (no ledger row), pid <pid>`.
  The marker `state/gh-rest-ledger/.empty-said.<lane>.<pid>` dedupes it. Markers
  older than `GH_LEDGER_TTL_H` hours (fallback 48) are removed.
- Not refused: `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`; a wake-started run; a
  shell outside a lane; an unknown reading (no file, torn file, no reset, a
  reset that has passed).

## The switch

- Settings row `lane.<id>.gh_rest_empty_budget_gate`. The values `0`, `false`,
  `off` and `no` (any case) turn the rule off for that lane. No row means on.
- The env `GH_REST_EMPTY_BUDGET_GATE` wins over the row for one run.
- No seed row ships. The default is on for every lane.

## The lanes stop at the first refusal

Each lane calls `gh_rest_budget_empty <path>` before an item. When it answers
yes, the lane stops the tick, exits 0, and writes none of its post-loop state.

- `bin/pr-owner-sweep.sh`: before each repo and before each PR in the hooks
  loop. Line `GitHub core budget empty — tick stopped …`. The health flush,
  the ownerless clock and the keyed conductor spawn do not run.
- `bin/unblock.sh`: before collect and after the ticket-PR enrich. Line
  `tick <p>: GitHub core budget empty — tick stopped …`. Rules, the
  unreadable-tick counter, decisions and the card sweep do not run. The lane
  now sources `bin/lib/gh-rest.sh` at start, so the check exists before collect.
- `bin/blocked-resolver.sh`: at tick start (line `GitHub core budget empty —
  tick stopped before discovery …`) and before each candidate (tick line
  `reason=gh-budget-empty`). The hand-off sweep does not run on that reason,
  and the saturation streak is left as it is (not reset to 0). A `--fix-here`
  round and the dispatcher are not checked at start.

## pr-owner-sweep: the record first

`po_lists_record` used to miss with `miss=floor` whenever its last GitHub list
read was older than `PR_OWNER_LIST_GITHUB_FLOOR_S` (3600 s) or absent. That
forced about 2 GraphQL list calls per repo per hour. Now the floor is a miss
only when the record's open list holds a row whose `mergeable_state` is unknown
(null, `unknown`, `draft`, or a value outside `dirty`, `clean`, `blocked`,
`behind`, `unstable`, `has_hooks`). The floor exists for that gap. A record
whose open rows are all known is used with no GitHub list read.
`PR_OWNER_LIST_GITHUB_FLOOR_S=0` still turns the record tier off.

## Owed on the hub

After 24 hours: the refused rows per hour for the 3 lanes, and
`bin/gh-ledger-report.sh --per-merged-pr --by-repo --last 24h`, posted on #10196.
