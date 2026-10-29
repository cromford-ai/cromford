# BH-7876: a daily spend ceiling per project

Doc: COST

## What changed

A project can now have a daily spend ceiling. The fleet ceiling
(`conf.cost-caps.ceiling`) is one number for all projects, so one busy project
could spend the whole fleet budget. A project's pool cap is raised only with a
ceiling of its own.

- Key: the settings row `conf.cost-caps.<project>.daily_usd` = `<usd>` (a
  `.<box>` suffix for one box; the box row wins). Fallback: a
  `daily <project> <usd>` line in `catalog/cost-caps.conf` or
  `flags/cost-caps.conf`. `bin/lib/cost-budget.sh` `cost_budget_daily` resolves
  it. A value that is not a positive number binds nothing and is named
  `row:<project>.daily_usd` in `cost_budget_legacy_rows`.
- Seeded values (the operator, ticket comment 6326016557): `catalog/cost-caps.conf`
  ships `daily project-6-os 5000` and `ceiling 10000`, and
  `bin/cost-caps-seed.sh` seeds them as the `registry-seed` rows
  `conf.cost-caps.project-6-os.daily_usd = 5000` and
  `conf.cost-caps.ceiling = 10000` (POST /api/cost-caps/seed; the worker's
  `capFleetKey` accepts the daily key). An operator row still wins. The code
  default fleet ceiling stays 4000 for a box with no file and no row.
- Warn point: `conf.cost-caps.daily_warn_pct` (or `daily_warn_pct <n>`),
  1 to 100, default 80 (`COST_BUDGET_DEFAULT_DAILY_WARN_PCT`).
- Spend: the project's `cost_rows` for the worker's current UTC day, through
  `GET /api/metrics/llm-spend?project=<p>` (the same read as `_bs_spend`).
- `bin/lib/project-ceiling.sh` (new) decides `under`, `warn` or `over`. It
  raises one alert per project per UTC day at the warn point
  (`project-ceiling-warn-<p>-<yyyymmdd>`) and one at 100%
  (`project-ceiling-over-<p>-<yyyymmdd>`). The over alert claims the warn flag,
  so no warn follows it on the same day. Each alert names the project, the
  spend and the ceiling.
- `bin/lib/rb/gates.sh` budget launch gate: at 100% a new non-hotfix build
  ends `BUILD_DEFERRED budget-project-day project-ceiling project=<p>
  usd=<spent>/<ceiling> …` (exit 3, no ADMITTED). `pool_lane_failure` reads
  ` budget-project-day ` as the lane's condition, so the pool requeues it
  uncounted. A hotfix starts and gets one pipeline.log line. A resume of an
  admitted build is not checked. A spend that cannot be read defers a
  non-hotfix build (`BUILD_DEFERRED budget-cap-unreadable launch
  project-ceiling-unreadable:<p>`), the same as the BH-4489 check.
- `bin/agent-call.sh` block `# >>> project ceiling note`: before a paid
  `plan`, `execute`, `review` or `lead-review` call, the same check raises the
  day's alerts. It never refuses a call: running builds finish.
- Console `/costs`: a DAILY CEILINGS table under CAPS (project, ceiling,
  today's spend, percent, state). It uses the CAPS settings read and reads
  each ceiling project's spend in one `Promise.all`. A failed spend read shows
  `unknown`, not $0. Display only: set a ceiling with
  `bin/jobs-client.sh setting-set conf.cost-caps.<p>.daily_usd <usd>`.
- MCP `project_status`: four GETs in parallel (the dash route, the ceiling
  row, the warn row, the spend) and a `spend_ceiling` block
  `{project, ceiling_usd, spent_usd_today, pct, state, as_of}`. No row is
  `state: 'none'`; a failed sub-read is `state: 'unknown'` with `error`. It
  shows the fleet row only, not a box row.

A project with no ceiling row or line has no ceiling. Nothing reads its spend,
and it behaves as before.

## Why

Ticket BH-7876. In September one account spent 21.9K USD of its 25K USD cap in
14 days. project-6-os is armed by the row `conf.cost-caps.project-6-os.daily_usd
= 5000`, which existed before this change and was read by no code.

## Not changed

BH-4489's `budget.project.<p>.day_usd` (bin/lib/budget-stop.sh) is a
different cap: it refuses calls and has no hotfix exemption. It is not read
here. The global slot allocator is a separate ticket.

## Kill switch

`lane_switch project-ceiling-off` (row `switch.project-ceiling-off`, else the
file `flags/project-ceiling-off`) turns the check off: no read, no alert, no
refusal.
