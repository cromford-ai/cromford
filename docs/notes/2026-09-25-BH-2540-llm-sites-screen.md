# LLM sites screen: the contract slice (BH-2540 part 1, BH-2553)

Doc: LLM_CALL_SITES, CALL-GUARD

## Why

BH-2540 (gap C9) gives Mission Control one place to see LLM spend and gating per
site, where a site is one row of `catalog/llm-sites.json`. It is split five ways.
This slice is the seam the other four import. It ships the catalog module for
real and everything else as a stub. It changes no schema, adds no knob, makes no
LLM call and names no model id.

## What changed

- **`worker/jobs/src/lib/llm-sites-catalog.js`** (real, pure):
  - `LLM_SITES` is the bundled `catalog/llm-sites.json` `sites` array, imported
    the way `lib/core.js` imports `catalog/lanes.json`.
  - `parseSiteStages(stage)`: `"*"` gives `{all:true, stages:[]}`. Anything else
    is split on `|` and trimmed, and only plain stage names
    (`/^[a-z][a-z0-9._-]{0,63}$/`) are kept. Free text such as
    `"$COST_STAGE (default raw)"` or `"(none — no cost row)"` names no stage.
  - `siteAttribution(site, sites)` gives `{all, stages, lane, attribution, shared}`.
- **The attribution rule.** `lane` means rows match
  `stage IN stages AND (lane_id = lane OR lane_id IS NULL)`. That is the rule
  `GET /api/metrics/llm-spend` in `routes/cost.js` uses. It is restated, not
  imported, and `cost.js` is unchanged. `signature` means `stage IN stages` (a
  site with no lane, or `agent-call`'s `*`). `none` means no attributable stage,
  so no rows. A lane with no stage (`fly-builder-smoke`, `lane-probe`) is `none`.
  It never means every row on that lane, which would credit the whole build spend
  on `fly-pool` to a smoke probe.
- **`shared`** is true when another site lists one of the same stages, whatever
  its lane. A `*` site is never shared and never makes another site shared.
  Otherwise every site would be shared and the badge would say nothing.
- **Worker stubs**, both in the bearer `ROUTES` table (401 without it) at the end:
  - `GET /api/metrics/llm-sites` answers
    `{sites:[], windows:null, as_of, incomplete:['not-implemented']}`.
  - `GET /api/metrics/llm-sites/rows?site=<id>` answers 400
    `{error:'unknown site'}` for a missing or non-catalog id (exact match), and
    otherwise `{rows:[], truncated:false, incomplete:['not-implemented']}`.
- **The full payload the siblings build to** is the JSDoc block at the top of
  `worker/jobs/src/routes/llm-sites.js`. Money is null when absent, never 0.
- **Console:** `api.llmSites()` and `api.llmSiteRows(id)` read through the coord
  proxy. `/llm-sites` and `/llm-sites/:site` are routes with stub screens (title
  plus one empty line, no API call). They are not in NAV yet; the list sibling
  adds that entry.

## Tests

`worker/jobs/test/llm-sites-catalog.bh-2553.test.js`,
`console-ui/tests/llm-sites.bh-2553.test.js` and
`tests/llm-sites-contract.bh-2553-test.sh`.
