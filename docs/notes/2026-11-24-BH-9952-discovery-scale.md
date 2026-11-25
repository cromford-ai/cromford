# BH-9952: blocked-resolver discovery at the hub's size, and a rung time bound

Doc: MERGE-CONDUCTOR

## Evidence

On bh-hub-2, 2026-11-24, the `cromford` pass took 1,978 s and did 0 rungs
(`tick: candidates=782 retired=17 rungs=0/100 reason=tick-budget`). The BH-9467
cache worked: 9,419 of 10,161 dirs and 1,158 of 1,175 records were skipped.
The prof line still said `discovery=1238 … discovery_src=rebuilds:571,…,builds:603`,
and `loop=581` was one rung (`cromford/example-org-cromford-9700:569s`).

## Cause (measured)

`bor_union` (`bin/lib/builds-of-record.sh`) was quadratic in the number of
local RESULT files. Each source called it once per project per tick, and
br_from_rebuilds called it again. Two string patterns grew by one row per
RESULT:

- the duplicate check: `case "$seen" in *$'\n'"$name"$'\n'*` on a string
  that grew by one name per row;
- the output: `out="$out<row>"`, which copies the whole string once per row.
  This was the larger part. At 4,000 rows the append alone took 12.6 s, and
  `out+=` took 0.04 s on the same box.

Each RESULT also forked one `date -u -r`. On a scratch builds/ with 4,000
RESULT dirs and an empty ledger, the old `bor_union` did not finish inside
`timeout 20` (`tests/bor-union-scale.bh-9952-test.sh` S1, the REPRO). The
fixed one took 1.3 s.

The ledger-only loop of br_from_builds forked `ba_path` (a process
substitution and an awk), `date -u -d`, a `br_rkey` subshell and `jq` per
row. br_from_rebuilds forked `jq` 5 to 8 times per record it read.

## Fix

- `bor_union`: `seen` is an associative array. The output is appended with
  `+=`. ONE `TZ=UTC find … -printf` gives every RESULT mtime. A RESULT the
  find did not list (written after it, a symlink) takes the old `date -u -r`.
  The output is byte-equal to the old function (S2 of the REPRO suite: ledger
  rows, pool-/fly- twins, `project-4` vs `project-4`, tabs, no trailing newline,
  an empty RESULT, a find that answers nothing, `TZ=Asia/Tokyo`).
- `bin/blocked-resolver.d/bh-9952-discovery-batch.sh` (new fragment):
  - `bdb_union`: one `bor_union` per project per tick for both sources.
  - `bdb_archived`: one awk pass over `builds-archive/index.tsv` per tick,
    with the same answer as `ba_path`.
  - `bdb_epoch`: ISO to epoch in bash, with `date -u -d` for any other shape.
  - `bdb_state_batch`: one `jq` over every ledger row's state file. jq stops
    at a file that does not parse. That file is asked alone, as before, and
    the batch runs again on the files after it.
  - `bdb_rec`: one `jq` for the fields br_from_rebuilds reads after the
    outcome. The `.outcome` read stays its own call, because
    `tests/blocked-resolver-discovery.bh-9029-test.sh` D4 counts it.
  - `bdb_qdone`: `queue_list <p> done` once per project per tick.
  - The ledger cache. A ledger row whose skip depends only on the row and its
    state file (rebuild_seen, or a ladder attempt at or after the record) is
    noted in the BH-9467 builds cache file as
    `ledger:<project>/<build_dir>\t<updated_at>|<state mtime:size>\tskip\t<epoch>`.
    The next tick skips it before the state read when the signature is the
    same. The 5,400 s and 21,600 s floors and every offered row are read
    again. `bdc_begin builds` now runs before the ledger loop.
  - Sub-timers: `discovery_sub=builds.union:…,builds.ledger:…,builds.glob:…,
    rebuilds.union:…,rebuilds.queue:…,rebuilds.walk:…`.
- `bin/lib/br/opt/profile.sh`: dotted entries go to `discovery_sub=`.
  `discovery_src=` keeps the whole sources in their order. The new fields
  `discovery_sub=` and `rung_bound=` go after `project=` and before
  `top=[…]`, which stays last (the BH-5946 pin).
- `BR_OPT_OFF=bh-9952-discovery-batch` gives the old per-row reads with the
  same candidate rows (`tests/br-discovery-scale.bh-9952-test.sh` S2).

## Before and after (the fixture, this box)

`tests/br-discovery-scale.bh-9952-test.sh`: 10,315 build dirs, 1,200 records,
500 ledger rows.

| Path | discovery= |
|---|---|
| old `bor_union` | does not finish (4,000 dirs: more than 20 s per call) |
| fixed lib, both fragments off (BR_OPT_OFF) | 52-53 s |
| fixed lib, batch fragment off, cache on, pass 2 | 31 s |
| fixed lib, batch fragment on, cache on, pass 2 | 22 s |

The hub number is the T9 probe after deploy (below).

## The rung time bound

`bin/blocked-resolver.d/bh-9952-rung-bound.sh`. Knob rows
`BR_RUNG_MAX_SECS` (default 0 = no bound, max 7200) and
`BR_RUNG_KILL_GRACE_SECS` (default 30). With a bound above 0, a watchdog
starts in each rung subshell after the key flock. It closes every inherited
fd above 2, so the key lock and the lane lock stay with their owners. Past
the bound it writes `fired` to `$ST/.rung-bound[-<project>].<pid>`. It sends
TERM to the rung's process tree, children first, and skips a process in
another session. After the grace it sends KILL. The rung's TERM trap runs
`br_wt_drop` and `br_round_end`. The driver then logs
`<p>/<rkey>: the rung ran past BR_RUNG_MAX_SECS=<n> — ended (reason=rung-bound …)`.
The profile row records rc 124, the prof line counts `rung_bound=<n>`, and
the tick goes to the next candidate. The attempt list on the ticket record
gets no new entry, so a rebuild-fresh in flight stays visible to
br_from_rebuilds.

The seed is 0 on purpose. A kill ends a fix round's paid agent call
(FIX_AGENT_TIMEOUT is 3600 s). Pick a value after the first hub ticks with
the discovery fix.

## builds/ retention (scope 4)

The rule: `bin/builds-retention.sh` runs daily at 04:27Z on every box, the hub
included (`cron/lanes/737-builds-retention.cron`, the `# @box hub` block
behind `hub-lease.sh check`; `catalog/lanes.d/builds-retention.json` lists
`hub`). It moves merged groups older than `builds_retention.window_days` (14)
and settled unmerged groups older than `builds_retention.settled_window_days`
(30) to `builds-archive/<YYYYMM>/<dir>`, at most `builds_retention.max_dirs`
(2000) dirs per run. Nothing is deleted. While the settings row
`builds_retention.dry_run` is 1 (the seed), the lane only writes its list to
`logs/builds-retention-dryrun.txt`. That is why the hub still holds 22,863
dirs. `tests/br-rung-bound.bh-9952-test.sh` R6 checks the wiring.

## Operator steps

1. After deploy, on bh-hub-2:
   `grep 'prof: secs' /root/harness/logs/blocked-resolver.log | grep 'project=cromford' | tail -3`.
   Expect `discovery=` under 120. The paired `tick:` line must show `rungs=` above 1.
2. Read `logs/builds-retention.log` and `logs/builds-retention-dryrun.txt` on
   the hub. If the list is correct, follow docs/HARNESS-COORDINATION.md
   "Flip procedure": `bin/jobs-client.sh setting-set builds_retention.dry_run 0`.
3. Optional, after step 1: set `BR_RUNG_MAX_SECS` (for example 900) if one rung
   still holds a whole tick.

A leftover `.rung-bound*` file (a tick killed during a rung) is a few bytes,
and no reader uses it.
