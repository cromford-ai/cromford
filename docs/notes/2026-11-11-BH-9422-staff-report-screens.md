# Staff lever scoreboard: weekly report, Archie briefing, /staff screens (BH-9422, C4 of BH-9187)

Doc: DB-COORDINATION-SPEC

## Why

BH-9187 judges every staff agent by whether its one metric moved. C0
(BH-9389) stored the ledger and served one agent's scorecard. This slice shows
that scorecard in four places: the weekly overlook report, Archie's turn
briefing, the Mission Control `/staff` page and `/staff/<agent>`. It adds no
table and no lever.

## What changed

### Worker

- `worker/jobs/src/routes/staff-levers.js`: the scorecard math is now the
  exported `scorecardOf(env, name, byKey, days, t, metricOverride)`, and the
  window rule is `daysOf(byKey, dq)`. `GET /api/staff/levers/scorecard` calls
  both. Its answer is unchanged (the BH-9187 L1-L6 cases pin it). No SQL text
  changed.
- `GET /api/staff/levers/scoreboard[?days=n]` (new,
  `worker/jobs/src/routes/staff-scoreboard.js`): `{ok, days, as_of, agents}`,
  one `scorecardOf` answer per `staff_agents` row except archie, ordered by
  name. The roster read and the settings read run in parallel, then every
  agent's three indexed reads run in one `Promise.all` (8 agents: 2 + 24
  statements). The window is the row `staff.scorecard_days` (7), capped by
  `staff.scorecard_days_max` (30).

### Weekly overlook report (`bin/archie-overlook.sh`)

One scoreboard read per weekly run. Under each agent line:

    - inspector: filed 1, digested 0, precision 100% (1 of 1), spend $0.40
      metric: hours_behind_main now 3 (7d ago 41), target 2, level observe; actions 2, moved 1 of 2 settled, precision 50%

The agent line does not change, so spend stays in the report. A failed read
holds nothing: the report gets one line `staff metrics unreadable (<reason>)`
and no metric line.

### Archie's turn briefing (`bin/orchestrate.sh` compose_v2_prompt)

A `=== STAFF METRICS (lever scorecards, 7d window) ===` section between REPO
ACTIVITY and RECENT CONVERSATION, one `- <agent>: <line>` per staff agent. One
request, timeout `ARCHIE_STAFF_METRICS_TIMEOUT_S` (default 5 s, settings row
`lane.archie.archie_staff_metrics_timeout_s`), no retry. A failed read is one
`UNREADABLE staff scoreboard (<reason>)` line; the turn goes on.

The shared helpers are in `bin/lib/staff-scoreboard.sh`.

### Mission Control

- `/staff`: a METRICS section under ROSTER. A sortable table: AGENT (links
  `/staff/<name>`), METRIC, TARGET, LEVEL, NOW, `<days>D AGO`, ACTIONS,
  SETTLED, MOVED, PRECISION.
- `/staff/<agent>`: a METRIC section after the facts list. `/staff/archie` has
  none.
- Reads: `console-ui/src/lib/staff-scores.js` (its own GET; `api.js` is not
  touched).

## Two precisions

The report's agent line and the roster's PRECISION column are ISSUE-verdict
precision (BH-5562, BH-5563): closed staff issues completed vs not planned.
The new value is LEVER precision: moved / settled lever actions in the window.
The report says `precision` on the metric line; the screens carry a legend.
A null lever precision (0 settled) prints `n/a`, never `0%`. A missing sample
prints `no sample`, never `0`.

## Tests

- `worker/jobs/test/staff-scoreboard.bh-9422.test.js` (B1-B6, with EXPLAIN on
  seeded data)
- `console-ui/tests/staff-metrics.bh-9422.test.js` (M1-M8)
- `tests/staff-scoreboard.bh-9422-test.sh` (S1-S4, W1-W3, P1-P2)
