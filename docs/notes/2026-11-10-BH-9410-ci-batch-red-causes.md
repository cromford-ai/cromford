# BH-9410: one cause per red merge-queue batch

## What it adds

- `bin/ci-batch-red-report.sh --causes [--days N]`. It reads local harness files and makes one `GET /api/ci-batches` for the runner-minutes. It makes no GitHub read, no model call and no write. rc is 0 on every path.
- A `causes=` field at the end of the daily tick line in `logs/ci-batch-red.log`:
  `causes=main-red:<n>,seeded-random:<n>,first-run:<n>,gate-green-batch-red:<n>,flake:<n>,unchanged-requeue:<n>,unknown:<n>`.
  The seven counts sum to the readable red records of the window (red minus unread). `causes=-` means the lib did not load.
- The rule lives in `bin/lib/ci-batch-red-causes.sh` (`cbr_classify`).
- A catalog of known random-dependent tests, `catalog/ci-batch-red-random.d/*.tsv`, for the cause `seeded-random` (the operator's comment 6780574176 on #9410).

## Output of `--causes`

```
ci-batch-red-causes: repo=<r> days=<d> red=<n> minutes=<read|unreadable|not-configured> minutes_missing=<k>
run_id  created  culprit  cause  suites  minutes          (TSV, one row per red batch, oldest first)
cause   batches  runner_minutes                           (TSV, all 7 causes, fixed order)
```

- `created` is the batch's epoch. `culprit` is `<pr>@<head12>` or `-`. `minutes` is `billed_min` of the ci-batch-ledger row, or `-`.
- `minutes=unreadable`: the GET failed, did not parse, or said `truncated: true`. `minutes=not-configured`: no `JOBS_URL` or no jobs client.
- `minutes_missing` counts red batches with no `billed_min`. A runner_minutes sum with `minutes_missing > 0` is a partial sum.

## The rule

A culprit is a member PR of the batch with a merge-conductor eject line of cause `batch-red` or `checks` in `[created, created + CI_BATCH_RED_EJECT_WINDOW_S]`.

The first cause that holds is the cause:

| # | Cause | Holds when |
|---|---|---|
| 1 | main-red | a failing suite was red on main in `[created - CI_BATCH_RED_MAINRED_WINDOW_S, created]`: a baseline file `red` whose sha dir (or `.primed`) mtime is in the window, a `prime.tsv` `red` row of such a sha, or a gate.txt (mtime in the window) whose `baseline-red:` lists the suite |
| 2 | seeded-random | the batch has at least one failing entry, and EVERY failing entry (suite or `job:<name>`) equals the `match` of a catalog row with `since <= created < until` (`until` `-` = open). Exact string match only |
| 3 | flake | the batch's tree is the tree of a green batch record |
| 4 | unchanged-requeue | the culprit's eject line is `again`, or the same (pr, head) has an eject line before the batch |
| 5 | first-run | a culprit head has no gate.txt; its newest gate.txt rc is `could-not-run`, `no-selection` or `off`; or its `selection.txt` omits a failing suite. No culprit: a readable legacy `gate` line omits a failing suite |
| 6 | gate-green-batch-red | the culprit head's newest gate.txt is rc 0, or rc 1 whose `red:` omits a failing suite, and the suite is in its selection when a selection exists. No culprit: a legacy `gate` line lists the failing suite |
| 7 | unknown | none of the above |

Rules 4 to 6 need at least one failing suite. A batch that failed only on a `job:<name>` row is `seeded-random`, `flake` or `unknown`.

Why this order: a red main and a flake make every PR-level cause false, so they come first. `seeded-random` comes before `flake`: a known sampler fault also passes on a re-run, and it is the more specific cause. It needs EVERY failing entry to match, so a batch where a PR also broke a real suite never hides behind the sampler. A requeue of a head that already failed is waste whatever the first cause was, so it comes before the gate causes.

## Data sources (all on the hub)

| Source | Path |
|---|---|
| Batch records | `state/ci-batch-red/runs/<run_id>` |
| Eject lines | `state/merge-conductor/eject-cause/<owner>_<repo>_<pr>` |
| Selection-gate records | `builds/pool-<proj>-*/gate.txt`, `builds/<proj>-*/gate.txt`, and `<build>/selection-gate/selection.txt` |
| Main red evidence | `state/selection-gate/baseline/<sha>/<suite, / as _>`, `state/selection-gate/prime.tsv` |
| Known random-dependent tests | `catalog/ci-batch-red-random.d/*.tsv` next to the script, else `$HARNESS/catalog/ci-batch-red-random.d/` |
| Runner-minutes | `GET /api/ci-batches?repo=<r>&since=<iso>&limit=5000` (`billed_min` per `run_id`) |

The selection-gate baseline dirs are deleted after `SELECTION_GATE_BASELINE_KEEP_DAYS` (default 2). For older batches, main-red evidence comes only from the gate.txt `baseline-red:` field.

## The seeded-random catalog

`catalog/ci-batch-red-random.d/<ticket>-<name>.tsv`, one fragment per ticket. Columns, TAB-separated:

`match  test_file  settings_row  since_iso  until_iso|-  ref`

- `match` is a failing entry exactly as a batch record stores it: a suite path, or `job:<job name>` for a failed non-shard job.
- `since` is when the random draw reached the product code. `until` is the merge time of the fix, or `-` while the test is still exposed.
- `#` lines and lines with fewer than 5 fields are skipped. A row whose date does not parse is dropped, with one stderr line per run.

The first row: `job:Jobs worker — routes + schema`, test `worker/jobs/test/d1-overload-giveup.bh-7541.test.js` (G3), settings row `d1.stmt_stats_sample_pct` (BH-9076, seeded 2026-11-07). Its `until` is `2026-11-11T01:58:49Z`: the G3 fix landed on main in #9462 (BH-9430, commit 913adb33), merged at that time. The plan expected the fix in #9432; it landed through #9462.

## Seeded-random audit

the operator's comment 6780574176: "Ten other worker test files count rows over `sqlite_master`; check which of them pass a `ctx`."

`withStmtStats` (`worker/jobs/src/lib/stmt-stats.js`) samples a request with `Math.random` only when the test passes a `ctx` whose `waitUntil` is a function. A sampled request writes `d1_stmt_stats` rows and adds one `ctx.waitUntil` flush batch on the raw binding.

Method, on this build's tree (main 89f2fc15):
1. `grep -l sqlite_master worker/jobs/test/*.js` gives 53 files. `grep -l waitUntil worker/jobs/test/*.js` gives 9 files. Only 1 file is in both lists.
2. Each of the 9 `waitUntil` files ran twice under `node --test`: with `Math.random = () => 0` (every request sampled), and with the normal draw.
3. Control: the pre-fix version of `d1-overload-giveup.bh-7541.test.js` (`913adb33^`) fails G3 with `Math.random = () => 0` and passes with `Math.random = () => 0.999`. So the method finds an exposed test.

| File | Reads sqlite_master | Passes ctx | Sets the pct row | Forced sampling | Exposed | Why |
|---|---|---|---|---|---|---|
| d1-overload-giveup.bh-7541 | yes | yes | yes (BH-9430) | 14 pass | was yes, fixed | G3 asserts that only `d1_overload_streaks` changed; a sampled request also wrote `d1_stmt_stats`. #9462 sets the row to 0 |
| d1-retry.bh-6690 | no | yes | no | 21 pass | no | no row or statement count over `d1_stmt_stats` |
| d1-retry.bh-6813 | no | yes | no | 9 pass | no | S1 counts raw-binding execs (6), but it stays green with every request sampled |
| flags.bh-4154 | no | yes | no | 14 pass | no | no row or statement count over `d1_stmt_stats` |
| pr-gate-overload.bh-7764 | no | yes | no | 9 pass | no | counts `pr_state_events` rows only |
| pr-state-overload.bh-9325 | no | yes | yes | 12 pass | no | sets the row |
| sentry.bh-5618 | no | yes | no | 8 pass | no | counts Sentry posts; a failed flush logs, it does not post |
| verdict-overload.bh-6807 | no | yes | no | 5 pass | no | no row or statement count over `d1_stmt_stats` |
| stmt-stats.bh-9076 | no | yes | yes | skipped: the subject suite | no | it injects `random` |
| the other 52 `sqlite_master` files | yes | no | - | - | no | `withStmtStats` returns early with no `ctx` |

Result: only `d1-overload-giveup.bh-7541` was exposed, and #9462 fixed it. The catalog has one row. No owed worker-test fix.

## Knobs

| Env | Default | Range | Settings key |
|---|---|---|---|
| `CI_BATCH_RED_EJECT_WINDOW_S` | 7200 | 600..86400 | `lane.ci-batch-red-report.ci_batch_red_eject_window_s` |
| `CI_BATCH_RED_MAINRED_WINDOW_S` | 7200 | 600..86400 | `lane.ci-batch-red-report.ci_batch_red_mainred_window_s` |
| `CI_BATCH_RED_LEDGER_LIMIT` | 5000 | 1..5000 | `lane.ci-batch-red-report.ci_batch_red_ledger_limit` (the row cap of the `--causes` ci-batches GET; the worker max is 5000) |

## Owed steps on #9410

1. On the hub, run `bin/ci-batch-red-report.sh --causes --days 7`. Paste the output in the PR and in #9410. This box has no hub state, so this build did not run it.
2. Fix the top 2 causes from that table in later slices (C1, C2 of #9410), one suite per fix. For `unchanged-requeue`, check the merge-conductor knob `MC_EJECTED_REQUEUE` first: the value `never` may be the fix. Starting points on main for C1 and C2: the `MAIN_RED` freeze acts at eject time only; the pre-queue gate already records `could-not-run`; the conductor knob `MC_EJECTED_REQUEUE` sets the requeue of an ejected PR.
3. Seven days after C1 and C2 deploy, read the week line and the `causes=` field. The target: red rate under 25 %, each fixed cause under 3 batches.
