# Lane-run fleet: several starts per tick, and claims that prefer warm clones (BH-6885)

Doc: PROJECT-LANES

Part of BH-6881 (slice S6). Before this change `bin/lane-fleet.sh tick` started
at most one machine a minute, so a queue of 40 runs drained one machine at a
time.

## What changed

- **Starts by queued work.** The tick reads `GET /api/lane-runs/stats?run_p50=1`.
  WORK = the sum over queued lanes of `queued x run_p50_s`. A lane with no done
  sample (`run_p50_s` null) adds 0. `lf_decide` computes
  `n = max(floor - live, ceil(WORK / target_drain_s) - live, 1 if W > scale_up_wait_s)`,
  then caps n by `lane_fleet.max_starts_per_tick` and by the room under
  `max_machines`. It prints `start <n> <reason>`, where the reason is
  `below-floor`, `queue-depth` or `queue-wait`. `none <reason>` is unchanged.
- **The start is a batch.** The tick starts up to n machines. It reuses each
  Fly `stopped` machine in id order first, then it runs `machine run` for the
  rest. Every start is recorded `starting` at the tick's decision time. The
  first failure ends the batch and writes `start batch stopped after <k> of <n>: <why>`.
- **The rules that stay.** The in-flight gate (a batch starts only after the
  last one claimed or failed), the failed-start hold and backoff,
  `max_machines`, the floor and every stop rule are the same as before.
- **Log line.** `action=start <mid>[,<mid>...] <reason>`. One start gives the
  same text as before. ` work=<s>s desired=<n>` comes after `cost=`.
- **Claim `prefer`.** `POST /api/lane-runs/claim {machine, prefer:[projects]}`
  takes the oldest live row of a preferred project. A live row that waited
  longer than `lane_run.prefer_max_wait_s` comes first, oldest first. Equal is
  not over. 0 turns the preference off. `prefer` is optional. If it is present,
  it must be an array of at most 64 path-safe names, else the answer is 400.
  `prefer` matches exact project names. A `merge-conductor-pr` row
  (`<project>.<pr>.<head12>`) never matches a clone name.
- **Stats `run_p50`.** With `run_p50=1`, each lane with `queued > 0` gets
  `run_p50_s` (the median of `finished_at - claimed_at` over the lane's newest
  50 done rows, or null) and `run_p50_n`. This is the same definition as
  `run_s` in the BH-6127 metrics route. At most 50 lanes are sampled, the most
  queued first. A lane past that cap gets null, and the answer carries
  `run_p50_truncated: true`. Any other value of `run_p50` is a 400.
- **Clone cache.** `bin/lane-run-worker.sh` treats the direct children of
  `${REPOS_ROOT:-/root/repos}` as its clone cache. A child counts only if it is
  a real dir (not a symlink), has a `.git` and has a path-safe name. The worker
  sends the newest `lane_run.clone_cache_n` names as `prefer`. After each run it
  touches the run's own clone. Only when `LANE_RUN=1` (set by
  `machine run -e LANE_RUN=1`) does it remove the clones past the newest N,
  with one `clone cache: evicted <name> (keep <n>)` line each. No lane-run
  machine clones a repo yet (BH-6888). So in prod the cache is empty today, no
  `prefer` is sent, and the claim behaves as before.

## Settings rows

`worker/jobs/schema.d/202610151917-bh-6885-lane-fleet-multistart-knobs.sql`.
These are seeds only, with no new table.

| key | seed | bounds | code default |
|---|---|---|---|
| `lane_fleet.target_drain_s` | 60 | 10..3600 | 60 |
| `lane_fleet.max_starts_per_tick` | 5 | 1..50 | 5 |
| `lane_run.prefer_max_wait_s` | 60 | 0..3600 | 60 |
| `lane_run.clone_cache_n` | 8 | 1..64 | 8 |

A missing or out-of-range row uses the code default. `clone_cache_n` has no 0,
so a bad row can never delete every clone.

## The claim's query plan

The claim subquery now spells LIVE as
`status IN ('queued','claimed') AND (status='queued' OR lease_until < ?2)` and
names `INDEXED BY idx_lane_runs_claim`. I measured both plans with node:sqlite
on the composed schema and 20,000 rows (2 % queued, 30 lanes):

- Main's statement, before `ANALYZE`: `MULTI-INDEX OR` over two
  `SEARCH ... idx_lane_runs_claim (status=?)`. After `ANALYZE`: `SCAN lane_runs`.
- The new statement without `INDEXED BY`, after `ANALYZE`: `SCAN lane_runs`.
- The new statement as shipped: `SEARCH lane_runs USING INDEX idx_lane_runs_claim (status=?)`,
  with a temp B-tree for the ORDER BY over the live rows only.

So `INDEXED BY` is the part that holds the plan. Test E1/E2 in
`tests/lib/lane-runs-claim-prefer.bh-6885.mjs` runs `ANALYZE` and asserts it.
The per-lane run sample `RUN_SAMPLE_SQL` is
`SEARCH lane_runs USING INDEX idx_lane_runs_lane (lane=? AND status=?)` with no
temp B-tree (test E3).

## Not in this change

- `lane_runs` still has no retention job (parent risk R8). This change adds no
  table and no growing rows.
- `GET /api/lane-runs/stats` still groups over all of `lane_runs` each tick.
  This change adds only the indexed per-lane reads.
- The ticket's metric (p90 claim wait at most 30 s at 10x load) is a
  measurement after deploy. No test asserts it.

## Tests

`tests/lane-fleet-multistart.bh-6885-test.sh`. It runs the real `bin/lane-fleet.sh tick`
and the real `bin/lane-run-worker.sh --once` against the real jobs worker, plus
the node half `tests/lib/lane-runs-claim-prefer.bh-6885.mjs`.
