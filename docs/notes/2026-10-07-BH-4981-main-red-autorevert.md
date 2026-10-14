# A red daily full run reverts its culprit through the hotfix lane and files the map gap (BH-4981)

Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

- `bin/lib/mrb-detect.sh` has a third red source, `full`: the newest completed
  `workflow_dispatch` run of `harness-ci.yml` on main (the daily full run,
  BH-4970). Its suites come from the failed `Tests, traced (shard` job logs, as
  for the main-red flag, and only a green dispatch run anchors it
  (`_mrb_green`'s new optional event argument). No dispatch run yet is no
  episode. `mrb_episode_still_red` re-reads the same list for `source=full`.
- The revert PR `bin/lib/mrb-act.sh` opens is labelled `fix-main-red` (Mergify's
  hotfix queue, unchanged) and `hotfix_label` (default `hotfix`), so the merge
  conductor's hotfix-first order heads its tick with it. Still one labels POST,
  still best-effort.
- After a culprit is acted on, `_mrb_mapgap` asks `qp_impact`
  (`bin/lib/queue-partition.sh`, over the hub's current map) which lane the
  culprit's changed files get. A scoped lane whose scopes miss a red suite that
  is not an always-suite is a map gap: one ai-build ticket per culprit,
  `Impact map gap: #<pr> reached <suite> without the map knowing`, ledger kind
  `main_red_mapgap` plus the body marker `<!-- main-red-mapgap: <slug>@<sha> -->`.
  A serial lane, a mapped suite or an always-suite files nothing. An
  unavailable qp lib is `unknown` with one warn. A culprit that is itself a
  main-red revert skips the step.
- Every culprit gets one `main_red_attrib <slug>@<culprit>` ledger row
  (`gap|no-gap|serial|unknown`, detail: pr, lane, reason, risk_tier, scopes,
  missed, revert_url, gap_url), written last. Its presence ends the step, so a
  second red run on the same merge files nothing new.
- Mission Control `/ci` has a MAIN-RED REVERTS section: counters by risk tier
  and lane, map gaps, and a sortable table of those rows
  (`console-ui/src/ui/MainRedReverts.js`). `risk_tier` reads `unknown` until
  #4973's `risk_tier` lib ships.
- `bin/main-red-bisect.sh` exports `MRB_REPO_DIR`. `mrb_act_culprit` has
  always needed it to cut the revert, and the lane never set it, so a culprit
  act answered 75 with a `main-red-revert-norepo` page instead of a revert.
- `bin/lib/queue-partition.sh` sources the optional `risk-tier.sh` through a
  variable, so `tests/lib/scratch.sh`'s closure reads it as optional rather
  than missing (the closure of anything reaching that lib, the merge conductor
  included, failed while #4973 is unshipped).

## Why

Impact partitioning (BH-4979) runs each PR against only the suites its files
reach. A break the map did not see lands on main. The daily full run finds it,
the bisect pins it, and the revert has to beat the next batch, which is what
the hotfix label buys. The map-gap ticket fixes the cause, not the symptom.

## Known overlap

BH-4970's daily run files its own red-date ticket. Both can exist for one red
night; this one is per culprit and only on a proven map miss.
