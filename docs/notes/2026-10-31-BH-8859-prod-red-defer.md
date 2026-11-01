# A merged close-out waits while production is red (BH-8859, slice C0)

Doc: OPERATOR-SETUP

## Why

In BH-8781, project-3 production was red for 2 days. Triage still told the
client that merged work was ready. That work was not live. BH-8859 item 3:
"Triage never posts a completion comment to a client while the project's
production is red. The comment waits for the green deploy, then goes out with
the live URL."

## What changed

- New lib `bin/lib/prod-red-defer.sh`. It reads `.projects[<p>].prod_red` in
  `state/vercel-deploy-status.json` through the BH-8781 reader
  `mc_prod_red_state` (`bin/merge-conductor.d/bh-8781-prod-red-hold.sh`).
  `prod_red_defers_dir` is true only when the first RESULT line of a build dir
  is `PR_MERGED http…` and production is red.
- `bin/board-closeout.sh` (builder-direct close-out): a `PR_MERGED` RESULT
  while red exits 4 before any request. The RESULT stays unmarked. The stderr
  line says `the merged close-out waits for a green deploy`.
- `bin/lib/rt/scope.sh` `rt_unswept_dirs`: the results sweep leaves those dirs
  off its list. They keep no `COMMENTED` marker.
- `bin/triage-gate.sh` step 3: those dirs alone buy no `RUN results-sweep`.
  The sweep fingerprint is not changed.
- `bin/run-triage.sh`: while red, the session and every shard get the
  directive `PRODUCTION RED (BH-8859): …`. It forbids a completion, "shipped",
  "live" or "done" comment for merged work and a move to done. The project log
  gets one `PROD-RED defer: completion close-outs held (<since> <sha8>)` line
  per tick.
- A `PR_CREATED` close-out ("built and open for review") still goes out.

After the first green snapshot, the dirs are back on the sweep list. The sweep
posts them as before, with the SOP's direct production links.

## Fail open

No snapshot file, a junk file or a file older than `MC_PROD_RED_MAX_AGE_S`
(1800 s, the BH-8781 knob) reads as "not red". Nothing is held. A Fly pool
builder has no snapshot file, so it posts as before.

## Knob

`TRIAGE_PROD_RED_DEFER` (lane `run-triage`, default 1, 0 = off). Per project:
`lane.run-triage.<project>.triage_prod_red_defer`.
Fragment: `catalog/lanes.d/run-triage.knobs.d/TRIAGE_PROD_RED_DEFER.json`.

## Probe on an owner box

1. `jq '.projects|map_values(.prod_red)' /root/harness/state/vercel-deploy-status.json`
2. `grep 'PROD-RED defer' /root/harness/logs/<project>.log`

## Not in this slice

The owner email, the console `prod: red since` marker (item 4), the migration
alerts that resolve on a green build log (item 5) and the project-3 row check.
They stay open on #8859.

Test: `tests/prod-red-defer.bh-8859-test.sh`.
