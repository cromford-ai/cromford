# Learned impact edges expire after N clean passes (BH-6460, slice C3 of BH-6390)

Doc: TESTING

## Why

A learned edge in `catalog/test-impact-learned.d/` stayed in the map forever.
A noise edge (a path in a wide culprit, or a flake classed as `semantic-test`)
made the builder gate run that suite for every PR that touched the path. C0
(#6451) deferred the exit: "Nothing prunes it in this slice (expiry is C3)".

## What changed

- The rule: an edge expires when its suite passed `IMPACT_LEARN_EXPIRE_PASSES`
  times (default 30, 0 = off) with no failure after the edge's date.
- Route `GET /api/suite-results/passes?repo=R&since=YYYY-MM-DD` in
  `worker/jobs/src/routes/suite-reuse-saved.js`. Bearer only. It answers
  `{repo, since, suites: [{suite, passes, fails}]}` from `suite_results`.
  `passes` is the `runs` of `ok` rows with `first_at >= since`. `fails` is
  every fail on a row with `updated_at >= since`, both classes. A suite with no
  row is absent. A missing or bad `repo` or `since` is a 400.
- Verb `bin/impact-learn.sh expire --counts <tsv> --passes N [--out-dir DIR]
  [--keep FILE]`. Pure and offline, like `record`. The counts TSV is
  `<edge date>\t<suite>\t<passes>\t<fails>`. A bad or repeated line is rc 1 and
  deletes nothing. Hand rows, `--keep` names, missing counts, fails > 0 and
  passes < N are kept. Each deletion prints `expire <suite> <path> <file>
  passes=<p>` after the file is gone.
- Lane `bin/impact-learn-lane.sh`, step 7b. For each date D of a tracked
  learned fragment it reads `sr_passes_list` from `max(D + 1 day, today - 30
  days)`. The floor matches the ledger's 30-day prune (`PRUNE_AFTER_S`). It
  then runs the tree's own `expire` verb in its worktree. The edges this tick
  wrote or re-confirmed (`edge` and `exists` lines) are the keep list. The
  deletions ride the same one PR as new edges. Title: `learn N …`,
  `expire M impact edge(s) after clean passes`, or `learn N and expire M
  impact edge(s)`.
- With no candidate event, the lane now goes on when expiry is on and
  `origin/main` tracks a learned edge. Otherwise the old `none` path runs.
- The tick line gains `expired=<n|-|?>` after `failed=`. `-` is off or not
  checked. `?` is a ledger or verb failure. A number is the ` D` lines in the
  worktree's `git status`.
- New warn ids (no page): `impact-learn-ledger`, `impact-learn-expire`,
  `impact-learn-mass-expire`.
- Knob fragment
  `catalog/lanes.d/impact-learn-lane.knobs.d/IMPACT_LEARN_EXPIRE_PASSES.json`.

## Not changed

`ti_learned_rows` in `bin/test-impact.sh`. Expiry deletes a committed fragment
through a PR, so the map stays a function of the tree.

## Verify

- `HARNESS_TEST_SANDBOX=1 bash tests/impact-learned-expire.bh-6460-test.sh`
- `cd worker/jobs && node --test test/suite-results-passes.bh-6460.test.js`
- Live, after the worker deploys: an authenticated
  `GET /api/suite-results/passes?repo=example-org/cromford&since=<yesterday>`
  answers 200 with a `suites` array, and
  `tail -1 /root/harness/logs/impact-learn.log` carries `expired=`.
