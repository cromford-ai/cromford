# tests/fixtures/bh-8338 — the BH-8338 outcome-cap suite

- `body-ten-inconclusive.md`: a PR body with ten INCONCLUSIVE claim rows, in the
  row shape `bin/evidence-summary.sh` writes (the shape of
  `tests/fixtures/bh-6381/body-one-inconclusive.md`).
- `issue-8401.json`: a made-up issue with the labels `ai-build,perf-gate` and a
  body with no perf phrase, so the `perf-gate` label alone decides the cap.
