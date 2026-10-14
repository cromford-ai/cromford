# A merge-queue failure can add the impact-map edge it missed (BH-6390, slice C0)

Doc: TESTING

## Why

The builder gate (`bin/test-impact-gate.sh`) runs only what
`bin/test-impact.sh select` picks. In the 7 days to 2026-10-13, 116 of 250
(culprit, suite) failures in merge-queue batches were suites the culprit's
impact set did not hold: 65 path misses and 51 whole-repo suites. The map is
built from suite text only, so a static miss stayed a miss.

## What changed

- `bin/impact-learn.sh record --event <file>` reads one `dequeue_events` row.
  It acts only on attribution `culprit` with class `rule-break` or
  `semantic-test`. It diffs the culprit head against its merge base with
  `--base` (default `origin/main`) and asks `select --map-only` for those paths.
  For each named suite that the map did not pick, it writes one edge per
  changed path to `catalog/test-impact-learned.d/<key>.tsv`. It skips `*.md`
  and `.harness/` paths. A culprit with more than `--max-paths` paths
  (env `IMPACT_LEARN_MAX_PATHS`, default 10) writes no edge for that suite. A
  suite with the line `# test-impact: whole-repo` gets one `*` row instead.
- `bin/test-impact.sh` reads those fragments into the map (`ti_learned_rows`).
  A learned path row prints the `closure` kind in `select --why`, and a `*` row
  prints `always`. `bin/test-impact.sh always` does not change, so the
  fast-lints set does not move.
- The format and key rule are in `catalog/test-impact-learned.d/README.md`.

## Not in this slice

- C1: a hub lane that runs the learner on each ejection and opens one PR with
  the new fragments. Until then, a person runs it.
- C2: the builder gate runs the always and whole-repo sets against fresh
  `origin/main` merged into the head, and ranks a learned edge with its own kind.
- C3: an edge expires after its suite passes 30 times with no failure (knob).
- No suite carries the `# test-impact: whole-repo` tag yet.
