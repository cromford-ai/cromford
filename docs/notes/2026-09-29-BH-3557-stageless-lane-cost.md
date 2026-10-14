# Stage-less lanes report no cost; the fleet's spend moves to /costs SPEND BREAKDOWN (BH-3557)

Doc: COST

## What changed

- `GET /api/lanes/status`: a lane with no `stats.cost_stage` and no
  `stats.cost_project_filter` now reports `runs_today`, `cost_today` and
  `cost_7d` as `null`, `cost_rows` as `[]` and `cost_attribution: "none"`.
  Before, its ownership rule matched every cost row, so 91 of 111 lanes each
  showed the whole fleet's spend (or a project's, on a project tab). A
  filter-only lane (none exist today) keeps its sum and reports `"lane"`.
- Settings renders `—` plus "no model cost of its own" on those lanes, keyed on
  the API's `cost_attribution`, and links to /costs.
- New `GET /api/metrics/cost-breakdown` (`worker/jobs/src/routes/cost-breakdown.js`):
  `since`/`until` (ISO UTC; default today's UTC midnight → now), `group` = 1-2
  of `project,stage,runner,model,billing_mode,ticket` or `rows`, filters on the
  same six names where `k=` (present, empty) means IS NULL. Groups cap at 500,
  rows at `limit` 1..500 (default 200, out-of-range is a 400), each with a
  `truncated` flag; the `total` is a separate read and is exact. `cash_usd` is
  metered rows only, `equiv_usd` subscription rows only, so unknown-mode dollars
  count in `usd` and in neither.
- /costs gains SPEND BREAKDOWN directly under the spend headline, drillable
  down to each cost row's build or job.
