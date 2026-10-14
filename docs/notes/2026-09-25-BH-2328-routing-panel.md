# The Project page shows the routing row, its change log, and a HALT toggle

Doc: BUILDER-ROUTING

## What changed

BH-2328. The routing rows (`GET /api/routing/<p>`) and their audit trail
(`GET /api/routing-changes`, BH-2010) had no screen. `/p/<project>` now has a
ROUTING section at the top of its right column:

- The row: builder, pool app, halted, updated, and ROWS DRIVE ROUTING, read
  from the `routing_rows` setting (`on` / `off` / `unknown`; a missing row is
  the seeded `off`, a failed read is `unknown`, never `off`). The panel reads
  the settings row only. A box's `ROUTING_ROWS` env still overrides it on that
  box (`routing_rows_on` in `bin/lib/jobs/routing.sh`).
- A HALT toggle. It flips only `halted`: it re-reads the row, sends nothing
  if the row already says what was asked, and otherwise PUTs the fresh
  builder and pool_app with the new `halted`. It never creates a row and
  never edits builder or pool_app. It is disabled when there is no row, when
  `routing_rows` is not `on`, or when either read failed, because a HALT that
  stops nothing should not look like a working control.
- The change log: the newest 50 `routing_changes` rows in a sortable table,
  with a note when older ones exist.

## The write path

The coord proxy (`console-ui/functions/api/coord/[[path]].js`) now admits
exactly `PUT routing`. `routing/<p>`, `routing-changes` and every other verb
stay 405. Like the hub writes (BH-1946), the proxy stamps `actor: 'console'`
over whatever the browser sent and refuses a body that is not a JSON object
with 400. So every console routing change reads `console` in
`routing_changes`.

## What a HALT does, and for how long

With `routing_rows` on, each box's next routing sync writes
`flags/pool-halt-<p>` from the row, and `bin/fly-pool.sh` stops spawning
for that project. Builds already running keep going.
On a deploy, `bin/harness-sync.sh` removes each `flags/pool-halt-<p>` that
has no `.keep` file beside it and clears that row's `halted` (actor
`harness-sync`). So a console HALT lasts until an UNHALT, or until a deploy on
a box that already has the halt file, unless a `.keep` file holds it. The
dialog says a deploy clears it unless a `.keep` file holds the halt.
