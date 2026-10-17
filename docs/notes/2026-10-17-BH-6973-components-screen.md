# Mission Control shows components, their open alerts and the watcher's decisions (BH-6973)

Doc: CONSOLE, console-ui/README.md

**What changed.** The console has a Components screen at `/components`. It is a sortable table with
one row per component that holds an open alert. The columns are OPEN, LAST RUN, DECISIONS 24H and
TICKETS. The ALERTS tab stays lit on it, and the Alerts screen has a `COMPONENTS →` crumb to it.

| column | source | rule |
|---|---|---|
| COMPONENT | `GET /api/alerts?state=!resolved&limit=500` | the distinct non-null `component` values; a NULL is "not stamped yet" and is counted in a note, not a row |
| OPEN | `GET /api/alerts?component=<c>&state=!resolved&limit=500` | the row count; `500+` when the worker says `truncated` |
| LAST RUN | `GET /api/alerts/decisions?component=<c>&limit=200` | the newest parsable `at` |
| DECISIONS 24H | the same read | rows with `at` inside the last 24 h; `200+` only when the read is `truncated` AND its oldest row is still inside the 24 h |
| TICKETS | the same read | rows with verdict `ticket` and a non-null `issue`; `N+` when the read is `truncated` |

A failed per-component read shows `—` with the error in the cell title, never `0`. A failed name
read shows the error with RETRY, never "no component".

**Reads.** One name read, then one `Promise.all` with two reads per component: 1 + 2N GETs per
open, no polling (REFRESH reloads). Each read is bounded (500 / 200) and uses an existing index
(`idx_alerts_state`, `idx_alerts_component`, `idx_alert_decisions_component`).

**Alerts filter.** `/alerts?component=<c>` passes `component` to `GET /api/alerts`, shows a
`component=<c>` chip with CLEAR, and adds a DECISIONS link per FLEET ROWS row. Without the filter
the Alerts screen is unchanged.

**Decisions screen.** `/alerts/decisions/<id>` reads `GET /api/alerts/decisions?alert_id=<id>&limit=200`
and lists AT, VERDICT, OUTCOME, ISSUE (a link to `/t/BH-<n>`), RUN and REASON.

Files: `console-ui/src/lib/components.js`, `console-ui/src/screens/Components.js`,
`console-ui/src/screens/Alerts.js`, `console-ui/src/lib/alertrows.js`, `console-ui/src/api.js`,
`console-ui/src/app.js`. Tests: `console-ui/tests/components-screen.bh-6973.test.js`,
`tests/components-console.bh-6973-test.sh`.
