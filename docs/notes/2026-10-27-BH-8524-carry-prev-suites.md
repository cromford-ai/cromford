# Two more gate-50 suites lose their enqueue cases; seven live cases move to two worklist suites (BH-8524)

Doc: TESTING

Slice C0 of #8524 (BH-8496.1). Since BH-7235 no cron lane or wake starts `bin/lead-review-enqueue.sh`. Since
BH-8363 it has no lane row. Its per-PR gates run in `bin/lead-review.sh tick` (the worklist,
`bin/lib/lead-gates.d/`). This slice removes the enqueue `tick` cases from bh-7043 and bh-6391. No file
under `bin/`, `worker/`, `cron/` or `catalog/` changes.

## What left which suite

- `tests/builder-carry-merge-only.bh-7043-test.sh`: E1-E8 went, with the enqueue rig (the `lead-verdict.sh`,
  `lane-alert.sh` and `agent-call.sh` stubs, the 3 closures into `$Q`, the curl and gh stubs, the token and
  its fleet.conf), the git shim's `allfail` mode (only E7 used it) and the `lpp-stub.sh` source (only the rig
  used it). F1-F4, B1-B5, W1-W5 and U1-U5 do not change.
- `tests/lead-review-delta-scope.bh-6391-test.sh`: D1a-D1e went, with the same kind of rig. The lib cases
  U1-U7 install `bin/lib/lead-prev.sh` with `scratch_install_closure`. Part 2 read its request notes from the
  notes D1a-D1c posted. It now builds the same 3 strings with `lpv_note`, behind a setup guard. U1-U7,
  D2a-D2f, D3a-D3e, P1 and D4a-D4f do not change.

## Where each case went

`.harness/specs/BH-8524/twin-map.md` has one row per removed case: TWIN (the worklist suite and case that
pins the same outcome), ENQUEUE-OWN (output only the enqueue wrote) or PORT.

`tests/lead-gates-builder-carry.bh-8524-test.sh` drives `bin/lead-review.sh tick` whole over the worklist
fixture:

- BC1 (from E1, second tick): a carried head that has its replay row gets no second post.
- BC2, BC2b (from E5): under `LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1` a carried head starts one review whose
  notes name the carry; a head with one own line is skipped.
- BC3 (from E7): when every fetch fails, the log has the redacted not-carried line and no cache row.
- M1 deletes gate 10's carried `LGB_REQFOR` line in the scratch copy; BC2's notes lose the prefix.

`tests/lead-gates-prev-note.bh-8524-test.sh` drives the same tick over a real git fixture:

- PV1, PV2, PV3, PV4 (from D1a, D1b, D1d, D1e): the `lead-prev:` group in the job notes, with delta mode
  off, past a newer replay row, and for a lead BLOCK. PV0: no lead row, no group.
- M2 makes gate 50's earlier-review pick keep `lead-replay:` rows; PV3 then names the replay head.

## What is left

- C1 of #8524: bh-3930 (`tests/lead-review-dedupe.bh-3930-test.sh`), after open PR #8489 merges or closes,
  because #8489 edits that suite.
- On this head, 8 suites still name an enqueue `tick` (the plan's V9 count): bh-6967, bh-5023, bh-3930,
  bh-5875, bh-7041, bh-5797 (silence-before-risk), bh-8363 (the lane-retired suite) and bh-5740
  (inbuild-grace-outside-push).
