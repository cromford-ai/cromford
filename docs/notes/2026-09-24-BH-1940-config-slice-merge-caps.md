# Merge/review and lane-caps knobs move into the registry

Doc: OPERATOR-SETUP

## What changed

BH-1940 is the merge/review and lane-caps slice of BH-1511. Eight knobs lost
their `${VAR:-literal}` default. Each one is now a registry knob with
`required: true` and a default equal to the literal it replaced, so nothing
changes on a box until someone writes a row.

| knob | where it's read | default | settings key |
|---|---|---|---|
| BR_MAX_REGEN | bin/blocked-resolver.sh | 1 | `lane.blocked-resolver.br_max_regen` |
| RESCUE_PER_TICK | bin/review-rescue.sh | 3 | `lane.review-rescue.rescue_per_tick` |
| RESCUE_PARALLEL | bin/review-rescue.sh | 0 (unlimited) | `lane.review-rescue.rescue_parallel` |
| PR_MERGE_REST | bin/lib/gh-pr-merge.sh | 1 | `lib.gh-pr-merge.pr_merge_rest` |
| RP_RAW_CAP | bin/lib/review-post.sh | 20000 | `lib.review-post.rp_raw_cap` |
| RP_TEXT_CAP | bin/lib/review-post.sh | 55000 | `lib.review-post.rp_text_cap` |
| LANE_CAPS_SCAN | bin/lib/lane-caps.sh | 4000 | `lib.lane-caps.lane_caps_scan` |
| LANE_CAPS_PRICE_MAX | bin/lib/lane-caps.sh | 500 | `lib.lane-caps.lane_caps_price_max` |

The lane knobs live in `catalog/lanes.d/blocked-resolver.json` and
`catalog/lanes.d/review-rescue.json`. The lib knobs are in three new files:
`_lib.gh-pr-merge.json`, `_lib.review-post.json` and `_lib.lane-caps.json`.
`_lib.json` is untouched.

The value resolves operator row > cached row > env > registry default > fail
closed, through `bin/lib/lane-gate.sh`. The two lanes already ran
`lane_env_apply`. The three libs now call `lib_env_apply` themselves
(`_gpm_knobs`, `_rp_knobs`, `_lc_knobs`) inside a subshell. If one fails
closed, it writes its one ALERTS line a day and the merge, review or cap lane
that sourced it keeps running. Each resolves once per process for each env
value.

## What answers when the contract never ran

Plenty of suites run these files in a scratch tree with no lane-gate.sh or no
rendered registry. On a real box a required knob always arrives set, or the
lane exits 75 first. So these fallbacks only answer in a scratch tree, or on a
box whose sync landed the file before its registry:

- blocked-resolver keeps its existing sanitizer, and an empty value is 1.
- review-rescue has a new sanitizer for RESCUE_PER_TICK (empty or not a number
  is 3), next to the existing one for RESCUE_PARALLEL (0).
- review-post and lane-caps read the default out of their own checkout's
  `_lib.<id>.json`. That's the same thing `verdict_window` does.
- If lane-caps still can't resolve, it writes one line to its lane log, reads
  the whole ledger and prices every blank row. Both knobs only bound the cost
  of the read, so an unresolved bound means a slower read, never a lower total.
  A $0.00 here would mean the daily cap never fires on a box whose sync landed
  the lib before its registry file (`tests/triage-session-cap-zero.bh-1164-test.sh`
  C4 went red on exactly that).
- gh-pr-merge leaves the REST ladder on. Only `0` has ever turned it off.

## Not config, not registered

- `COST` in lane-caps.sh is a box-layout path (`$_LC_H/logs/cost.csv`).
- `LANE_CAPS_DAY` is a computed default (`$(date …)`) and a test seam.
- `LANE_CAPS_CONF` is a test hook, `${…:-}`.
- `RESCUE_ONLY` is an emptiness test for a manual run, `${…:-}`.

Suite: `tests/config-slice-merge-caps.bh-1940-test.sh`.
