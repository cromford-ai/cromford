# CI cost lanes (each tree tested exactly once, in the merge queue)

**What it is:** how `.github/workflows/harness-ci.yml`, `.mergify.yml` and
`bin/main-red-detector.sh` fit together since 2026-09-24 (the operator: "no duplicate
CI, each tree gets tested exactly once"): `bin/ci-plan.sh` (the plan),
`bin/test-trace-safety.sh --gate` (one traced run of the corpus that yields
both verdicts), `bin/ci-verdicts.sh` (the two fan-in checks), the
the `queue_check=` conf key in `bin/mergify-template.sh`,
a workflow `concurrency:` block and the detector's merge-queue arm.

**Why.** MonkCI billed 63,269 / 93,467 / 125,738 minutes on 09-21 / 22 / 23,
all overage, most of it cromford. One tree was tested two or three times:
on the PR (twice: bare for `Pure-logic gate fixtures`, again under the tracer
for `Tests cannot touch a real harness`), in the Mergify batch, and again on
the push to main. Superseded PR runs kept burning with nothing to cancel them.

**Who runs what:**

| event | jobs | corpus |
|---|---|---|
| ordinary PR | `Syntax + shellcheck + config integrity` (now also the sourcing lint, model-literal lint and the two gate fixtures), `Test determinism lint`, `Prompt replay evals` | none — the builder's `bin/test-impact-gate.sh` before push is the pre-test |
| batch draft (`mergify/merge-queue/*`) | all of the above + `CI plan`, `Tests, traced (shard i/n)`, the two fan-ins, the SPA, the jobs worker | the FULL corpus once, traced, 8 shards |
| push to main by `mergify[bot]` whose tree is a green batch head (or that main already moved past: a batch-merge intermediate) | lint + determinism + `CI plan` | none — the queue tested exactly this tree |
| any other push to main (a human, an admin merge, a batch merge that stopped halfway, an unreadable queue) | as the batch draft | the FULL corpus once, on that tree |
| `full` label (takes effect on the PR's next push), workflow_dispatch | as the batch draft | full |

`.mergify.yml` (rendered from `config/mergify/repos/cromford.conf`):
`queue_conditions` ask for the three fast checks, `merge_conditions` for all
seven (Mergify evaluates them on the draft). With the two lists different,
Mergify never checks a PR in place: every batch, even a batch of one, is a
draft, so the corpus runs once per batch and never on the PR. Both queues, hotfix included.
The seven check names are unchanged.

**One run, two verdicts.** Each shard runs `bin/test-trace-safety.sh --gate`
(`tests/*.sh` + `tests/mc/*.sh`, every test traced, a failing test's output
printed, a timeout a failure) and writes `shard-<i>.txt` (`tests= failed=
hits= pure= trace=`) only when the scan completed. `Pure-logic gate fixtures`
= `bin/ci-verdicts.sh pure`, `Tests cannot touch a real harness` =
`bin/ci-verdicts.sh trace`: a failed test never reddens the safety check, a hit
never reddens the pure-logic one, and a missing verdict, a failed plan or a
shard total that differs from the planned count reddens both.
`HARNESS_TEST_SANDBOX` stays unset on the traced lane (#388).

**Concurrency.** Keyed on event + PR number (ordinary PR) or sha (a batch
draft, a push, a dispatch). A superseded PR run is cancelled; a batch draft, a
push to main and a dispatch never are. `labeled` is deliberately not a trigger:
a label run's skipped checks would replace a queued PR's green ones, and
Mergify drops a PR whose queue_conditions stop matching.

**Nothing lands around the queue.** Since BH-2199 (on main before this PR
landed; the operator 2026-09-25: the queue owns main) no path merges a `queue_rules`
repo directly: a silent queue HOLDS the PR READY (`MERGE_HELD`, one daily
"READY PRs are held, NOT merged" alert), an unreadable `.mergify.yml` makes the
provider `unknown` and holds, and Mission Control's merge button enqueues. So
this lane adds no park arm and no merge-button branch of its own (both were in
earlier rounds of #2220 and were dropped in the rebase as redundant). What it
keeps: `@mergifyio queue` is posted once per (PR head, command) — the ledger is
`state/merge-conductor/mergify-asked/`, a new head asks at once, the same head
again only after `MC_MERGIFY_REASK_S` (lib.mc-queue, default 6h; 0 = once per
head), and only a post `mc_mergify_command` (C2, the PAT poster) accepted is
recorded. The label is still re-applied every tick (idempotent).
`bin/lib/queue-batch-only.sh` (`mc_queue_batch_only`: Mergify, and
merge_conditions ask for a check queue_conditions do not) is read by the
resolver's green-at-head guard, and it FAILS CLOSED: a `.mergify.yml` that
cannot be read (403, outage, `unknown` provider, undecodable content) answers
"batch-only", so a fast-checks green is never believed on a guess. A PR the queue ejected is briefed
from its red batch (`br_ci_log` falls back to the newest red
`mergify/merge-queue/*` run naming `#N`), and `green-at-head` never releases a
`queue-ejected-twice` park on a fast-checks green: only a green batch carrying
the PR does.
The brief's batch is `br_queue_red_batch`: `failure`/`timed_out` only (a newer
cancelled re-embark never hides the red one), newer than the newest green batch
naming the PR, and a batch not `stacked on` another first. The push-to-main
check reads the newest 20 green batches in the API's own newest-first order
(a sha-sorted `unique` could drop the matching batch), and a runner with no
`gh` says so as a `::warning::` before it runs the corpus.

**Mergify knobs.** `max_checks_retries: 0`, `max_parallel_checks: 8`,
`checks_timeout: 60 min`. Every batch is a full-corpus run (~16 jobs, ~160
billed min), so a red batch is the expensive event: with 8 stacked batches and
one retry, one bad PR at the head cost ~15-17 corpus runs; with 0 retries and 4
in flight (#2220) it was the red batch, at most 3 discarded speculative ones and
the bisection, ~5-7. On 2026-09-28 the operator moved it back to 8 in flight with 0
retries (~9-11 corpus runs per red head batch): throughput over CI minutes,
8 x 8 = 64 PRs in flight, roughly double the merge rate at 4.

**Main-red.** Push runs carry no corpus, so the detector's fifth arm reads the
merge queue: for repos in `MAIN_RED_QUEUE_REPOS` (default the harness repo) it
walks the newest required runs on `mergify/merge-queue/*` heads until a green
one, counting a red batch only when the PR numbers in its title share none with
a batch already counted (speculative batches stack; one bad PR is one culprit).
A batch titled `stacked on N pull requests ahead` never counts. Only `failure`
is red code: `timed_out` and `startup_failure` are the runner or the platform,
and are skipped (neither red evidence nor a green that ends the walk).
`MAIN_RED_QUEUE_STREAK` (3) independent red batches freeze merges
(`reason=queue`). A queue freeze clears on a green batch newer than it, or on a
green `workflow_dispatch` run of the workflow on main newer than it (the way out
when the queue is empty and no batch will run) — never on a failed read, never
because the reds scrolled off the page (the read is 100 runs), and never on
main's own push runs, which are fast checks. `MAIN_RED_QUEUE=0` disarms it.

**Red batches per day** is the number that decides whether this saves money: if
batches go red often, every red one costs the batch plus its discarded stack
and the split. Count it with one read (the job's token or any read token):

```bash
gh api "repos/example-org/cromford/actions/runs?event=pull_request&created=>=$(date -u +%F)&per_page=100" \
  --jq '[.workflow_runs[] | select(.head_branch|startswith("mergify/merge-queue/"))] | group_by(.conclusion) | map({(.[0].conclusion // "running"): length}) | add'
```

More than ~5 red batches a day for a few days means the PR-time pre-test (the
builder gate) is letting too much through, and the fix is there, not in
re-adding PR-level corpus runs.

**Known trade-offs.** A batch goes red more often without PR-level tests (the
builder gate and the hot-file fragments are the mitigation), and Mergify splits
a red batch at the cost of more runs. A real test failure now shows on the
batch draft, not on the PR head, so the conductor sees a green PR that was
ejected: its requeue-once / `queue-ejected-twice` path parks it, and the
resolver briefs the fix round from the batch's failing log (above).

**How to drive it:**

| what | how |
|---|---|
| the plan: queue full, PR selection for the `full` label, sizing, knobs, never-empty, --expect-n | `bash tests/ci-plan-test.sh` |
| the shard count by recorded duration on the ticket's numbers (BH-6491): 93 suites with five 6-min ones give >= 3 shards of <= 12 min, the logged count fallback, sizing after reuse, the `ci-plan sizing` notice | `bash tests/ci-plan-shard-by-duration.bh-6491-test.sh` |
| the sizing replay and re-measure over real batches (BH-6491): actual max shard, runner minutes, predicted max, no-ledger count | `bash tests/ci-shard-replay.bh-6491-test.sh` |
| one traced run, two verdicts, verdict file only on a completed scan | `bash tests/trace-safety-gate-test.sh` |
| each fan-in judges its own column; missing / short evidence is red for both | `bash tests/ci-verdicts-test.sh` |
| who runs what, concurrency, Mergify queue vs merge conditions, in-place off | `bash tests/harness-ci-cost-shape-test.sh` |
| queue_check= renders; other confs unchanged | `bash tests/mergify-queue-check-test.sh` |
| the single traced matrix and its two fan-ins | `bash tests/ci-shard-split-test.sh` |
| main-red fires from independent red batches, not from a stack; infra failures skipped; a dispatch clears a stuck freeze | `bash tests/main-red-queue-arm-test.sh` |
| the queue-only predicate, failing closed on an unreadable config | `bash tests/queue-batch-only-test.sh` |
| a queue-only repo is held like any Mergify repo (BH-2199, never merged directly); one queue ask per head | `bash tests/hotfix-conductor-degraded-test.sh` (section 7) |
| a queue-ejected PR's fix brief is its red batch's log | `bash tests/br-ci-log-queue-batch-test.sh` |
| a fast-checks green never releases a queue-ejected park | `bash tests/blocked-resolver-green-at-head.bh-1671-test.sh` (section 7) |
