# The console reads the alerts table: a FLEET ROWS section on /alerts

Doc: ALERTS-GROOMING-SPEC

BH-1068 shipped the `alerts` table and the client wrappers. Nothing in the
console could see it: `/alerts` assembled its rows from each project's own
`/p/:project` payload, so the incident state the fleet's lanes write — family,
claim, count, `notified_at` — existed only in D1 and in TSV from
`bin/jobs-client.sh alerts`. BH-1072 is the read side of that table for a human.

## What changed

Three product files, all in `console-ui/`:

- `src/api.js` — `alerts(opts)`: `GET /api/coord/alerts` with `state`, `family`,
  `box`, `limit` set only when given. It goes through the existing Pages proxy
  (`functions/api/coord/[[path]].js`, untouched), which forwards any GET to the
  jobs worker with the harness bearer and the caller's `dash` session.
- `src/lib/alertrows.js` — new, pure, no DOM and no clock. `shapeAlertRows(payload, now)`
  takes the wire payload exactly as `GET /api/alerts` returns it
  (`{alerts, truncated, as_of}`) and hands back `{rows, truncated, asOf}`, each
  row carrying `ageMin` (from `first_seen`), `lastSeenMin`, `lane`/`laneBox`
  (`claimed_by` split on its FIRST `@`) and `stateRank`. `now` is a parameter so
  the screen reads the clock once per render and the tests can fix it.
  Also `ALERT_STATE_ORDER`, `alertSortValue` (what each column sorts on),
  `filterHref`/`familyHref`/`boxHref`/`stateHref`.
- `src/screens/Alerts.js` — `FleetRowsSection`, mounted under OPEN ALERTS. Ten
  columns in the shared `SortableTable` (id, family, box, project, state, count,
  first seen, last seen, claimed by, notified), family/box/state cells drilling
  into `?family=` / `?box=` / `?state=`, a chip per active filter whose CLEAR
  keeps the others, and the `truncated` note.

## Decisions worth keeping

- **The default query is `state=!resolved`, sent verbatim.** The section is a
  worklist, not an archive. The contract README documents `state=` without
  negation semantics, and the worker route that would honour `!` is a sibling
  slice of #1030 — if it turns out to match the string literally, the fix is in
  the worker, not in a client-side filter (the count on screen must describe the
  set the worker was asked for).
- **`limit=500` is a rendering bound, like `PIPELINE_SHIPPED_LIMIT`.** When it
  bites, the worker says `truncated: true` and the section's note reads
  "showing N of more" instead of a count that would be a lie.
- **Its own `useApi`.** Until the worker's `GET /api/alerts` deploys, that read
  answers 404 and this section renders `ErrorBox — http_404` with RETRY. The
  OPEN ALERTS table, the stat tiles and `resolve_alert` above it are unaffected.
  That is the honest state of the screen today, and it is what a reviewer will
  see on the deployed console before the worker sibling lands.
- **Read-only.** Nothing in this section writes; resolving stays the console's
  own `resolve_alert` action on the OPEN table.
- **Two empty copies.** With no filter: "no fleet rows yet — either the
  alerts-db flag is off or nothing has fired." Behind a filter that sentence
  would be false, so a filtered empty set says "no fleet rows match" and names
  the filters narrowing it.

## How to drive it

`docs/verification-map/entries/BH-1072.md`. The suite is
`console-ui/tests/alerts-rows.bh-1072.test.js` (`cd console-ui && npm test`),
which renders the real section markup — headers with `aria-sort`, the drill-down
hrefs, both empty copies, the error branch — over fixtures shaped exactly like
the contract's column list.
