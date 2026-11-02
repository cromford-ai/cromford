# The hub lead review enqueue is deleted (BH-8589)

Doc: OPERATING

Slice C1 of #8525. `bin/lead-review-enqueue.sh` and every file that existed only for it are gone. The lead review
worklist (`bin/lead-review.sh tick` on each box, with the gates in `bin/lib/lead-gates.d/`) is the one input of the
lead review.

## What was deleted

- `bin/lead-review-enqueue.sh` (1822 lines) and its fragment dir `bin/lead-review-enqueue.d/` (a README only).
- `bin/lib/lead-reenqueue.sh`, the `pr`-mode lib (`lre_wake_row`, `lre_wake_launch`, `lre_parse` and the rest).
- The `catalog/list-files.tsv` row for the fragment dir.
- The two `catalog/lead-protected-paths.seed.tsv` rows for the script and the dir, and their mirror lines in
  `tests/fixtures/lead-protected-paths.bh-4148.txt`. The live D1 rows are not deleted by this change.
- The script's line in `tests/fixtures/tracker-direct-allowlist.txt`.
- `tests/lead-review-enqueue-frags.bh-8396-test.sh`, whose subject was the fragment loader.

## Why it was dead

- No cron fragment started the script since BH-7235. Its 713 fragment and lane JSON are gone since #8503.
- `lre_wake_launch` had no caller: `bin/wake-loop.sh` stopped sourcing the lib in BH-7235.

## What replaced each part

| Enqueue part | Live owner |
|---|---|
| builder approval, step-done, CI green | gate 10 `bin/lib/lead-gates.d/10-builder.sh` |
| head_authors | gate 25 `25-authors.sh` |
| patch-same replay, BH-3930 rebound replay, `lead-delta:` and `lead-prev:` notes | gate 50 `50-replay-delta.sh` |
| PR snapshot read | gate 55 `55-snapshot.sh` |
| risk tier, review-tier tokens | gate 60 `60-risk.sh` |
| pre-review self-check notes | `bin/lib/lead-gates-selfcheck.sh` (`lgsc_notes`), gates 75 and 78 |
| lead-review doorbell | gate 97 `97-doorbell.sh` |

## The replay rule change

`review_one` in `bin/lead-review.sh` and `_lr_fresh_lane_request` in `bin/lib/lead-review/fresh-conflict.sh` no
longer treat a `requested_by lead-review-enqueue:*` row as the lane's own. Only `requested_by lead-review-worklist`
or `src worklist` is replayed (patch-same) or held (fresh conflict). Any other row, the old enqueue tag included, is
a review a person asked for, so it is reviewed. The no-replay log line now reads `not the worklist`.

## Left alone on purpose

- `state/lead-review-enqueue/` keeps its name. It is the live state dir of the worklist gates.
- History comments stay true: the "ported from bin/lead-review-enqueue.sh" lines in `bin/lib/lead-gates.d/`,
  `bin/pr-state-reconcile.sh`, `bin/lib/console-qa-gate.sh`, `bin/lib/lead-gates-compare.sh` and
  `bin/lib/lead-gates-selfcheck.sh`.
- The CI workflow comment in `config/harness-ci/120-lint/000-job.yml` (and its render) is a protected path. It is
  out of scope here.

## Tests

`tests/lead-enqueue-retired.bh-8589-test.sh` pins the four #5878 paths absent, the lib, the dir and the catalog
rows, and drives the replay rule through `bin/lead-review.sh tick`.
