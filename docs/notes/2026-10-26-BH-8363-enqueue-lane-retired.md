# The lead review enqueue lane is out of the registry and the cron fragments (BH-8363)

Doc: OPERATING

Slice C1 of BH-8363 (BH-7236.2). C0 (PR #8381) removed the static reads of the
enqueue script from five suites.

## What changed

- `catalog/lanes.d/lead-review-enqueue.json` is deleted. The lane
  `lead-review-enqueue` is not in `catalog/lanes.json` after
  `bin/lanes-build.sh --write`.
- `cron/lanes/713-lead-review-enqueue.cron` is deleted. It was a comment-only
  stub since BH-7235 (no schedule line).
- Both files go in one commit. The lane JSON with no stub makes the db-mode hub
  render refuse (`registry lanes with no cron/lanes fragment`), because of the
  D1 row below.
- `tests/lead-enqueue-lane-retired.bh-8363-test.sh` pins the result (R1-R4, the
  matcher D1-D4, and the mutation M1). The stub and `.boxes` pins of
  `tests/lead-enqueue-unwired.bh-7235-test.sh` (U4, M2, the U1 stub asserts) and
  the 713 assert of `tests/lead-review-concurrent.bh-5317-test.sh` C8 changed
  to match.

## Why the D1 row needs no prod write

The D1 registry row `lane_boxes {lead-review-enqueue, hub}` stays. In db mode
`bin/render-cron.sh` overlays the D1 rows with `.lanes |= map(...)`: it maps
over the file lanes only. No file lane has the id `lead-review-enqueue`, so the
row overlays nothing, the hub gets no such lane, and step 3 has nothing to
refuse. `bin/registry-seed.sh` counts the row as stale and does not delete it.

## Why the script stays

`bin/lead-review-enqueue.sh` stays in this slice. Fifteen suites still run its
`tick`; their removal is #8362 (BH-7236.1), which is open. The script reads its
lane through `lane_gate_or_exit lead-review-enqueue` and `lane_env_apply
lead-review-enqueue`. Both fail open on a lane with no row, and each knob the
script reads has a code fallback or is set by the suite.

## Next slice (C2, blocked by #8362)

- Delete the enqueue script and its `pr`-mode lib.
- Delete the supersede block in the lead lane (`requested_by lead-review-enqueue:*`).
- Delete the protected-path seed row and its fixture line.
- Rewrite the comments that name the enqueue (#5878 step 6).
- Retire the map rows of #5878 step 7 and the tmp-sweep name.
- Add `tests/lead-enqueue-retired.bh-5870-test.sh`.
- Keep `state/lead-review-enqueue/`: it is the live state dir of the worklist gates.
