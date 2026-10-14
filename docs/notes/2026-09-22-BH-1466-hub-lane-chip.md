# 2026-09-22 — BH-1466: a hub lane on a project tab

Doc: mission-control-settings, lanes-status-contract

#1463 landed the per-project hold as a contract and nothing else: five hub lanes
carry `"per_project_hold": true`, and `lane_project_held <id> <project>` stops
that lane for that project alone off one `lane-off-<id>-<project>` row. Nothing
could SET that row except a curl, and nothing showed it once set — Mission
Control drew the conductor as running on project-3's tab while the gate was skipping
every project-3 tick. This is the page half of #1419, and it is the last of the four
slices.

## What changed

**`worker/jobs/src/routes/lanes.js`** — the status lane loop:

```
const projectHold = l.per_project_hold === true && Boolean(project);
if (scoped || projectHold) names.push(`lane-off-${l.id}-${project}`);
const ownsSighting = (r) => !(scoped || projectHold) || !r.project || r.project === "-" || r.project === project;
```

plus `per_project_hold: Boolean(l.per_project_hold)` on the lane object, so the
console can tell a hold lane from a plain hub lane without a second fetch. The
`ownsSighting` half is not decoration: per-project flag FILES exist for these
five now, and unscoped, a `flags/lane-off-merge-conductor-project-3` sighting on
the hub box would report the conductor stopped on every project's tab. That is
the BH-1165 round-2 bug, newly reachable.

**`console-ui/src/lib/settings.js`**, `laneRows`: the per-row literal is lifted
to `rowFor(decl)` (unchanged field for field) and reused to build `holdRows` —
on a project tab only, one row per `per_project_hold` hub lane, labelled
`<name> (hub lane)`, `scope: 'hub'`, `knobs: []`, `switchName` =
`lane-off-<id>-<project>` and `href` keeping `?project=`. The `extra` filter
excludes them so none of the five also comes back as an `unregistered`
duplicate of itself.

`console-ui/src/screens/Settings.js` is untouched, and that is the design: its
toggle already calls `flagBody(row.id, row.project, …)`, which for these rows
builds exactly the name #1463's gate reads, and `LaneDetailScreen` resolves its
lane through the same `laneRows`, so `/settings/<lane>?project=<p>` works by
construction.

## What deliberately did NOT change

`scoped` is not widened to cover the hold. It also picks the knob key (`pk`) and
the cost attribution (`owns`), and a hub lane reads neither per project: a
per-project knob input would be a control that writes a row nothing reads, and
splitting one lane's spend by tab would invent a number. The `lane_ticks` filter
is untouched for the same reason — the hold posts no tick row.

The HUB tab is byte-identical: `isHub(tab)` makes `project` null, `holdDecls`
empty, and the five keep their knobs and their plain names there. A per-project
row still never marks a lane off fleet-wide.

No schema change, no new env var, no new table and no new component.

## Verified

```
cd worker/jobs && node --test test/routes/lanes-project-hold.bh-1466.test.js   # 6/6
cd console-ui  && node --test tests/settings-hub-project-hold.bh-1466.test.js  # 4/4
```

The worker suite drives `worker.fetch` through the real route table against the
REAL composed `catalog/lanes.json`, and its first case asserts the registry
still declares the field — a `per_project_hold` that fell out of
`catalog/lanes.d/` fails loudly instead of turning the rest green for free.
Seven deliberate mutations (the `names.push` guard, `ownsSighting`, the new
field, a widened `scoped`, the `extra` exclusion, the `holdRows` append and the
`knobs: []` override) were each confirmed red before the tree was restored.

The screens were rendered once as shipped with `preact-render-to-string`: on
`?project=project-3` all five hold lanes render exactly one row each with the
per-project switch, no `NOT IN REGISTRY` tag and a `/settings/<id>?project=`
link; the hub tab renders the string `(hub lane)` zero times; the lane detail
titles `Merge conductor (hub lane)`, names `lane-off-merge-conductor-project-3`
and draws no KNOBS section; the empty tab still renders `NO LANES`.
