# Every alert belongs to a component (BH-6971)

Doc: ALERTS-GROOMING-SPEC, DB-COORDINATION-SPEC

## What changed

- `catalog/components.tsv` names the ten seed components and the regex that
  claims an alert line for each: `component regex lanes logs doc`, five
  tab-separated fields, `-` for none. A component can have more than one row.
- `bin/component-of.sh <line>` prints the component, or `unowned`. It removes a
  leading timestamp, matches rows in file order and the first match wins.
  `--batch` maps `<id>\t<line>` on stdin. `--check` also checks the lane ids
  and docs. A bad row is rc 2 with the line number and the raw line.
- The jobs-worker `alerts` table has a nullable `component` column and
  `idx_alerts_component (component, last_seen)`, both through
  `ADDED_COLUMNS` / `ADDED_INDEXES` in `worker/jobs/src/lib/core.js`.
- `GET /api/alerts?component=<name>` and `?unstamped=1` filter on it.
  `POST /api/alerts/component` stamps rows whose component is NULL.
- `bin/alerts-groom.sh` stamps every open row with no component, each tick,
  at most `ALERTS_GROOM_COMPONENT_MAX` rows (lane knob, default 200, 0 = off),
  only with `flags/alerts-db` set. `unowned` is stamped too, so a row is read
  once. It logs `component stamp: read R stamped S unowned U[ truncated]`.

## Why

BH-6546: an alert needs an owner before a lane can decide on it. This wave
only labels. Nothing decides on an alert from its component yet.

## Limits

A row stamped `unowned` is not stamped again when a catalog row is added later.
