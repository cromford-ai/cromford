# The share publisher drops `.harness/`, the build records (BH-5055)

Doc: MIRROR-NOTES, SELF-HOST

## What changed

- `bin/share/sanitize.py` `dropped()` now drops every path at or under
  `.harness/` with the reason `internal build record`. Every build writes its
  plan, review and owed proofs under `.harness/specs/<KEY>/`. Those are a record
  of how this repo was built, not part of what the mirror runs. Both publish
  workflows run the same sanitizer, so the drop holds for whichever survives.
- Two shipped suites read a committed plan from the real tree, so the mirror
  copies now print an explicit SKIP for it instead of failing: Section G of
  `tests/run-build-rollout-hook.bh-985-test.sh` and check (d) of
  `tests/mc-pr-read-retired.bh-1325-test.sh`. Both are sanitize `PATCHES`
  entries. Upstream copies are unchanged.
- `tests/share-publish-clean.bh-795-test.sh` plants a plan with a KEY=value line
  under `.harness/specs/` in its HEAD export and asserts the mirror has no
  `.harness` path. `tests/share-harness-specs.bh-5055-test.sh` pins the same on
  a small tree, with a control that plants the line where the mirror ships it.
- `tests/README.md` documents the fixture-marker rule the gates already had.
  Nothing was added to it.

## Why

Batch #5048 (8 PRs) failed on bh-795: gitleaks read a plan line quoting
`MC_ONLY_PR=<READY/WAIT_CI keys> ...` as a key. Plans quote env lines and
commands all the time, so every plan was a fresh chance to break a batch.
