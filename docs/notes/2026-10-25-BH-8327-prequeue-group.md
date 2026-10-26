# One pre-queue gate run per main sha for a group of READY heads (BH-8327)

Doc: MERGE-CONDUCTOR

## What changed

Before this change, `pq_resolve` (`bin/lib/mc-prequeue.d/dispatch.sh`)
dispatched `prequeue-gate.yml` once per (PR, head, main). Five READY heads on
one main made five runs. #8152 recorded 20 runs on one main.

The rule now: **one dispatch per (repo, main) per conductor run, one verdict
row per head.**

1. A head that reaches the dispatch point of `pq_resolve` (after the cache,
   reuse, adopt, impact-reuse and veto rules) joins the open group of its repo
   and main (`pq_group_join`, `bin/lib/mc-prequeue.d/group.sh`). Its cache
   entry is `pending <now> -`, and `<path>.group` names the group id. The gate
   answers hold, as for a per-head dispatch.
2. After every PR worker of the repo answered, `tick_project` in
   `bin/merge-conductor.sh` calls `mc_pq_group_tick_end "$SLUG"` once (a
   BH-7453 fragment, `bin/merge-conductor.d/bh-8327-prequeue-group.sh`), and
   that calls `pq_group_flush`. The fragment always returns 0, so a flush
   failure never stops the tick. The flush dispatches ONE run of
   `.github/workflows/prequeue-group-gate.yml` per open group, with the inputs
   `main`, `group_id`, `members` (`<pr>:<head>,...`) and the same invariants,
   learned and trace inputs as the per-head gate. No open group: no lock and
   no call.
3. The group workflow has a `plan` job that checks the inputs and makes a
   matrix, and one `gate` job per head that calls `prequeue-gate.yml` through
   its new `workflow_call` trigger. The per-head job does not change: each
   head is merged onto main alone, runs its own suites and prints its own
   `prequeue-verdict` annotation. `fail-fast: false`, so one red head does not
   cancel the others.
4. On a later tick, `pq_settle` reads a grouped head through `pq_group_read`.
   The first head to ask reads the group run once (one run-list read, one jobs
   read, one annotation read per gate job that concluded success) and writes
   `groups/<gid>.verdicts`. Every other head of the group reads its line from
   that file. A head gets a verdict only from exactly one `prequeue-verdict`
   message that names its head and the group's main. A red head parks only
   itself. A failed or cancelled gate job, zero or two messages, or a main
   mismatch is could-not-run for that head only, with the usual one alert.
5. A head that asks after the flush opens the next group. A dispatched group
   (`.run`) is never flushed again.

## Not grouped (per head, as before)

- The knob `MC_PREQUEUE_GROUP` is 0.
- The repo has no `prequeue-group-gate.yml`: the probe answers 404, cannot be
  read, or answers a body that does not name that path.
- A named-suites run (`bin/lib/mc-prequeue.d/batch-solo.sh` calls
  `pq_dispatch` directly).

A per-PR machine run (`MC_ON_MACHINE=1` without `MC_LEASED_RUN=1` and
`MC_LEASE_FENCE`) dispatches nothing. It holds, writes the defer word
`prequeue-group`, and the hub runs that PR on its next tick, where the head
joins the hub's group. Cost: one hub tick of latency on fly-worker projects.
A leased project run joins and flushes its own groups.

## Failure paths

- A refused group dispatch: each member is `could-not-run ...
  group-dispatch-refused alerted`, ONE warn alert names the group and its PRs,
  the file becomes `.refused`, and each member proceeds on its next ask.
- An open group that its own run did not flush (a worker crash, a busy lock):
  the next flush abandons it. The members' pending entries and `.group`
  sidecars go, nothing is dispatched, and the members ask again. A knob set to
  0 between the join and the flush abandons the group too.
- A group run past the first `MC_PREQUEUE_GROUP_PAGE` runs of the list is not
  found. `MC_PREQUEUE_DEADLINE_S` makes its heads could-not-run, as for a
  per-head run.

## Suite ledger run key

Every gate job of one group run shares `github.run_id`, so the per-head
workflow's ledger run key `prequeue-<run_id>-<attempt>` would be one row for
all heads (`suite_reuse_runs` is keyed by repo and run key). The new
`workflow_call`-only input `run_key_suffix` (the group passes `-<pr>`) makes
it `prequeue-<run_id>-<attempt>-<pr>` in a group run. A dispatched per-head
run has no such input, so its key does not change.

## Knobs (lane merge-conductor)

| knob | default | row |
|---|---|---|
| `MC_PREQUEUE_GROUP` | 1 (0 = one run per head) | `lane.merge-conductor.<project>.mc_prequeue_group` |
| `MC_PREQUEUE_GROUP_MAX` | 10 heads per group run | `lane.merge-conductor.<project>.mc_prequeue_group_max` |
| `MC_PREQUEUE_GROUP_PAGE` | 30 runs per run-list read | `lane.merge-conductor.<project>.mc_prequeue_group_page` |

The group lock waits `MC_PREQUEUE_GIT_LOCK_WAIT_S`. The group dispatch is
bounded by `MC_PREQUEUE_CALL_BUDGET_S` (0 = no bound).

**Rollback is one row:** set `lane.merge-conductor.<project>.mc_prequeue_group`
to `0`. The next flush abandons any open group, and every head dispatches per
head again.

## State and retention

`$MC_STATE_DIR/prequeue/groups/`: `<slug_>_<main>_<gid>.open|.run|.refused`
(line 1 `open|dispatched|refused <opened_at> <tick_id|-> <main>`, then one
`<num> <head>` line per member), `<gid>.verdicts` and
`<gid>.<head>.why|fail|timing`. `pq_prune` already deletes every file under
`$MC_STATE_DIR/prequeue/` older than 7 days, so `groups/` has the same
retention. No database table.

## Live probe after deploy (not run here)

```bash
gh api "repos/example-org/cromford/actions/workflows/prequeue-group-gate.yml/runs?per_page=20" \
  --jq '.workflow_runs[].display_title'
grep 'PREQUEUE group-dispatch' /root/harness/logs/merge-conductor.log | tail -5
```

One run title per group (`prequeue group=<gid> main=<main>`), and a
`group-dispatch ... n=<k>` line with k > 1 when several heads were READY on
one main.

## Test

`tests/prequeue-group.bh-8327-test.sh` (G1-G16 and G1E, the real conductor
tick with 5 READY rows).
