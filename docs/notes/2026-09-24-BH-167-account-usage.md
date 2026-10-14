# Account usage contract: `GET /api/metrics/account-usage` answers a stub shape

Doc: COST

## What changed

BH-1913 (BH-167.0, part 1 of 4 of #167). This is the contract the three #167
siblings build against: the worker compute, the lane alert and the console section.

- `worker/jobs/src/lib/account-usage.js` (new) exports three things:
  - `usageWindow({window, now})`, which is real.
  - `shapeAccountUsage(...)`, which is a stub.
  - `EMPTY_TRUNCATED`.
- `worker/jobs/src/routes/usage.js` gains `GET /api/metrics/account-usage?window=5h|7d`.
  It uses the same bearer as every other `/api/*` route. In this slice it answers
  `accounts: []` from the stub and reads nothing: no `cost_rows`, no
  `extra_usage_snapshots`, no DB statement at all.

## Response shape

Top level:

    { window, from, to,
      accounts: [ <entry> ... ],
      totals: { calls, usd, unpriced_calls, input_toks, output_toks, cache_read, cache_write },
      truncated: { groups, projects, snapshots } }

Today the stub answers `accounts: []`, `totals` all zero except `usd: null`, and
every `truncated` flag `false`. `usd` is null when nothing is priced, never 0.

Each account entry (the JSDoc `AccountUsageEntry` in `account-usage.js` is the
source of truth) has these fields:

- `account` (string or null) and `calls`
- `usd`: null when every row is unpriced, never 0
- `unpriced_calls`, `input_toks`, `output_toks`, `cache_read`, `cache_write`, `untokened_calls`
- `first_ts`, `last_ts`
- `projects[]`: `{project, calls, usd, unpriced_calls, input_toks, output_toks, cache_read, cache_write}`
- `meter`: `{label, session_pct, weekly_pct, weekly_resets_at, extra_used_usd, polls}` or null
- `cross_check`, in one of two variants:
  - `{state:'comparable', meter_delta_usd, rows_usd, unpriced_in_span, gap_usd, gap_pct, span_from, span_to}`
  - `{state:'no-login'|'unmeasured', reason}`, which carries no gap keys

## Rolling-window assumption

Windows trail the request time. They are not aligned to the vendor's reset
boundaries.

- `5h` is [now-5h, now) and `7d` is [now-168h, now). Both are half-open.
- `from` and `to` use the worker's `YYYY-MM-DDTHH:MM:SSZ` shape, so they compare
  as strings against `cost_rows.ts`.
- Any other `window` value (absent, empty, `7D`, `30d`) resolves to `5h`. The
  resolved window is echoed in `window`, so a caller can see the fallback.
