# A merge-queue batch red on a suite main does not have is dropped, not filed as a main red (BH-4875)

Doc: MERGIFY

## What changed

- `bin/lib/mrb-detect.sh`, flag source. When the flagged run is a merge-queue
  batch (`mergify/merge-queue/*`), each red suite from its failed traced
  shards is checked against main's tree at `red`, the batch head's merge-base
  with main. A suite that is not in that tree was added by one of the batch's
  own PRs. It is dropped, with one `mrb-detect:` line naming it and the sha:
  `batch run <id> red on <suites>, not in main at <red>: the batch's own PRs
  added them, dropped`.
- No red suite left: no episode file, rc 0, the same shape as BH-4329's skip.
  The bisect driver never sees it, so there is no probe, no quarantine and no
  ticket.
- Some left: the episode is written with only those, and they go through
  BH-4329's main-cleared check first, so that check reads the filtered list.
- The tree at `red` cannot be read: rc 75, the existing "this source writes no
  file this tick" path. A failed read is never "absent".

## Why

#4875 said main was red with no culprit merge, at P0 f7f50bd9 and P1
c019d393, and quarantined `tests/cromford-docs-site.bh-4084-test.sh`,
`tests/test-impact-test.sh` and `tests/test-impact.bh-1253-test.sh`. Run
37489866946 was not a main run. It was the merge-queue batch checking #4773,
#4735, #4614, #4811, #4620, #4785, #4732 and #4841 on c019d39.
`tests/cromford-docs-site.bh-4084-test.sh` is not on main at all. PR #4785
(BH-4084) adds it, and the two test-impact failures were that PR's
`site/cromford-docs/*` files missing from the test-impact map.

The detector mapped the batch red to c019d393 and handed the suites to
`mrb_probe`. That ran `bash <suite>` at f7f50bd9 and c019d393, where the file
does not exist, and bash exited 127. `bin/lib/mrb-probe.sh` counts a suite
missing at an older sha as red, so both probes answered red and the verdict
was `notmerge`. The BH-4329 guard did not catch it, because main had no
traced Harness CI run at c019d393 to clear the suites.

`tests/test-impact-test.sh`, `tests/test-impact.bh-1253-test.sh` and
`tests/scratch-closure-lint.bh-4552-test.sh` pass with
`HARNESS_TEST_SANDBOX=1` on this branch: main plus this change, which touches
no code they run. There was nothing on main to fix. #4785 has to fix its own
S13 case and its map rows before it can land.

## What it does not change

- `mrb_probe`'s rule that a suite missing at an older sha counts as red. That
  is right for bisecting main's own history, where merge N adds the suite.
- main-class flags and the nightly source. There, `red` is the run's own
  head, so every red suite is in its tree.

## The quarantine rows #4875 wrote

This change writes no quarantine rows. `bin/lib/flaky-tier-release.sh`
releases `main-red-bisect` rows after `FLAKY_TIER_RELEASE_CLEAN` (default 5)
clean scheduled nightlies. An operator can clear the two test-impact rows from
the console sooner. The cromford row only releases once #4785 lands and its
suite runs clean in nightlies.

Pinned by `tests/mrb-detect-absent.bh-4875-test.sh`.
