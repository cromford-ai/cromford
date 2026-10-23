# The patch-id rebind carries the lead verdict to the rebased head (BH-8028)

Doc: MERGE-CONDUCTOR

## Why

The conductor rebased a PR onto a newer main. The PR's own patch did not
change, so `rebind_patch_id` (`bin/lib/mc/settle.sh`) logged
`REBOUND A -> B: patch-id <id> unchanged` and moved the builder approval to B.
It wrote no lead verdict row on B. The rebind also set REVIEWED to B, so
`mc_lead_ready` returned at its gate 3, before its BH-6291 `lead_carry` call.
`bin/lead-verdict.sh show` answered `standing on B: none`, and the lead lane
bought a second paid lead review of the same patch. On 2026-10-22 this cost
30 to 60 min on 11 project-6 rebases (#2296, #2297 x4, #2298, #2300 x3, #2309).

## What changed

- `rebind_patch_id` calls `lead_carry <key> <slug> <num> <B> <reason>` after
  the REBOUND log line and before `mc_rebind_publish`. The reason is
  `patch-id:<id>` on the patch-id arm and `same:<how>` on the BH-2310
  patch-same arm. The call is fail-open: the rebind rc does not change.
- `lead_carry` keeps all of its BH-6291 checks. It carries the newest lead
  MERGE or MERGE-WITH-NOTES only when `patch_same` proves B carries that row's
  patch. A BLOCK, a changed patch, a hand-resolved merge, `la_decide` rc 1 or
  a failed post carries nothing.
- `lead_carry` takes an optional 5th argument `<reason>`. With it, the note of
  the carried row gets two more tokens:
  `lead-replay:<A12> how:<how> ref:#<idA> by:merge-conductor carried_from:#<idA> reason:<reason>`.
  A reason with whitespace is held, and nothing is posted. Without the 5th
  argument (the `mc_lead_ready` path) the note is the same as before.
- `bin/lead-verdict.sh show` names the source of a replayed or carried
  standing row: `standing on <B12>: MERGE (lead, #<idB>, carried from #<idA>)`.
  It reads `carried_from:#N`, else `ref:#N`, else the `lead-replay:<G12>` head.

The carried row is an ordinary `source=lead` row, posted through
`bin/lead-verdict.sh post`. That post also publishes the `lead-verdict` status
on B, so Mergify, AUTOENQUEUE and `vd_standing` treat it like the original.

## Off switch

`MC_LEAD_CARRY=0` (the existing merge-conductor knob,
`catalog/lanes.d/merge-conductor.knobs.d/MC_LEAD_CARRY.json`) turns off this
path and the BH-6291 path. The rebind then works as before BH-8028.

## Tests

`tests/lead-carry-rebind.bh-8028-test.sh` drives `rebind_patch_id` against
real git (cases R1-R10) and `bin/lead-verdict.sh show` (S1-S5).
`worker/jobs/test/verdicts-carried-standing.bh-8028.test.js` proves the worker
answers the carried row as the standing verdict on B.
