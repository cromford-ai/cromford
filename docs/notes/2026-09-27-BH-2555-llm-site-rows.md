# LLM sites: the drill route answers real cost rows (BH-2540 part 3, BH-2555)

Doc: LLM_CALL_SITES

## What changed

`GET /api/metrics/llm-sites/rows?site=<id>` (worker/jobs/src/routes/llm-site-rows.js)
was a stub answering `{rows:[], truncated:false, incomplete:['not-implemented']}`.
It now reads `cost_rows`, read-only:

- An unknown, missing or case-variant `?site=` is still 400 `{error:'unknown site'}`.
- The site's rows come from `siteAttribution()` in `lib/llm-sites-catalog.js`:
  `lane` is `stage IN (...) AND (lane_id = lane OR lane_id IS NULL)`, `signature`
  is `stage IN (...)`, and `*` (agent-call) is every stage. A site with no
  attributable stage answers `{site, rows:[], truncated:false, reason:'no-stage',
  incomplete:[]}` without reading the table.
- Only rows with `ts` in the last 7 days (rolling, from the request clock), newest
  first, at most 200. `truncated` is true when 200 came back.
- `site` is the full catalog record. `cost_usd` passes through as stored, so a
  NULL cost stays null.
- Every value is a bound parameter.

## Why

The LLM Sites screen drills from a site's row to the cost rows behind its numbers.
The 7-day window and the 200 cap are fixed by the ticket; they are constants in
the route, not settings rows.

Tests: `worker/jobs/test/llm-site-rows.bh-2540.test.js`.
