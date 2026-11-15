# BH-9719: the meter skips and the cost_ceiling.<project> spend brake

Doc: COST, ACCOUNT-ROUTING

Slice C2 of #9676 (BH-9334 Fix 2).

## Why

A project with `claude_auth.<p>=api-key` pays per token with its own key. It has
no subscription session meter. Before this change the account-capacity count
still capped its build rule, and a box whose projects were all api-key polled a
meter it did not have, wrote `status=no-login` rows and raised a false
`EXTRA-USAGE METER DOWN` after 2h. No code read `cost_ceiling.<p>`.

## What changed

- New `bin/lib/meter-skip.sh`: `meter_skip_api_key <p>` (rc 0 only for a valid
  `api-key` row) and `meter_skip_log_once` (one log line per script, key and UTC
  day; state in `state/meter-skip/<script>-<key>.day`, one file per key).
- `bin/account-capacity.sh [vendor] [project]`: claude plus an api-key project
  answers `unlimited (...)`, reads no quota, logs once a day.
- `bin/concurrency-apply.sh`: asks account-capacity per pool project. Only an
  `unlimited` answer replaces the shared count for that row.
- `bin/extra-usage-track.sh`: skips the fallback login when every project on
  the box is api-key.
- `bin/lib/budget-stop.sh` `bs_pcap`: reads `cost_ceiling.<p>` too. The lower
  cap wins. The refusal line ends with `key=cost_ceiling.<p>` when that row set
  the cap.

## What did not change

- A project with no row or an `oauth` row: every output is byte-same.
- `bin/lib/project-ceiling.sh` (BH-7876), `bin/lib/llm-gate.sh`,
  `bin/lib/rb/gates.sh` and `bin/agent-call.sh` are not edited.
- No prod row is written. No new table.

## Tests

`tests/meter-skip.bh-9719-test.sh`, `tests/budget-stop-cost-ceiling.bh-9719-test.sh`.
