# The merge-queue arm's hooks, flag lines and knobs (BH-3888, part 1 of BH-3886)

Doc: MERGE-CONDUCTOR

## What changed

`bin/main-red-detector.sh`'s merge-queue arm now has the wiring the three
BH-3886 libs plug into. None of those libs exists yet. With none of them
installed, every decision, alert and existing flag key is what it was before.
`tests/main-red-queue-hooks.bh-3886-test.sh` H5 compares a no-lib tick against
the detector at 1226c3b on the 2026-10-02 incident pages.

- **The walk.** The queue read now projects `updated_at`. The python walk takes
  a comma list of run ids to leave out, and prints three new line kinds: `GD`
  (the newest green batch's finish), and, only with a verdict, `R` (the newest
  counted red's created_at and updated_at) and one `W <run-id> <PR,PR...>` per
  counted batch. Bash keeps them in `QGREEN_DONE`, `QRED_T`, `QRED_DONE` and
  `QWALK`. The `QVERDICT` columns are unchanged.
- **The hooks.** The detector sources `bin/lib/main-red-queue-thaw.sh`,
  `bin/lib/main-red-queue-attr.sh` and `bin/lib/main-red-queue-dispatch.sh` if
  they are there. Each hook runs only when `type` finds it:
  - `mrqa_attr <slug> <run-id> <pr...>` is asked about at most
    `MAIN_RED_QUEUE_STREAK*2` counted batches. A batch it answers `own` for is
    logged and left out of a second walk of the same page, and that walk's
    result is the verdict.
  - `mrqt_stand_down <slug>` runs after the workflow_dispatch stand-down. rc 0
    drops the verdict and logs its `MRQT_WHY`.
  - `mrqt_clear_ok <slug> <flagfile>` decides a queue freeze's clear in place
    of the `detected=` comparison. rc 0 clears (one resolve alert, as before),
    anything else holds.
  - `mrqd_self_dispatch <slug> <flagfile>` runs on the same-sha still-red path
    for a `reason=queue` flag, and on the queue "flag left as it is" branch.
- **The flag.** A `reason=queue` flag ends with `qred_t=`, `qred_done=` and
  `raised=`. `raised=` is the episode's first raise. A new-sha rewrite keeps it,
  and an older flag's `detected=` stands in for it. No new flag write site was
  added, so `bin/batch-resolve.sh`'s mtime read is unaffected.
- **The knobs.** `MAIN_RED_QUEUE_ATTR` (default 1) and
  `MAIN_RED_QUEUE_SELF_DISPATCH_MIN` (default 60) are registered in
  `catalog/lanes.d/_lib.main-red-detector.json`. They resolve as settings row
  `lib.main-red-detector.<env lowercased>`, then env, then the default. A value
  that is not a whole number is the default. They are exported as
  `MR_QUEUE_ATTR` and `MR_QUEUE_SELF_DISPATCH_MIN`, and each tick logs one
  `queue knobs ...` line.

## Why

BH-3886 splits the queue arm's thaw, attribution and self-dispatch rules into
three sibling libs. This slice freezes the contract they implement, so they can
land in any order without touching the detector.
