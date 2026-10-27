# Two gate-50 suites lose their enqueue cases; three live cases move to a worklist suite (BH-8496)

Doc: TESTING

Slice C0 of #8496 (BH-8362.2). Since BH-7235 no cron lane or wake starts `bin/lead-review-enqueue.sh`. Its
per-PR gates run in `bin/lead-review.sh tick` (the worklist, `bin/lib/lead-gates.d/`). On main at af379a98,
14 suites still mixed enqueue `tick` cases with cases that test live code. This slice cleans the 2 that share
one enqueue scaffold: bh-5294 and bh-5582. No file under `bin/`, `worker/`, `cron/` or `catalog/` changes.

## What left which suite

- `tests/lead-replay-merge-only.bh-5294-test.sh`: R1-R7 of the enqueue part went, with the enqueue rig (the
  `lead-verdict.sh`, `lane-alert.sh` and `agent-call.sh` stubs, the enqueue closure, the curl, gh and git
  stubs, the token and its fleet.conf) and the fixture heads only they read (HM, HP, HB). The `ld_protected`
  unit check that sat inside R6 stays as its own block. It installs `bin/lib/lead-delta.sh` and
  `bin/lib/lead-authority.sh` with `scratch_install_closure`. L1-L3 and the dispatcher R1-R7 do not change.
- `tests/lead-delta-protected.bh-5582-test.sh`: P1 (enqueue), P4 (enqueue) and P8 went, with the same rig.
  The lib cases P1-P7 install the same two libs with `scratch_install_closure` and keep the lead-delta knob
  registry in the scratch catalog (`ld_knob` reads it there). P1 (prompt), P1b and the dispatcher P1-P3 do not
  change.

## Where each case went

`.harness/specs/BH-8496/twin-map.md` has one row per case id of the 2 suites: TWIN (the worklist suite and
case that pins the same outcome), ENQUEUE-OWN (output only the enqueue wrote), PORT or KEPT.

The new suite `tests/lead-gates-delta-class.bh-8496-test.sh` holds the 3 ports. It drives
`bin/lead-review.sh tick` whole over a real git fixture:

- DC1, DC1b (from bh-5294 R7): an over-max head is `full over-max:60` and a full review; under a higher max
  it is a delta review with its `delta_note`.
- DC2a, DC2b (from bh-5582 P8): the cached class of a protected delta carries the allowance and the word
  (`20:MERGE`); a tick under `LEAD_DELTA_PROTECTED_MAX_LINES=0` classifies again and starts a full review.
- DC3 (from bh-5294 R5, the cache half): a plain 7-column delta row is reused on the next tick with no fetch.
- M1 removes the allowance check from the cache rule in the scratch copy of gate 50; DC2b's outcome flips.

## What is left (the next slices of #8496)

After this slice, 12 suites still run the enqueue `tick`.

- C1: the rest of gate 50: bh-7043, bh-6391, bh-3930 (bh-3930 after open PR #8489).
- C2: gate 60 (risk): bh-5325, bh-5024, bh-7041, bh-5875, bh-6968, bh-6967, silence-before-risk.
- C3: gate 70 (in-build grace): bh-5023, inbuild-grace-outside-push.
