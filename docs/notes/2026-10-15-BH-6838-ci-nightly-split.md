# CI blocks on factory checks and reached suites; the corpus and hygiene lints run nightly (BH-6838)

Doc: ci-test-tiers, TEST-DETERMINISM

## Result first

**The 10-minute median target is NOT met.** The 20-draft replay ran on
2026-10-15, finished 08:44Z, from the build box (`gh` read the REST API). The new
plan's median estimate is 24.4 min. The old median wall is 30.9 min. A
selected batch (no full mode) estimates 16.3 to 26.9 min, so the slowest
shard's suite time alone is over 10 min. Meeting 10 min needs more shards or
faster suites. This PR does not change the shard sizing.

- Full mode fires on 9 of 20 drafts. 4 of the 9 are artifacts of the replay's
  map: the path is not in this branch's tree (`bin/lib/main-red-state.sh`
  fires 3, `catalog/lead-protected-paths.seed.tsv` fires 1). BH-4156 added
  them to main after this branch was cut, and the replay plans with THIS
  checkout's map. The other 5 are the `.github/` row (workflow edits). The
  real rate on this sample is 5 of 20.
- Every failed draft has a verdict (8 of 8 read). No culprit is
  `moved-nightly`. Four drafts have a `missed` culprit. All four are replay
  artifacts, not misses. The per-draft reading is below.
- The regression list keeps one row (#6830, route-table.d). The replay found
  no real miss that needs a new row.

Command (CI_SUITES_PER_SHARD and CI_MAX_SHARDS were not readable from this
token, so the planner defaults 120 and 8 sized the shards):

```bash
bin/ci-plan-split-replay.sh --last 20 --repo example-org/cromford --out /tmp/replay.tsv
```

Summary lines, verbatim:

```
drafts: 20 read (unreadable 0)
full fires: 9 of 20 (unreadable 0)
other full reason unmapped path bin/lib/main-red-state.sh fires 3
other full reason unmapped path catalog/lead-protected-paths.seed.tsv fires 1
row .github/ fires 5
median wall (min): old 30.9 over 20, new est 24.4 over 20
verdicts: caught-batch 0, caught-pr 0, moved-nightly 0, missed 4, not-replayed 4, no-culprit 0 (failed 8)
durations: artifact run 38701998940
selection step: approx: current map; est is suite time on the slowest shard, no job setup
```

(The `verdicts:` line counts the draft verdict, which is the weakest culprit.
The per-culprit verdicts are in the table.)

### The 20-draft table

| draft | old result | old plan | old wall (min) | planned on | new plan | new shards | new est (min) | new escalation | culprits | verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| #6855 | pending | batch-selected 1197 | 2.9 | own | batch-selected 186 | 2 | 26.9 | - | - | - |
| #6849 | success | batch-selected 1191 | 36.6 | own | batch-selected 494 | 5 | 18.9 | - | - | - |
| #6847 | success | batch-selected 1165 | 36.1 | own | batch-selected 893 | 8 | 16.3 | - | - | - |
| #6845 | success | full 2215 | 45.8 | full | full 2211 | 8 | 33.1 | unmapped path catalog/lead-protected-paths.seed.tsv | - | - |
| #6844 | success | batch-selected 837 | 24.8 | full | batch-selected 835 | 7 | 17.3 | - | - | - |
| #6843 | success | batch-selected 404 | 27.5 | full | batch-selected 402 | 4 | 21.1 | - | - | - |
| #6841 | success | batch-selected 1140 | 29.8 | full | full 2211 | 8 | 33.1 | unmapped path bin/lib/main-red-state.sh | - | - |
| #6840 | failure | batch-selected 404 | 27.6 | own | batch-selected 402 | 4 | 21.1 | - | tests/harness-sync-docs-off-path.bh-6806-test.sh=missed, job:Pure-logic gate fixtures/every planned shard ran,  and every test passed=not-replayed | missed |
| #6839 | failure | batch-selected 1243 | 35.6 | full | full 2211 | 8 | 33.1 | selection input: .github/workflows/harness-ci.yml | tests/harness-sync-docs-off-path.bh-6806-test.sh=missed, job:Pure-logic gate fixtures/every planned shard ran,  and every test passed=not-replayed | missed |
| #6837 | success | batch-selected 974 | 29.6 | own | batch-selected 486 | 5 | 18.4 | - | - | - |
| #6836 | success | full 2207 | 45.6 | full | full 2211 | 8 | 33.1 | selection input: .github/workflows/harness-ci.yml | - | - |
| #6835 | failure | batch-selected 1190 | 29.0 | full | full 2211 | 8 | 33.1 | unmapped path bin/lib/main-red-state.sh | tests/route-keyed-merge.bh-5788-test.sh=caught-pr, tests/worker-node-catalog-compose.bh-6452-test.sh=caught-batch, tests/worker-routes-render.bh-4607-test.sh=caught-batch, job:Pure-logic gate fixtures/every planned shard ran,  and every test passed=not-replayed | not-replayed |
| #6834 | success | batch-selected 745 | 23.5 | full | batch-selected 748 | 7 | 16.5 | - | - | - |
| #6832 | failure | full 2211 | 48.9 | full | full 2211 | 8 | 33.1 | selection input: .github/workflows/harness-ci.yml | tests/route-keyed-merge.bh-5788-test.sh=caught-batch, tests/worker-node-catalog-compose.bh-6452-test.sh=caught-batch, job:Pure-logic gate fixtures/every planned shard ran,  and every test passed=not-replayed | not-replayed |
| #6831 | failure | batch-selected 1217 | 31.2 | full | full 2211 | 8 | 33.1 | unmapped path bin/lib/main-red-state.sh | tests/route-keyed-merge.bh-5788-test.sh=caught-pr, tests/worker-node-catalog-compose.bh-6452-test.sh=caught-batch, tests/worker-routes-render.bh-4607-test.sh=caught-batch, job:Pure-logic gate fixtures/every planned shard ran,  and every test passed=not-replayed | not-replayed |
| #6830 | failure | batch-selected 1219 | 30.6 | own | batch-selected 132 | 2 | 21.8 | - | tests/route-keyed-merge.bh-5788-test.sh=missed, tests/worker-node-catalog-compose.bh-6452-test.sh=caught-batch, tests/worker-routes-render.bh-4607-test.sh=missed, job:Pure-logic gate fixtures/every planned shard ran,  and every test passed=not-replayed | missed |
| #6829 | failure | batch-selected 1268 | 39.4 | own | batch-selected 132 | 2 | 21.8 | - | tests/route-keyed-merge.bh-5788-test.sh=missed, tests/test-impact-gate-fresh-main.bh-6459-test.sh=caught-batch, tests/worker-node-catalog-compose.bh-6452-test.sh=caught-batch, tests/worker-routes-render.bh-4607-test.sh=missed, job:Pure-logic gate fixtures/every planned shard ran,  and every test passed=not-replayed | missed |
| #6826 | failure | batch-selected 1266 | 33.1 | full | full 2211 | 8 | 33.1 | selection input: .github/workflows/harness-ci.yml | tests/route-keyed-merge.bh-5788-test.sh=caught-pr, tests/test-impact-gate-failed.bh-4548-test.sh=caught-batch, tests/worker-node-catalog-compose.bh-6452-test.sh=caught-batch, tests/worker-routes-render.bh-4607-test.sh=caught-batch, job:Pure-logic gate fixtures/every planned shard ran,  and every test passed=not-replayed | not-replayed |
| #6820 | success | batch-selected 961 | 30.5 | own | batch-selected 901 | 8 | 18.1 | - | - | - |
| #6819 | cancelled | full 2199 | 48.4 | full | full 2210 | 8 | 32.7 | selection input: .github/workflows/harness-ci.yml | - | - |

`job:Pure-logic gate fixtures/every planned shard ran…=not-replayed` is the
fan-in job that fails when a shard fails. It is not a culprit of its own.

### The four `missed` drafts

- **#6840 and #6839:** `tests/harness-sync-docs-off-path.bh-6806-test.sh`
  failed. That suite is NEW in the draft's own diff (BH-6806). It is not in
  this checkout, so the replay cannot select it. The real planner selects a
  changed suite as its own reach, so the batch runs it: `caught-batch`. It
  is not a regression-list case.
- **#6830 and #6829:** stacked drafts. `tests/route-keyed-merge.bh-5788-test.sh`
  and `tests/worker-routes-render.bh-4607-test.sh` failed. The cause is the
  BH-4156 member queued ahead (it adds `worker/jobs/test/route-table.d/` and
  `worker/jobs/src/routes/` files). The replay judges a stacked draft on its
  own diff (BH-6720 only), which has none of those paths. On the whole diff
  the seeded row fires (`caught-pr`), and the drafts that carry BH-4156 as
  their own diff show it: #6835, #6831 and #6826 are `caught-pr` for
  route-keyed-merge and `caught-batch` for worker-routes-render.

### What the replay could not read

- **operator-a5's `batch-fail-suites.txt`:** it is on another box, and this box
  cannot read it. The seed is from the replay only.
- **The failed batches older than the last 20** (#6782 #6788 #6789 #6798
  #6800): a 45-draft replay started, and the box's GitHub token expired
  during it (401 "Bad credentials" at 08:48Z). That run read 11 drafts. Its
  two failed drafts are #6840 and #6839 again. The older five have no verdict.
  An operator with `gh` access must run `--last 45` and add a fragment for
  any real `missed` culprit.

### The fixture-hygiene decision (review finding 2)

The fixture-hygiene rules-pack row stays blocking on every PR, and its suite
stays in the batch. Its three rules (`tailnet-ip`, `private-ip`, `secret`)
are leak checks under iron guardrail 3, not word checks. The nightly lints
job does not run it. The replay gives no evidence for a move: no culprit of
the 8 failed drafts is a fixture-hygiene finding.

## What changed

1. **The batch-fail regression list.** `catalog/ci-batch-regression.d/*.txt`
   holds `<suite>\t<paths>` rows (format: the directory's README).
   `bin/test-impact.sh` reads them as map edges of kind `regression`.
   `bin/test-impact-gate.sh` ranks `regression` with `reads` (rank 1), so the
   builder gate runs the suite ahead of its cap. `bin/ci-plan.sh` adds every
   row a batch's diff touches after the tier step, minus quarantined suites.
   `bin/test-impact.sh regression [--changed <f>]` prints the rows.
2. **The #6830 case** (comment 6185155501). #6784 added
   `worker/jobs/test/route-table.d/` fragments. The gate selected
   `tests/route-keyed-merge.bh-5788-test.sh` as `source` (rank 4) behind 73
   `always` suites with cap 80, and left it to CI. The batch ran it first, and
   batch #6830 failed. The seed fragment `bh-6838.txt` maps that directory and
   `worker/jobs/scripts/routes-build.mjs` to the suite. The plan's REPRO now
   exits 0. `tests/ci-plan-split-replay.bh-6838-test.sh` R2 replays a draft
   with that diff to `caught-pr`.
3. **The seed has one row.** The 20-draft replay above found no real miss
   that needs another row. #6819 was cancelled, not failed. #6835 is
   `caught-pr` and `caught-batch`. The older batches are owed (see "What the
   replay could not read").
4. **The full corpus runs nightly.** `.github/workflows/harness-nightly.yml`
   plans `bin/ci-plan.sh --tier nightly-full`: every suite, no tier step, no
   suite reuse, sized by `vars.CI_SUITES_PER_SHARD` and `vars.CI_MAX_SHARDS`.
5. **The hygiene lints run strict, nightly only.** A new `lints` job runs
   `bin/test-determinism-lint.sh`, `bin/test-payload-pin-lint.sh --strict`
   and the day-boundary guard. Its base is the newest night on main whose
   `lints` job was green (fallback `HEAD~50`), so one red corpus suite does
   not hold the base at an old sha. The ticket range stays the newest fully
   green night. In `harness-ci.yml` the determinism job is `--warn-only` (the
   job name stays, because Mergify requires it), the rules pack skips
   `determinism` only, and the payload-pin step is gone.
   `catalog/test-tiers.tsv` puts `tests/day-boundary-guard.bh-6052-test.sh`
   in the nightly tier. fixture-hygiene stays on the PR (see above).
6. **A nightly red files one issue per failing suite.** `bin/nightly-ticket.sh`
   searches for the marker `<!-- harness-nightly-red:<suite> -->`, comments on
   an open issue or opens a new one with the commit range, and writes one row
   per decision to `ticket-requests.tsv`. At most `NT_MAX_NEW` (10) new issues
   a night. A nightly red never blocks a merge: the workflow name matches
   `bin/main-red-detector.sh`'s skip regex and it runs on a schedule.
7. **The daily full Harness CI dispatch is off.** `bin/ci-nightly-full.sh
   dispatch` runs only with the knob `CI_NIGHTLY_FULL_DISPATCH=1` (default 0),
   because the nightly workflow now runs the corpus and a red dispatch run on
   Harness CI can freeze merges. Cost: `collect` reads only the Harness CI
   runs that `dispatch` made (bin/ci-nightly-full.sh), so the BH-4964
   map-miss tickets ("which changed files the map missed for this suite")
   stop. The per-suite nightly issue gives a commit range, not a map-miss
   diagnosis. Pointing `collect` at the harness-nightly.yml runs is a
   follow-up ticket.
8. **The full-mode triggers are DB-driven.** The settings row
   `CI_FULL_TRIGGERS` (lane `ci-plan-settings`) adds (`+<pattern>`) or removes
   (`-<pattern>`) escalate rows of `catalog/ci-batch-escalate.tsv`.
   `bin/ci-plan-settings.sh` projects it into the repo variable of the same
   name each hour. A self row (the planner, the selector, the rules, the
   regression list and the two runner rows `tests/lib/scratch.sh` and
   `bin/lib/suite-runner.sh`) can never be removed. Empty is the committed file.

## Operator steps owed

1. Run the replay with `--last 45` from a host with `gh` access. Add a
   `catalog/ci-batch-regression.d/` fragment for each real `missed` culprit
   in #6782 to #6800.
2. Run `bin/ci-test-tiers.sh put` so the worker's tier set carries the new
   nightly row. Until then CI reads the committed file only when the worker
   set is older than it (docs/ci-test-tiers.md).

## Scope readings

"The impact map itself" in the ticket's full-mode rule is read as the
selection machinery: the planner, the selector, the tier step, their catalogs
and the suite runners. Their escalate rows stay. The replay prints how often
each row fires, and the `CI_FULL_TRIGGERS` delta lets an operator remove a
row without a PR. `tests/lib/scratch.sh` keeps its escalate row: 2109 of 2147
suites source it, so its reach is the corpus.
