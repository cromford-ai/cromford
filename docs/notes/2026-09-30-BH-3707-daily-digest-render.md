# The daily digest renders now, and can carry one LLM paragraph (BH-3707)

Doc: ALERTS-STATE-MACHINE, MODEL-ROUTES

## What changed

BH-3707 (BH-3688.4, child 5 of 5) replaced the two contract stubs that
`bin/daily-digest.sh` calls. The signatures did not change.

- `dd_render` (`bin/lib/daily-digest-render.sh`) prints the digest. The
  sections come in this order: header, optional `Summary:`, Throughput, Spend,
  Autonomy (lead precision is part of it), Tripwires, Holds, PRs awaiting a
  human verdict, Model watch, Spot-checks, Factory stop. It returns 0. Every
  line with a number ends with the console URL it drills into, and every one
  of those URLs is a `console-ui/src/app.js` ROUTES path. A section with
  `ok:false` prints `n/a (read failed: …)`, never 0. Lists are cut at
  `DAILY_DIGEST_MAX_ITEMS` with `+N more`, and `<`, `>` and `&` are stripped.
  The spot-check sample is `lrl_spotcheck`'s own `cksum % 100 < pct`, copied
  as `dd_spotcheck_bucket`.
- `dd_summary` (`bin/lib/daily-digest-summary.sh`) is still off unless
  `DAILY_DIGEST_LLM_SUMMARY=1`. When it is on, it reads the jobs ledger row
  `daily_digest_summary/<sha256 of the digest JSON without as_of>` before any
  call:
  - `ok` reuses the stored text.
  - `empty`, `billed-failed` or any other status means no call.
  - An unreadable ledger means no call.
  Only a missing row calls `bin/agent-call.sh daily-digest fleet`. The model
  comes from `model_routes` `stage.daily-digest`, and only the claude runner
  is taken. The call is capped by `DAILY_DIGEST_LLM_MAX_USD`.
- The prompt is `catalog/prompts/daily-digest-summary.md`. The call site is
  `daily-digest-summary` in `catalog/llm-sites.json`, and its context budget
  is the `daily-digest` row in `catalog/context-budgets.json`.

## Why

Before this change, the lane sent nothing. Every tick hit the rc-3 stub
renderer and logged ` render-failed` (see the BH-3688 note, "Before #3707").
Now it sends the digest once a day.

## Operator notes

- To turn the paragraph on, set `lane.daily-digest.DAILY_DIGEST_LLM_SUMMARY=1`.
  It costs at most one call per distinct digest.
- The approve command under a model-watch row is built from the lib's own
  install root. On the hub that is `/root/harness/bin/model-watch-approve.sh`.
