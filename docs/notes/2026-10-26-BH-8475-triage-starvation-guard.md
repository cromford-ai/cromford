# Triage starvation guard: oldest first, one fastpath attempt, one alert (BH-8475)

Doc: TRIAGE-STATE

## What changed

- New lib `bin/lib/triage-starve.sh`. It keeps
  `state/triage-state/<p>/starve.tsv`: one row per key in the current model
  set, with the pass count and the time the key was first listed.
- `ts_tick` (enforce, readable rows) counts each pass with `tsv_pass`, then
  reorders `TICK_SCOPE` with `tsv_order_scope`: hotfix lines first, then the
  oldest listed, then the scope order. The shard units are built in that
  order, so a cap cuts the youngest keys. A full tick marks every listed key
  run (`tsv_ran_all`).
- A run is read from the shard's own out file and lock. `bin/lib/rt/shards.sh`
  is not edited (BH-3418 B1). The first build edited it and was refused.
- A key listed 3 passes over 2 h with no run gets one `bin/launch-fastpath.sh`
  attempt per listing episode, with its board label (`TK-2601`). A decline is
  logged with fastpath's own reason. One warn alert per project per pass names
  the keys.
- Knobs: `catalog/lanes.d/_lib.triage-starve.json`.

## Why

project-6-os TK-2601 was in the "to the model" list on every enforce pass for
27 h (2026-10-25 18:06Z to 2026-10-26 21:05Z). No shard ran for it. The shard
loop walked the scope in scope order, and every cap cut the same tail. Nothing
counted how long a key was listed.

## Off switch

`lib.triage-starve.triage_starve_passes = 0` (or per project
`lib.triage-starve.<p>.triage_starve_passes = 0`): no ledger write, and
TICK_SCOPE keeps its order.
