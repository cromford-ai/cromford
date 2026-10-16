The median is over 10 min: the replay (2026-10-15, rc 0, 20 batches) gives old 28.1 min, new est 13.5 min of suite time, about 19-21 min of wall. The measured gap is the per-suite trace scan. Runner speed was not measured (see "The slowdown").

# CI shard count by measured time; a workflow edit selects its readers; a 35-minute shard page (BH-6876)

Doc: ci-durations, ci-test-tiers, CI-RUNNERS

## Result first

The replay ran from the fix-round box on 2026-10-15, at dc4e90bf02ad, with the
command in "Operator steps" 1 (rc 0). Its summary lines, verbatim:

```
drafts: 20 read (unreadable 0)
full fires: 3 of 20 (unreadable 0)
other full reason unmapped path bin/lib/group-findings.sh fires 1
other full reason unmapped path bin/lib/project-lease.sh fires 1
other full reason unmapped path tests/lib/lane-runs-batch.bh-6886.mjs fires 1
median wall (min): old 28.1 over 20, new est 13.5 over 20
verdicts: caught-batch 0, caught-pr 0, moved-nightly 0, missed 1, not-replayed 6, no-culprit 0 (failed 7)
durations: artifact run 38795563393
weights source: artifact
corpus: 2350 suites at dc4e90bf02ad
speed: median 1.00x over 1291 suites (now vs seed c9063c6b90da)
speed-top20: median 1.00x
over budget: 0 suite(s) over 480s
selection step: approx: current map; est is suite time on the slowest shard, no job setup
```

The `speed:` and `speed-top20:` lines above came from the first version of
the replay. That version counted every shared row, also rows that
`bin/ci-durations.sh merge` carried forward from the seed byte for byte. Those
rows are 1.00x by construction. The fix round (lead review lr-6997) changed
the replay: it now counts only re-measured rows and prints how many rows carry
the seed value. Do not read the `1.00x` above as a runner speed.

The 20 slowest suites (seconds, from the same weights):
share-mirror-cache.bh-5543 398.6, prequeue-invariants-real.bh-5429 365.4,
public-ci-green.bh-4083 290.3, generated-files-train 283.1,
quickstart-walkthrough.bh-4084 242.8, archie-fm-queue.bh-4584 237.4,
publish-cromford-brand.bh-4901 229.1, share-publish-clean.bh-795 200.8,
registry-no-commit 198.3, merge-path-stall.bh-4918 191.9, pipeline-gaps 189.1,
share-mirror-clean 180.8, archie-fm-watch.bh-4586 175.8,
fixround-closure-lint.bh-5064 175.6, rules-pack.bh-3510 163.2,
scratch-closure-pr.bh-4869 144.8, mc/requeue-after-foreign-red.bh-3776 142.1,
verification-map-no-commit 140.4, triage-state-precheck 134.2,
port-to-cromford.bh-5227 118.4.

The `new est 13.5` median is NOT the wall a batch will see. It is suite time on
the slowest shard, and the weights it used did not carry the trace scan (next
section). With the scan added (x1.3-x1.5) and ~1 min of job setup, the median
for these 20 batches is about 19-21 min, not 10. The old median is 28.1 min.

Verdicts: of 7 failed batches, 6 are `not-replayed` (5 were the same
`worker-node-*` pair, caught in the batch but the run also had a fan-in job
fail that the replay does not model). 1 is `missed`
(`tests/archive-readers.bh-6779-test.sh` in run 38778306189: the new selection
for that batch does not reach it).

## Per-run shard table (operator step 2)

From `actions/runs/<id>/jobs`, `Tests, traced (shard ...)` jobs only. Every
shard of every run ran on `monkci--ubuntu-24-04-4-*`.

| PR | run | shards | slowest min | mean min |
|---|---|---|---|---|
| 6982 | 38799938868 | 4 | (in progress) | - |
| 6959 | 38795563393 | 12 | 27.1 | 24.2 |
| 6955 | 38793975871 | 12 | 26.1 | 24.3 |
| 6954 | 38792756916 | 12 | 26.6 | 24.0 |
| 6952 | 38791530526 | 8 | 25.4 | 23.4 |
| 6951 | 38791404218 | 12 | 25.1 | 24.1 |
| 6949 | 38790119628 | 7 | 25.3 | 23.4 |
| 6947 | 38788706169 | 8 | 25.4 | 23.5 |
| 6945 | 38787160702 | 10 | 23.8 | 20.9 |
| 6943 | 38786336023 | 9 | 24.6 | 19.0 |
| 6941 | 38785153862 | 8 | 23.3 | 21.5 |
| 6938 | 38780139967 | 10 | 25.5 | 23.1 |
| 6937 | 38778306189 | 10 | 25.8 | 23.1 |
| 6935 | 38777154650 | 10 | 25.4 | 23.1 |
| 6934 | 38777129509 | 10 | 23.8 | 20.3 |
| 6933 | 38776993444 | 5 | 29.8 | 28.3 |
| 6932 | 38776971056 | 5 | 27.5 | 25.9 |
| 6931 | 38776945897 | 3 | 26.4 | 24.1 |
| 6927 | 38773043897 | 10 | 24.7 | 22.5 |
| 6926 | 38773015204 | 10 | 23.3 | 21.6 |

A shard takes 23-30 min at every shard count from 3 to 12. That is the count
rule: `ceil(N/120)` gives every shard about 120 suites, whatever N is.

## The slowdown: the cause (comment 6197071504 item 3)

| Candidate | Result | Source |
|---|---|---|
| Runner speed | NOT MEASURED. See "Why runner speed is not measured" below | replay, fetch 2026-10-16 |
| Slower heavy suites | NOT MEASURED, same reason | replay, fetch 2026-10-16 |
| Stale seed weights | Not in the file header (`weights source: artifact`). Rows can still carry seed values: 99 of 1291 shared rows on 2026-10-16 | replay, fetch 2026-10-16 |
| Corpus growth | Part of it. 1646 suites (2026-10-05) -> 2350: x1.43 | `git ls-tree`, replay `corpus:` |
| Trace scan after each suite | THE GAP. Not in the weights | run 38795563393, below |

### Why runner speed is not measured

The `speed:` ratio compares the fetched seconds with the seed seconds. Two
facts stop it from measuring the runner:

1. Carried rows. `merge` keeps the row of a suite that a batch did not run
   byte for byte (`docs/ci-durations.md`, "The merge rule"). Such a row is the
   seed itself, so its ratio is 1.00x. The replay now leaves these rows out
   and prints their count.
2. Different units. A seed value is the gap between consecutive `---` lines,
   so it includes the trace scan. A `--timings` row written before this PR
   stops at the test's exit and does not include the scan. A re-measured row
   and its seed row therefore measure different things.

A fetch on 2026-10-16 (`# source: artifact run 38956461308`, 2428 rows) gave
these numbers with the fixed rule: 1291 suites in both files, 99 carry the
seed value, 1192 re-measured, median 1.00x over the 1192; 12 of the 20
heaviest seed suites re-measured, median 1.44x over those 12. Point 2 applies
to all of them, so these numbers do not separate runner speed from the scan.
A valid runner comparison needs rows written after this PR (scan included)
for most suites. Follow-up: run the replay again after 3 full-corpus batches
on the new rows, and read `speed:` then.

### The measured gap: the trace scan

Run 38795563393 (12 shards). The steps before the suite step take about
1 min. The suite step of shard 9 took 26.0 min. Its 125 timings rows sum to
17.7 min. Shard 1: 22.8 min step, 17.9 min of rows. The gap is the time
between consecutive `--- <test> rc=N Ns` lines minus the test's own row: 8.2
min over shard 9's 125 suites, mean 4.0 s, worst 117.4 s after
`tests/lanes-offhub.bh-6721-test.sh` and 62.9 s after
`tests/pr-url-reconcile-per-project.bh-6894-test.sh`. That time is
`bin/test-trace-safety.sh` parsing each suite's trace and running `realpath`
per candidate line. `--timings` stopped its clock when the test exited, before
that scan, though `docs/ci-durations.md` says the rows carry tracer overhead.

So the weights were ~1.4x too small, and a 480 s budget on them is a
~11-12 min shard. This round fixes the measure: the `--timings` row is now
written after the scan (`bin/test-trace-safety.sh`). The shard weights keep
the 3 newest values per suite and use their median. So the fix is in a
suite's weight after 2 green batches that RUN that suite. Most batches run
their impact set only, so a suite outside those sets keeps its old row (no
scan) until a batch runs it; the whole corpus is covered only after 2 green
full-corpus batches. The `---` log line still prints the test's own
seconds.

What is still NOT done: the scan itself is not made faster. A per-suite scan
of 4 s mean, with outliers over 1 min, is the next lever. That is a follow-up
ticket, not this PR.

## What changed

1. **Shard count by time.** `bin/ci-plan.sh` reads `CI_PLAN_DURATIONS_FILE`
   (the plan job's `bin/ci-durations.sh fetch` file, the same one every shard
   splits by). When it holds a `<suite>\t<seconds>` row, the count is
   `suite_shard_size` in `bin/lib/suite-runner.sh`: the fewest shards whose
   slowest shard is within `CI_SHARD_BUDGET_S` (default 480 s of suite time, no
   job setup), by the same LPT the shards use. It never passes `CI_MAX_SHARDS`
   or the suite count. A suite longer than the budget cannot be split; the plan
   then uses the fewest shards that reach that suite's time.
   Every plan prints one line:
   - `ci-plan: sizing: time (<api|cache|artifact>), <n> shard(s), slowest est <s>s of budget <b>s, cap <m>`,
     plus `; over budget (biggest suite <s>s)` or `; cap reached`; or
   - `ci-plan: sizing: count, ceil(<count>/<per>) cap <m> (<why>)`, where why is
     `no durations file`, `durations file unreadable`, `no data rows`,
     `weights are the seed <sha12>`, `weights have no source` or
     `cannot load suite-runner`.
   Time sizing runs only on a real fetch: the file's first line is
   `# source: api`, `# source: cache` or `# source: artifact run <id>`. On
   `# source: seed <sha>` (the fetch fell back to the last committed copy) or
   `# source: none`, the count rule answers. The seed is from 2026-10-09 and
   has no row for 1046 of today's 2345 suites, so sizing by it would plan
   from the median weight for 45% of the corpus.
   The plan job publishes `sizing`, `shard_budget_s` and `max_shards`. Each
   shard re-plans with those two values and the same file, so `--expect-n`
   still agrees when a repo variable changes between the jobs.
2. **The workflow fetches the weights before the plan.** In
   `.github/workflows/harness-ci.yml` the plan job's "the shard weights
   (ci-durations)" step now runs before `bin/ci-plan.sh`, on every plan run
   (no `if:`). The upload to the shards keeps its `corpus == '1'` condition.
   `harness-nightly.yml` is not changed: it passes no durations file, so the
   nightly plan keeps the count rule (with the new cap).
3. **Sizing knobs as settings rows.** `catalog/lanes.d/ci-plan-settings.json`
   has two required knobs: `CI_MAX_SHARDS` (default 12, 1..64) and
   `CI_SHARD_BUDGET_S` (default 480, 60..3600). `bin/ci-plan-settings.sh`
   (hub, `23 * * * *`) projects each into the repo variable of the same name.
   Its tick line ends in ` sizing=CI_MAX_SHARDS:<r>,CI_SHARD_BUDGET_S:<r>`, with
   r one of `unset`, `refused`, `same`, `set`, `would-POST`, `would-PATCH`,
   `failed`. A refused or failed name raises one warn alert,
   `ci-plan-settings-sizing:<slug>`. The code fallbacks (8 and 480) apply only
   when the repo variable is not set.
4. **A workflow edit selects its readers (merge-queue batch only).**
   `catalog/ci-batch-escalate.tsv` has two `allow` rows,
   `.github/workflows/*.yml` and `*.yaml`. Under `TI_BATCH_SELECT=1`,
   `bin/test-impact.sh` selects a top-level workflow file through its map rows:
   the suites that name it, the suites that scan the whole
   `.github/workflows/` directory, and the always set. A workflow file that no
   suite names gets the always set and those directory scanners. The reason
   says `workflow: <path> selects its readers (BH-6876)`, or
   `workflow: non-test jobs only (<jobs>)` for a harness-ci.yml diff that
   `bin/test-impact-workflow.sh` classifies (BH-6688). The BH-6688
   `TI_WORKFLOW_BASE` plumbing is removed.
   Two `spa`/`worker` rows for `.github/workflows/harness-ci.yml` keep the
   console-ui and worker-jobs jobs on for a harness-ci.yml edit, because that
   file defines both jobs.
   These still escalate: any other `.github/` path (an action, CODEOWNERS), a
   nested `.github/workflows/<dir>/x.yml`, and every self row
   (`bin/ci-plan.sh`, `bin/test-impact*.sh`, …). The ordinary PR select and the
   builder gate keep `full: infra change` for a workflow path.
   The nightly full corpus (BH-6838) is the backstop for a runner change that a
   narrow batch misses.
   An allow row beats an escalate row, a `CI_FULL_TRIGGERS` `+` row included.
   To make workflow edits escalate again, remove the two allow rows by PR.
   The culprit finder's member reach (`bim_reach` in
   `bin/lib/mc-batch-impact.sh`) uses the same batch select. So a member that
   edits a top-level workflow file now reaches that file's readers, not `*`.
5. **The replay reports the slowest suites and the slowdown's parts.** `bin/ci-plan-split-replay.sh`
   hands the fetched weights to the planner (so `new_n` is the time-sized
   count) and passes `CI_SHARD_BUDGET_S` through. After `durations:` it prints
   `slowest: <rank> <suite> <s>s` for the 20 heaviest suites and
   `over budget: <k> suite(s) over <b>s`. With no real fetch it prints
   `slowest: - (no durations)`. It also prints, after `durations:`:
   - `weights source: <api|cache|artifact|seed|none>`;
   - `corpus: <n> suites at <sha12>` (`tests/*.sh` + `tests/mc/*.sh` in
     HEAD's tree);
   - `speed: median <r>x over <k> re-measured suites; <c> of <n> shared
     rows carry the seed value (now vs seed <sha12>)`: for each suite in both
     the fetched file and the seed whose row is not the seed's own row (other
     seconds or another run), the fetched seconds over the seed seconds. A
     carried row is counted in `<c>` and never in the median.
     `speed-top20: median <r>x over <t> re-measured` does the same over the 20
     heaviest seed rows. With 0 re-measured rows the lines are
     `speed: - (0 of <n> shared rows re-measured; all carry the seed value)`
     and `speed-top20: - (none of the 20 heaviest seed suites re-measured)`.
     When the fetch IS the seed, or no seed is in the history, both say
     `- (<why>)`.
   These lines read local git and the already-fetched file. No new GitHub call.
6. **A page before the 45-minute limit.** New hub lane `ci-shard-watch`
   (`bin/ci-shard-watch.sh`, `*/5 * * * *`, `cron/lanes/726-ci-shard-watch.cron`,
   registry `catalog/lanes.d/ci-shard-watch.json`). Each tick reads the
   in-progress Harness CI runs, then the latest jobs of at most
   `CI_SHARD_WATCH_MAX_RUNS` (default 10) of them, oldest first. A job is slow
   when its name starts `Tests, traced (shard`, it is `in_progress`, and it
   started `CI_SHARD_ALERT_MIN` (default 35) or more minutes ago. Any slow job
   raises one critical alert, `ci-shard-slow:<slug>` (Telegram now; a warn goes
   to the digest, which arrives after the 45-minute limit). The text names up to
   5 jobs as `run <id> shard <s> <min> min [<runner>]`, then `+<n> more`.
   lane-alert keeps one open id, so one episode is one page. The lane resolves
   the id only after a complete read that saw no slow job: a failed runs read,
   a failed jobs read or a run past the cap changes nothing. A 5-minute cadence
   means the page comes between minute 35 and minute 40. One log line per tick
   in `logs/ci-shard-watch.log`: `runs=<n> read=<r> deferred=<d> slow=<k>
   action=<raise|resolve|none>`. GitHub cost: at most 1 + 10 reads per tick,
   skipped while `bin/lib/gh-budget.sh` says the budget is low.


## Why 12 shards

The ticket asks to raise `CI_MAX_SHARDS` if the runner budget allows. the operator
approved the repo variable `CI_MAX_SHARDS=12` on 2026-10-15 at 15:05Z
(comment 6197071504), so the registry default is 12 and the first projection
tick writes nothing new (`same`). docs/CI-RUNNERS.md says MonkCI bills per
job-minute and documents no concurrency cap. More shards add job setup
minutes, not suite minutes. `bin/ci-minutes-watch.sh` pages over
`CI_MINUTES_DAY_MAX` as before. An operator changes the cap with one settings
row.

## Operator steps

1. Run the replay from a box that can read the GitHub API:
   ```
   CI_REPO=example-org/cromford CI_WORKFLOW="Harness CI" CI_MAX_SHARDS=12 CI_SHARD_BUDGET_S=480 bin/ci-plan-split-replay.sh --last 20 --repo example-org/cromford --out /tmp/replay-6876.tsv
   ```
   Post the summary lines on the PR: `full fires`, `median wall`, `verdicts`,
   `durations`, `weights source`, `corpus`, `speed`, `speed-top20`, the 20
   `slowest:` lines and `over budget`. If `median wall` new est is over 10
   min, say so first.
2. For the same 20 runs, list each run's `Tests, traced (shard ...)` jobs
   (`gh api repos/example-org/cromford/actions/runs/<id>/jobs`) and post
   the shard count, the slowest shard's minutes and the runner name prefix
   per run.
3. If the defaults are wrong, set the settings rows
   `lane.ci-plan-settings.CI_MAX_SHARDS`,
   `lane.ci-plan-settings.CI_SHARD_BUDGET_S`,
   `lane.ci-shard-watch.CI_SHARD_ALERT_MIN` or
   `lane.ci-shard-watch.CI_SHARD_WATCH_MAX_RUNS`. With no row, the registry
   defaults (12, 480, 35, 10) apply.
4. After merge, check the first projection tick on the hub:
   `grep sizing= logs/ci-plan-settings.log` shows
   `sizing=CI_MAX_SHARDS:same,CI_SHARD_BUDGET_S:set` once, then `:same`.
5. Check the next merge-queue batch: the "CI plan (what this run tests)" job
   log has `ci-plan: sizing: time (api), ...`, or a `count (...)` line with
   its reason.
6. Check the alert lane on the hub: `bin/ci-shard-watch.sh --dry-run` prints
   the counts and no alert while no shard is past 35 min, and
   `logs/ci-shard-watch.log` gets one line every 5 min.

## Tests

- `tests/ci-plan-time-sizing.bh-6876-test.sh`: S1-S10 (sizing, the source
  gate), W1 (the workflow wiring, parsed), R (the replay's `slowest:` and
  `over budget:` lines).
- `tests/ci-plan-split-replay-speed.bh-6876-test.sh`: V1-V6 (`weights
  source:`, `corpus:`, `speed:`, `speed-top20:`; V5-V6: a row carried from
  the seed is not counted as a measurement).
- `tests/ci-plan-workflow-narrow.bh-6876-test.sh`: N1-N7.
- `tests/ci-plan-settings-sizing.bh-6876-test.sh`: P1-P8.
- `tests/ci-shard-watch.bh-6876-test.sh`: A1-A10.
- Changed premises: `tests/ci-plan-batch-impact.bh-4968-test.sh` (E1, 3a, 11),
  `tests/ci-plan-escalation-own-diff.bh-6490-test.sh` (O2, R1),
  `tests/test-impact-workflow.bh-6688-test.sh` (W7, W8, W9),
  `tests/ci-durations.bh-5518-test.sh` (CD-7),
  `tests/ci-plan-nightly-split.bh-6838-test.sh` (A3),
  `tests/impact-map-infra-paths.bh-6688-test.sh` (C7b),
  `tests/queue-eject-culprit.bh-4980-test.sh` (U2) and
  `tests/queue-culprit-flip.bh-5373-test.sh` (N3).
