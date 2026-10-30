# The pre-queue fast lint set: a READY head merged onto main, before the queue (BH-8473)

Doc: MERGE-CONDUCTOR

## What changed

1. **`pq_gate` runs a third hook, `pq_fastlint`** (`bin/lib/mc-prequeue.d/fast-lints.sh`).
   It runs after `pq_restamp` and `pq_mignum`, before the cache read, with
   `MC_PREQUEUE_GATE` at 0 or 1. When it can act (`pq_fastlint_wanted`: knob
   on, `ACTIONS=1`, and the runner and catalog under `$MC_H`), the gate-off
   early return no longer happens, and the main tip is read.
2. **The hook.** Under the project git lock (wait `MC_PREQUEUE_GIT_LOCK_WAIT_S`,
   5 s) it fetches main and the head into the conductor clone, runs
   `git merge-tree --write-tree <main> <head>` and `git commit-tree` (a local
   object, no ref, no push). After the lock it builds a snapshot with
   `bin/lib/rules-pack-snapshot.sh` (auto gc off). Then it runs
   `bin/prequeue-fast-lints.sh` as nobody with a clean environment. It makes
   no GitHub or Mergify API call. It writes one log line per call:
   `<key> PREQUEUE_FAST_LINT <green|red|none> head= main= s= red= unfinished= preexisting= could-not-run= reason=`.
3. **A red parks the row.** An item that is red on the merged tree and green on
   main makes `pq_gate` answer `red` with `PQ_SUITES` set to its suite name and
   `PQ_PATH` empty. The READY arm then parks the row BLOCKED_HUMAN
   `prequeue-red: <suites> on main <m12> — the head merged onto current main fails them`.
   That reason is resolver-owned, so `bin/blocked-resolver.sh` runs its
   existing prequeue-red fix round. The PR is not enqueued.
4. **Fail open.** A conflict, a busy lock, a failed fetch, no setpriv, a set
   that cannot run, an item that the budget cut, and an item that is red on
   main too all go on to the queue as before, with one `none` or `green` line.
5. **The set** is `catalog/prequeue-fast-lints.tsv` (10 rows, longest first).
   The settings row `lane.merge-conductor.mc_prequeue_fast_lints_set` picks rows
   by id; empty means every row. A command is never a settings row.
   `tests/lanes-registry.bh-2205-test.sh` (231 s, a meta-test of the suite
   below) is not a row.
6. **`tests/lanes-registry-test.sh` has an opt-in static mode.**
   `LANES_REGISTRY_SECTIONS=static` skips sections 2-6, 12, 16 and 19. It runs
   1, 7-11, 13-15, 17, 18 and 20 in about 28 s (the full run is about 135 s).
   Section 7 (no missing knobs, about 16 s) stays in because it catches the
   #8344 class: a wired script reads a knob the registry does not carry.
   Without the variable, every section runs as before.
7. **The main baseline cache.** `$MC_STATE_DIR/prequeue/fastlint-main/<main>.<id>`
   holds the rc of item `<id>` on main `<main>`. The existing 7-day `pq_prune`
   removes it.

## Knobs (lane merge-conductor)

| knob | default | meaning |
|---|---|---|
| `MC_PREQUEUE_FAST_LINTS` | 1 | 0 = off |
| `MC_PREQUEUE_FAST_LINTS_BUDGET_S` | 90 | the set's wall budget, base re-runs included (a red lanes-registry item runs about 29 s twice, so 60 s cut its base run and the park failed open); never more than the gate's call budget left minus the reserve |
| `MC_PREQUEUE_FAST_LINTS_JOBS` | 4 | items at once |
| `MC_PREQUEUE_FAST_LINTS_RESERVE_S` | 10 | seconds kept back from the gate's call budget left, so the call bound never cuts the hook (lead review BLOCK hardcoded-knob, verdict row 4373) |
| `MC_PREQUEUE_FAST_LINTS_SET` | "" | comma list of catalog ids; empty = every row |

Rollback: set `lane.merge-conductor.mc_prequeue_fast_lints` to 0.

## Measured (a build box, 8 cores, 2026-10-26)

- The whole set on this repo plus a 50-file commit, no base tree, 4 jobs:
  49 s and 56 s on two runs, before the catalog was put longest first.
- The snapshot of this repo (177 MB, about 14,000 files) takes about 25 s.
  That time is outside the 90 s set budget and outside the git lock.

## Why

On 2026-10-25/26 nine Mergify batch drafts went red on fast, deterministic
checks from one member each. With `MC_PREQUEUE_GATE=0` (BH-8062), `pq_gate`
answered proceed with no check. Seven of those reds came from a suite in this
set: lanes-registry (#8344, #8348, #8377), the trace gate and
context-budget-manifest (#8346, #8370, #8401), worker-node-lanes-build
(#8361, #8370) and mc-split-layout (#8377). The other causes (#8344's
fly-pool-pr-unreadable, #8438's no-state-files and no-harness-export, #8461's
review fixtures) are not rows in this set.
