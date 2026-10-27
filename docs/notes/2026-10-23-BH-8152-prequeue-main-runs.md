# BH-8152: the pre-queue gate finds its run by the main sha

Ticket: example-org/cromford#8152. The ticket says the merge conductor
dispatches `prequeue-gate.yml` once per READY PR, not once per main sha.

## What the run list showed

The `prequeue-gate.yml` runs from 2026-10-22T11:00Z to 2026-10-23T11:25Z:

- 281 runs, 273 distinct run titles `prequeue pr=<n> head=<h> main=<m>`, 83
  distinct `(pr, head)` pairs.
- 8 runs were exact duplicates: the same title on the same main, dispatched
  again 7 to 60 min later. These are the waste.
- The other runs on one main are different PRs. Each run merges ITS head onto
  main and runs ITS impact selection. They are not copies of one check.
- 277 of 281 runs have `head_sha` equal to the title's main, because the
  dispatch uses `--ref main`.

## The cause

`pq_find_run` (adopt) and `pq_read_run` (settle) read only the 30 newest runs
of the workflow. One main gets 15-20 runs, so after 30-60 min a run is past
them. A worker with no cache entry (a lane-run machine has its own state dir)
then did not see the run and dispatched the same title again. A pending run
past the 30 newest was not read until `MC_PREQUEUE_DEADLINE_S` (2400 s).

## What changed

- `bin/lib/mc-prequeue.d/main-runs.sh` (new). `pq_main_runs` reads
  `runs?event=workflow_dispatch&head_sha=<main>&per_page=<page>` once per tick,
  repo and main (memo in `MC_TICK_DIR`). Every READY PR on that main shares the
  read. `pq_main_run_find` prints the newest run with the exact title.
- `pq_find_run` and `pq_read_run` look up the title there first, and read the
  30 newest runs only on a miss or a failed read.
- `pq_dispatch` (plain gate only) reads the list again with no memo, under its
  lock, before `gh workflow run`. A run with the exact title in any state is
  written `pending <created> <run_id>`, the answer is rc 3 (hold), and the log
  gets `PREQUEUE dedup #<n> head=<h12> main=<m12> run=<id> status=<st> -> no-dispatch`.
  A failed read dispatches as before and logs `... -> read-failed, dispatched`.
  A named-suites run (`batch-solo.sh`) is never deduped.

## Knobs (lane merge-conductor)

- `MC_PREQUEUE_MAIN_RUNS`, default 1. 0 is the rule before BH-8152.
- `MC_PREQUEUE_MAIN_RUNS_PAGE`, default 100 (the API maximum). A value outside
  1..100 is 100. Only the first page is read: a title past it is a miss.

## What this build does not do

The dedup key is the run title, not the main sha alone. Five READY PRs on one
main still get five runs, one per `(pr, head)`, because each run gates its own
head merged with main (BH-4545, BH-6335). One run for a whole group of heads
changes what the gate means and needs a product decision. What this build
gives: one dispatch per title, and one run-list read per main per tick for
every READY PR on that main.

## Check after deploy

24 h after the deploy, this must print 0:

```bash
gh api "repos/example-org/cromford/actions/workflows/prequeue-gate.yml/runs?per_page=100&created=>=<deploy time>" \
  --paginate -q '.workflow_runs[].display_title' | sort | uniq -d | wc -l
```

Test: `HARNESS_TEST_SANDBOX=1 bash tests/prequeue-main-runs.bh-8152-test.sh`.
