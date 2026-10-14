# Each tree is tested exactly once, in the merge queue

Doc: CI-RUNNERS

## What changed

- **An ordinary PR runs only the fast checks**: syntax + shellcheck + config
  integrity (which now also carries the sourcing lint, the model-literal lint
  and the two gate fixtures), the determinism lint and the prompt-fixture check.
  No test corpus. The builder's `bin/test-impact-gate.sh` before push is the
  pre-test.
- **The Mergify batch draft (`mergify/merge-queue/*`) runs the corpus once**, as
  `tests-shard`: `bin/test-trace-safety.sh --gate` over 8 shards, both verdicts
  from one traced run. `Pure-logic gate fixtures` and `Tests cannot touch a
  real harness` are fan-ins over the verdict files (`bin/ci-verdicts.sh`). The
  SPA and jobs-worker jobs run there too. The seven check names are unchanged.
- **`.mergify.yml`**: `queue_conditions` = the three fast checks,
  `merge_conditions` = all seven, in both queues (different lists, so every
  batch is a draft; Mergify has deprecated `allow_inplace_checks`).
  Rendered from `config/mergify/repos/cromford.conf` via the new
  `queue_check=` key; other confs render unchanged.
- **A push to main runs lint + determinism** (and the corpus once if the queue did not test that tree — see below). `bin/main-red-detector.sh`
  gained a queue arm: 3 independent red batches (no shared PR number, no green
  batch since) freeze merges with `reason=queue`. Knobs `MAIN_RED_QUEUE`,
  `MAIN_RED_QUEUE_REPOS`, `MAIN_RED_QUEUE_STREAK`, `MAIN_RED_QUEUE_PER_PAGE`.
- **Superseded PR runs cancel** (`concurrency:`), never a batch or a push.
- **The metered prompt replay** runs on the PR only, never re-spent on a batch.

## Review round (independent adversarial review of #2220)

- A PR that fails only in the queue is briefed from its red batch
  (`br_ci_log` fallback), and a fast-checks green no longer releases a
  `queue-ejected-twice` park on a queue-only repo.
- Nothing lands around the queue on a queue-only repo. (Rebase onto main,
  2026-09-25: BH-2199 already removed every direct merge on a `queue_rules`
  repo — the operator's decision, the queue owns main — so this PR's own park arm and
  merge-button branch were dropped as redundant; `mc_queue_batch_only` now
  fails closed on an unreadable `.mergify.yml`.)
- A push to main that the queue did not test (not `mergify[bot]`, or a tree no
  green batch had, unless main already moved past it) runs the full corpus once.
- Mergify: 0 retries, 4 parallel batches, 60 min checks timeout.
- The queue arm skips `timed_out` / `startup_failure`, clears on a green
  `workflow_dispatch` run on main, and reads 100 runs.

## Why

MonkCI overage: 63K / 93K / 126K billed minutes on 09-21..23. A tree was tested
two to three times: twice on the PR, once in the batch, once on push to main.

## Watch for

- Batches go red more often without PR-level tests; Mergify splits them.
- A real test failure shows on the batch draft, not the PR head. The conductor
  sees a green PR that was ejected (requeue once, then `queue-ejected-twice`).
- `review-autopilot` shows the model `…=SKIPPED` for the four merge-only checks
  on a PR; its prompt may read that as missing tests.
- A test that passes bare but fails under the tracer would now fail the
  pure-logic check. A full-corpus differential in a Linux container (bare vs
  traced) found none.
