# A project save now guards against the hub moving, and the ladders nobody could see are on screen

Doc: MODEL-ROUTES

Four follow-ups from the round-2 review of #1560 (the MODELS console).

## The hub-drift guard

`GET /api/model-routes/:role?project=p` answered `scope_version` for the scope
the read NAMES. For a project with no override that is 0, and 0 never changes,
so a project-tab save that was *creating* an override from the inherited hub
ladder carried a guard that could not fail. Two tabs open on the same role, one
editing the hub and one creating the override, and the override silently landed
on top of a ladder its operator never saw.

The read now also carries `hub_scope_version`, always (on a hub read it is the
same number as `scope_version`). The PUT accepts `expected_hub_version`, checked
at read time AND as a second `versionGuard` statement inside the same D1 batch
as the project one — a read-time check alone still loses to a hub write that
commits in the window, which is the interleaving the #1560 fix round already had
to close once for the project scope.

Three deliberate narrownesses:

- **Project PUT only.** `expected_hub_version` on a hub write, or on a reset, is
  a **400**, not an ignored field. A caller that sent it to the wrong verb would
  otherwise believe it was guarded and not be.
- **Sent only on an inherited ladder.** `console-ui/src/lib/models.js` adds the
  field when `project && source !== 'project'`. A project that already owns its
  ladder sends its own version alone: a hub edit does not touch what it is
  editing, and guarding on it would refuse saves for a change that cannot affect
  them.
- **The 409 says which scope moved.** The body is `{error, scope_version,
  hub_scope_version, stale}` with `stale` one of `project` / `hub` / `both`,
  computed by re-reading both versions. `console-ui/src/api.js` now hangs the
  parsed body off the thrown error (`err.body`) so the lib can read it, and the
  screen says "the hub ladder this edit was based on changed" rather than the
  generic line, because the two send an operator to look at different things.

## The gapped scopes

`resolveModelLadder` ignores any scope whose rows do not start at position 0 (the
NO RUNG 0 = NO SCOPE rule from #1510.3). That rule is right, and it made the
half-written ladders the pre-#1560 write shapes could leave behind completely
invisible: the project tab showed HUB DEFAULT, the hub tab showed NO ROUTE, and
`bin/lib/model-route.sh`'s own `norung0` alert cannot fire against the current
worker, because the worker resolves past the gap before the shell ever sees it.

So the gap is a read of its own. `modelRouteGaps(env)` is one GROUP BY with
`HAVING min(position) > 0`; the list read carries it as `gaps` **fleet-wide on
every tab** (a project-only gapped scope is not a row on the hub tab at all, so
this list is the only place it can surface) plus `gapped` per role, and the
one-role read carries `gapped: {rows}` for the scope it names. A hole past rung
0 — a `0,2` ladder — is not a gap: position is a failover order, not an index.

On screen: a warn banner counting them with one link each, `GAPPED` beside the
scope tag, and on the role page the orphan rungs listed plus the repair. RESET TO
HUB is shown for a gapped PROJECT scope even though `source !== 'project'`,
because those rows are that project's and dropping them is exactly the repair;
its confirm modal lists the orphan rungs going. `scope_version` already counts
those rows, so both repairs run under the existing guard.

`bin/model-route-gap-check.sh` (hub lane, daily 04:35Z, hub-lease gated,
read-only) writes one `ALERTS.log` line per gapped scope per UTC day. It reuses
`_mr_alert_once "<role>-norung0" "<project>"` — the same reservoir key the lib's
runtime branch owns — so the two paths together emit one line per scope-day
whichever sees it first. A worker it cannot reach is a log line and no alert:
`bin/jobs-client.sh` already pages its own transport, and a detector that pages
on the outage it rides is the doorbell lesson in reverse.

`bin/lib/model-route.sh` is untouched. Every lane sources it, and its `norung0`
branch stays as the old-worker safety net.

## Operator identity: not deliverable, and why

The ticket asked to record the operator identity "once the console has one". It
does not have one. Login is `/login/<DASH_SECRET>`
(`console-ui/functions/login/[secret].js`), a single shared secret that mints an
anonymous `dash` cookie; no username, email or session subject exists anywhere
in `console-ui/` or the worker. So the actor stays `console` and nothing here
invents a placeholder. The seam is recorded in `docs/MODEL-ROUTES.md`: `ACTOR` in
`console-ui/src/lib/models.js`, and the `actor` body field the worker already
stores sliced to 128 chars.

## SHARED on the calls column

`AttributionTag` was only in the `$ 7D` cell. A summed calls figure is exactly as
double-counted as the dollars, so it is in `CALLS 7D` too. Two chips in one row
pushed the roles table 2px past 1280 in `npm run drive:models`, so the tag got a
`tag--sm` modifier (tighter padding, no letter-spacing) rather than being moved
to a footnote; the drive reports spill 0px.
