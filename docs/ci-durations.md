# CI suite durations (the shard weights)

BH-5518 C1, 2026-10-08. `catalog/ci-suite-durations.tsv` is not committed. CI composes it from its own runs.

## What the file is

The file gives the cost of each `tests/` suite on a CI shard. Two readers use it:

- `bin/lib/suite-runner.sh` `suite_shard_plan` balances the traced shards by it (plan item A2, 2026-09-28).
- `bin/fast-lints.sh --list` picks the fast always-suites for the PR lint job (BH-3860).

It is a sort hint. No value in it changes WHICH suites run or what the verdict is. A suite with no row weighs the median of the file. With no file, every suite weighs the same and the split is round-robin.

Columns: `<suite>\t<seconds>\t<run>\t<newest values>`. Both readers use columns 1-2 only. `#` lines are comments.

## Why it left git

Every PR that added an always-run suite had to add a row. Two such PRs added rows at the same place and conflicted. A PR that forgot the row turned every merge-queue batch red in `tests/fast-lints-data.bh-3860-test.sh` D1. `tests/trap-target-safety.bh-5191-test.sh` did that on 2026-10-07: no batch went green until a row landed.

## The chain

| Where | What | Artifact |
|---|---|---|
| `plan` job | `bin/ci-durations.sh fetch` | `ci-durations` (3 days) |
| `tests-shard` jobs | read `ci-durations` as `SUITE_DURATIONS_FILE`; `bin/test-trace-safety.sh --gate --timings` | `suite-timings-<n>` (3 days) |
| `decisions` job | `bin/ci-durations.sh merge` over `ci-durations` and every `suite-timings-*` | `ci-durations-next` (30 days) |
| `lint` job (PRs) | `bin/ci-durations.sh fetch`, then `FAST_LINTS_DURATIONS` on the fast-lints step | none |
| `ci-timings` job (green Mergify batch) | `bin/ci-durations.sh post` over every `suite-timings-*` | the jobs worker's `ci_suite_durations` (BH-5653) |

`fetch` reads the jobs worker FIRST (BH-5653): `GET /api/ci/suite-durations`, when `JOBS_URL` and a token (`CI_DURATIONS_TOKEN` or `HARNESS_SECRET`) are set. A usable answer is written under `# source: api` and copied to the cache (`CI_DURATIONS_CACHE`). An unusable answer (an HTTP error, `{}`, no rows, `truncated`, a bad row) prints one `::warning::` and the cache is used under `# source: cache`. With no cache, `fetch` goes on to the chain below. The plan job gets the token only on a push, a dispatch or a Mergify batch. The lint job never gets it.

Then `fetch` reads the newest unexpired `ci-durations-next` of a run that is all of these: event `pull_request`, conclusion `success`, head branch `mergify/merge-queue/*`, and the same workflow name. A red batch, a `full` PR, a push and another workflow never feed the chain. It reads only the zip member `ci-durations.tsv`, into memory, and every row needs numeric seconds.

If that fails (no artifact, an API error, rc 75, a bad file), `fetch` uses the SEED: the last committed copy of the file, `git show <deleting commit>^:catalog/ci-suite-durations.tsv`. The checkout needs full history. With no seed, it writes a header-only file. Each fallback prints one `::warning::`. `fetch` always exits 0. The first line of its output names the source: `# source: artifact run <id>`, `# source: seed <sha>` or `# source: none`.

Every shard reads the ONE file from the plan job. A shard that cannot download it is red. A shard-local fallback would split by other weights than its siblings, and a split that drops suites looks like a fast green.

The decisions steps are `continue-on-error`. `Pure-logic gate fixtures` keeps its old meaning. A failed merge loses one link, and the next run reads the previous green link.

## The worker's ledger (BH-5653)

`ci-timings` runs after a Mergify batch whose shards all succeeded. `post` sends one body for the run: every rc 0 row, a suite timed twice at its larger value. The worker keeps the newest samples per suite (settings row `ci_suite_durations.window`, default 3) and their median (two values: the mean, named by the newer run). The same run posted again is a no-op. The same run with other rows is a 409 and writes nothing. The job is `continue-on-error`, and `.mergify.yml` does not name it.

`bin/ci-durations.sh seed` loads a durations file into the worker, one POST per source run. Run it once on the hub after the deploy: `cd /root/repos/cromford && bin/ci-durations.sh seed`.

A suite with no row in any source weighs the median of the file. A missing row never fails a gate: `tests/fast-lints-data.bh-3860-test.sh` D1 prints it as a note.

## The merge rule

`merge` is a pure function of its inputs. The same inputs give the same bytes, in any file order.

- Only rc 0 timing rows count. A suite timed twice in one run keeps the larger value.
- A measured suite puts its new value first in its list and keeps the 3 newest. `<seconds>` is their median (2 values: the mean), to 0.1 s. `<run>` is this run id.
- A suite not measured keeps its row byte for byte. A batch runs its impact set only, so most rows carry forward.
- A suite with no file under `--root` is dropped.

Method of the seed values (the old file header): seconds were the median over three green merge-queue batch runs, measured per suite as the gap between consecutive `--- <test> rc=N Ns` lines on one shard, never less than the suite's own reported seconds. `--timings` now measures the same thing directly, tracer overhead included, because that is what the shard pays. Until BH-6876 the row stopped at the test's exit and missed the trace scan that follows it (8.2 of 26.0 min on one shard of run 38795563393); the row is now written after the scan.

## Use it locally

```bash
bin/ci-durations.sh fetch --out catalog/ci-suite-durations.tsv   # needs gh auth, else the seed
HARNESS_TEST_SANDBOX=1 bin/fast-lints.sh --list
```

The default paths of both readers still point at `catalog/ci-suite-durations.tsv`, which is git-ignored. On a box with no file, `fast-lints --list` reports every suite as unmeasured, and `bin/test-impact-gate.sh` prints no `(fast)` tags. Nothing fails.

## Tests

- `tests/ci-durations.bh-5518-test.sh`: CD-1 to CD-10 (tracer timings, fetch, the negative list, merge determinism, a hostile zip, the fallbacks, the workflow wiring, not tracked, two PRs merge clean, fast-lints-data SKIP).
- `tests/fast-lints-data.bh-3860-test.sh`: SKIPs D1, D2 and D4 when no file is given. With a file, a missing row is a D1 note, and a non-numeric row is red.
- `tests/ci-durations-post.bh-5653-test.sh`, `tests/ci-durations-db.bh-5653-test.sh`, `tests/ci-durations-missing-row.bh-5653-test.sh`, `tests/ci-durations-workflow.bh-5653-test.sh` and `worker/jobs/test/ci-durations.bh-5653.test.js`: the worker's ledger.
- `tests/ci-shard-split-test.sh` block E: the balance on a fixture, and the library's default path.

## Not in this slice

The missing-rows report (#5302). The D1 ledger shipped in BH-5653.
