# BH-7059 slice C0: the routes/cost.js history readers read the archive

Doc: none

## What changed

The inventory (`worker/jobs/test/archive-readers.d/bh-6779.json`) held six
`routes/cost.js` rows `pending`. This slice ports five of them onto
`worker/jobs/src/lib/archive-read.js`:

| inventory row | route | statement | archive state in the answer |
|---|---|---|---|
| `cost.js` rowSums | `GET /api/metrics/cost-anchored` | SUM per box and account | `archive` |
| `cost.js` span sums | `GET /api/metrics/cost-anchored` | SUM per metered account in its meter span | `archive` (worst of all reads) |
| `cost.js` lane statement (2 texts) | `GET /api/metrics/llm-spend?lane=` | one aggregate | `archive` |
| `cost.js` aggregate | `GET /api/metrics/llm-spend` | one aggregate | `archive` |

- The hot SQL text and binds do not change. Each read goes through
  `readHistory`. The archive answer is merged with `mergeAggregate` (sums) or
  `mergeGroups` (box x account groups, cap 500).
- The span reads reuse the rowSums reach. A cost-anchored request makes one
  archive MAX read at most.
- Each response has one new key, `archive`: `unbound`, `not-needed`, `read` or
  `unreadable`. A failed archive read gives the hot answer, HTTP 200 and
  `unreadable`. It is never thrown.
- `ARCHIVE` is unbound in prod until #6777 merges. Until then both routes
  answer as before, plus `"archive": "unbound"`, with 0 archive calls.
- The gate paths (`bin/lib/llm-gate.sh`, `bin/lib/budget-stop.sh`) ask for
  today. The console Costs screen asks for the 24h window. Those requests are
  inside the 1-day floor and make 0 archive calls.

Tests: `worker/jobs/test/archive-readers.bh-7059.test.js` (R2 same answer as
all-hot, R3 0 archive calls on the gate paths, R4 unbound equals main's SQL,
R5u unreadable, R6 EXPLAIN at `LIVE.cost_rows` archive volume uses
`idx_cost_rows_ts`).

## What is left

- `GET /api/metrics/cost-rows` (the page of rows): #6777 (BH-6774 C0) ports
  it in its own diff. The inventory row stays `pending` with slice
  `#6777 (BH-6774 C0)`.
- Scope 4 (the `stage_events_daily` archive rule) and R5 (its test) need
  `archiveCopy` and `ARCHIVE_TABLES` from #6777. They go to C1 of #7059.
  Blocked-by: #6777 (hard).
