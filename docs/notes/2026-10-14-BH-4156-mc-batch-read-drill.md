# Merge-conductor state: one attempt read per repo per tick, and the fresh-hub drill (BH-4156)

Doc: MERGE-CONDUCTOR, DB-COORDINATION-SPEC

## The gap

BH-4141.4 asked to move the merge conductor's record of each open PR into the
DB, batch its per-tick reads into one query, and prove with a drill that a
fresh hub with an empty `state/` resumes every open PR from the DB with no
re-review and no duplicate merge.

Most of the records were rows on main already. Two parts were not done:

- Every `mc_attempt_has` and `mc_attempt_rows` of a PR-keyed line was its own
  `GET /api/pr-attempts`, per PR per line. A 3-PR tick of the test fixture
  made 15 of them.
- No drill existed.

## Which store holds each record now

| Record | Store | Since |
|---|---|---|
| `attempts.txt` | `pr_attempts` rows, row first; the file is a warm cache (flag `pr-state-rows`) | BH-1387, BH-2357 |
| `head-lag/<pr>` | `headlag` rows; the file is a read-through cache | BH-1564 |
| provcleared | a `provcleared` attempt row | BH-1387 |
| rebind records | the job verdict ledger (`job_verdict_rebind`) and `vsrebind` attempt rows; `rebind.log` is a build-record artifact | BH-2310 |
| per-PR state rows | the `pr_state` view; `mc_rows_rehydrate` fills and merges `pr-state.tsv` from it | BH-1387, BH-2361 |
| `state/review-autopilot/` | see `2026-10-14-BH-4156-review-autopilot-rows.md` | BH-4156 C1 |
| `state/main-red/` | see `2026-10-14-BH-4156-main-red-state-tables.md` | BH-4156 C2 |

Out of scope and still file state: `batch-hold/`, `land/`, `stuck/`,
`closed-watch/`, `conflict-size/`, `rereviews-<day>.txt`. The drill report
lists the ones the live hub has under "Not in the DB".

## What changed

- Route `GET /api/conductor-state?repo=<owner/repo>&numbers=<n,n,…>`
  (`worker/jobs/src/routes/conductor-state.js`, fragment
  `worker/jobs/test/route-table.d/773-conductor-state.txt`). It answers
  the `pr_attempts` rows of 1 to 200 PRs of one repo in one request:
  `{repo, numbers, truncated, attempts:[{number, kind, sha, at}], as_of}`.
  `numbers` lists the PRs the answer COVERS. The rows of one PR come newest
  first, the order `GET /api/pr-attempts` uses. A PR whose rows would take
  the answer over 5000 rows is left out of `numbers` and `truncated` is true.
  Zero rows is a 200. A bad `repo` or `numbers` is a 400, never a clamp. The
  number list binds as one `json_each` parameter, because D1 refuses a
  statement with more than 100 bound values.
- Client verb `pr_attempt_batch <repo> <out-tsv> <covered-file> <n…>` in
  `bin/lib/jobs/conductor.sh`. One GET per 200 numbers. rc 0 answered, rc 2
  the route answered 404 (not deployed), rc 1 an outage or a 200 without the
  two arrays. A row whose kind or sha holds a tab or a line break leaves its
  PR uncovered.
- The tick memo, in `bin/lib/mc/locks.sh`. `tick_project` calls
  `mc_tick_prefetch` once per repo, directly after the refs pin, with the rows
  the workers get. It writes `$MC_TICK_DIR/<tick>.batch-<repo>.tsv` and
  `.covered`. `mc_attempt_has` and `mc_attempt_rows` answer a covered PR from
  the memo: a memo hit is the row-hit arm (warm the file line), a memo miss is
  the measured-miss arm (the file decides, a file hit back-fills the row). A
  row this tick writes is appended to `.add`, so a later read sees it.
  `mc_attempt_clear` appends the PR to `.uncovered` before the DELETE, so no
  later read in the tick answers "attempted" from the memo. It also touches
  `$MC_TICK_DIR/memo-cleared.<repo>.<num>`, before and after the DELETE, with
  or without `MC_TICK_ID`. A memo whose `.covered` file is not older than that
  stamp does not cover the PR. So a clear in a keyed tick, a detached job or a
  later worker of another tick is seen by every tick memo, and a stale snapshot
  never warms a cleared line back into `attempts.txt`.
  Not covered, so read per PR exactly as before: no `MC_TICK_ID`
  (blocked-resolver), the flag down, a 404, an outage, a PR the row cap left
  out, a PR cleared in any tick after the snapshot. A 404 or an outage logs one line for that repo and does
  not latch the twin off. `mc_tick_gc` deletes the memo files with the other
  tick files. There is no knob: every failure falls back to the per-PR read.
- `MC_DRILL=1` forces observe mode in `mc_tick_mode`
  (`bin/lib/mc/tick-scope.sh`). Only the drill sets it.
- `bin/mc-state-drill.sh`, hand-run on the hub. See its header for the
  usage. It runs ONE conductor tick in `/tmp/mc-drill.*`, with empty
  `state/`, `logs/`, `locks/` and `flags/` (the `pr-state-rows` flag file is
  copied if the hub keeps it as a file), `bin`, `catalog`, `prompts` and
  `fleet.conf` symlinked, and shims for `curl`, `gh`, `git` and `claude` first
  on PATH that refuse every write and log every call. The live
  `state/merge-conductor` is never moved or touched: renaming it would let
  the live conductor's next cron tick run as a fresh hub with its actions on.
  Exit 0 `PASS`, 1 `FAIL: <codes>` (F0 the tick exited non-zero, F1 a refused
  merge/enqueue/push/model call, F2 a refused PUT of an attempt the DB has,
  F3 a lost `reviewed` on the same head, F4 no rehydrate line, F5 a repo with
  open PRs and no batch read), 2 `COULD NOT RUN: <why>`. The report is
  `logs/mc-state-drill-<epoch>.md`, and one line goes to
  `logs/merge-conductor.log`. No ALERTS line.

## What the drill found in its own fixture

The drill's scratch hub has no `builds/`. A PR whose APPROVE is only in a
build record (`builds/<rec>/review.md`), and not in the job verdict ledger,
reads "no verdict bound to head" on the fresh tick and goes HEAD_MOVED with
`reviewed=-`: a fresh hub would buy a re-review. The drill reports that as F3
(`tests/mc-state-drill.bh-4156-test.sh` D1b). With the ledger row present the
same tick resumes READY (D1).

## Preconditions for a PASS on the hub

1. The jobs worker with this route is deployed (else exit 2, "answered 404").
2. The `pr-state-rows` flag is up (else exit 2). Raising it is an operator
   decision (`docs/verification-map/pr-rows-contract.md`), not this change.

Run: `bin/mc-state-drill.sh` (all projects) or `bin/mc-state-drill.sh
--project <p>`. PASS means the first line of the report is `PASS`.
