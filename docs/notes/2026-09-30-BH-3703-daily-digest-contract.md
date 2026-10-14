# The daily-digest contract: signatures, stubs, seeds and fixtures (BH-3703)

Doc: MODEL-ROUTES, CONFIG

## What changed

BH-3688 (the daily Telegram digest) is split into five slices. This is slice 1,
the interface the other four build against. It adds signatures and stubs that
answer "not built yet", two schema seeds and the two canonical fixtures. It adds
no section SQL, no rendering and no lane.

- `worker/jobs/src/lib/daily-digest/shape.js` (pure, no clock):
  - `dayWindow(day, nowIso)` returns `{day, from, to}` as `[day, day+1)` in UTC,
    or null for a malformed day, an unreal date (`2026-02-29`) or a day after
    `nowIso`'s date. Today is allowed.
  - `capList(rows, limit)` returns `{rows, truncated}`. A non-array throws.
  - `isEmptyDigest(d)` is true only when all nine sections are `ok:true` and
    every counter the ticket lists is a number `=== 0`. An absent counter or
    `"0"` is not zero.
  - `notBuilt()` returns `{ok:false, error:"not built yet (BH-3688)"}`.
  - `SECTION_KEYS` lists the nine sections split by reader, and
    `guardSections(keys, fn)` runs one reader. A throw makes each of its keys
    `{ok:false, error}`, and a key it left out is
    `{ok:false, error:"section missing from reader"}`.
- `readCoreSections(db, win, opts)` (`core-sections.js`) and
  `readStateSections(db, win, opts)` (`state-sections.js`) are stubs. #3704 and
  #3705 replace their bodies and keep the signature.
- `GET /api/metrics/daily-digest?day=YYYY-MM-DD[&limit=&loop_min=&trip=&human=]`
  (`routes/daily-digest.js`, spread after `...costBreakdown` in `index.js`,
  route-table fragment `650-daily-digest.txt`). It is read-only.
  - `limit` is 1..100 (default 20), `loop_min` 2..20 (default 2) and `trip`
    1..100 (default 2). `human` is a comma list, trimmed and lowercased, with at
    most 20 names of at most 128 chars.
  - Any explicit value out of range is a 400 with `{error}`. Nothing is clamped.
  - It answers `{day, from, to, as_of, empty, throughput, spend, autonomy,
    tripwires, holds, human_verdict_prs, model_watch, spotcheck_candidates,
    factory}`. Today every section is `notBuilt()`, so `empty` is false.
- `schema.sql` seeds, `INSERT OR IGNORE`, one statement each:
  - settings `lane.daily-digest.daily_digest_send_hour_utc` = `7`.
  - model_routes role `stage.daily-digest` rung 0, copied from `stage.execute`
    rung 0 on the claude runner behind both `NOT EXISTS` guards, the same way
    `stage.lookback` is seeded. It adds no model literal.
- `bin/lib/daily-digest-render.sh`:
  `dd_render <json-file> <console-base> <lead-precision-file|-> <spotcheck-pct> <max-items> <summary-file|->`.
  The stub prints nothing on stdout and returns 3 (2 with fewer than 6 args).
  It reads no env.
- `bin/lib/daily-digest-summary.sh`: `dd_summary <json-file> <out-file>`. It
  reads `${DAILY_DIGEST_LLM_SUMMARY:-0}` and `${DAILY_DIGEST_LLM_MAX_USD:-0.10}`
  because #3706 registers both with `read_in` this file. The stub writes
  nothing, makes no call and returns 1. #3707 fills both shell bodies.
- `tests/fixtures/daily-digest/fixture-day.json` and `empty-day.json` are the
  written shape of the route's answer, and the render and lane suites read them.
  The parent plan's "Route response" block was not on the building box, so the
  row fields were assembled from the names the sibling tickets quote. A sibling
  that needs a different field changes both fixtures together. Two row shapes
  are pinned by #3705's own text, and F2 checks their exact keys:
  - `model_watch.rows[]` is `{vendor, model_id, suggestion}`. The read keeps
    only `status='suggested'` rows, so there is no `status` field. An empty
    `suggestion` means the renderer prints no approve command.
  - `spotcheck_candidates.rows[]` is `{repo, pr, head_sha, project}`. The
    renderer's `dd_spotcheck_bucket <repo> <pr> <head>` takes `head_sha`, so
    a renderer that reads `.head` hashes an empty head and samples the wrong set.
  `tests/daily-digest-contract.bh-3703-test.sh` and
  `worker/jobs/test/daily-digest.bh-3703.test.js` hold the two files to one
  shape.

## Why

The four other slices (#3704 core sections, #3705 state sections, #3706 lane,
#3707 render and summary) are each hard-blocked on this one. Freezing the
signatures and the fixture shape first lets them build in parallel without
touching each other's files.
