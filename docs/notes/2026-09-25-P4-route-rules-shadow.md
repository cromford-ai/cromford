# P4: plan-driven model routing, recorded in shadow

Doc: ROUTE-RULES, MODEL-ROUTES

## What changed

- Three D1 tables (`route_rules`, `route_rule_changes`, `route_shadow`) and their
  routes (`worker/jobs/src/routes/route-rules.js`). Four seeded rules, all
  `mode: shadow`: `risk-surface`, `docs-tests-copy`, `specified-small`,
  `bounce-escalate`. The worker refuses `mode: live`.
- A new `model_routes` role, `build.execute.lite` (Sonnet 5), named by the two
  cheap rules and read by nothing live.
- `bin/lib/route-rules.sh`: plan features from the build's artifacts, the rule
  evaluation, the would-be model through `model_routes`, and the shadow record.
- `bin/lib/review-tier.sh` gains `review_tier_files`, the same classifier over
  a path list (the planned files), and `review_tier` now calls the shared body.
- `bin/run-build.sh`: one `# >>> route shadow` block before `rb_execute`, run
  as its own process, output discarded. Log only.
- `bin/route-shadow-report.sh`, hub lane `route-shadow-report`, daily 06:15Z.

## Why

Everything runs on Opus 5.5 today, and nothing says which builds a cheaper
execute model could have carried. The design the operator approved on 2026-09-25 picks
the model from the plan's structure, never downshifts the reviewer, and escalates
on measured failure. This slice measures that design against real builds before
anything routes on it.

## How to read it

`bin/jobs-client.sh route-shadow` for the rows, `state/route-shadow/latest.txt`
on the hub for the nightly summary, `$BUILD/route-shadow.json` per build.
Kill switch: `ROUTE_SHADOW=0` or `flags/route-shadow-off`.
