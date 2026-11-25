# Gate: builder to-red

owner: BH-9559.9

The builder gate (`bin/test-impact-gate.sh`) runs the suites that turned the
most builds of this repo GATE_RED lately, before the push (BH-9583, BH-9559
part D item 10). A suite that the diff map does not reach, but that keeps
failing the selection gate after the push, now runs one step earlier.

## What the tier does

- The tier is `topred`, rank 1: right after `self`, before `reads` and
  `regression` (rank 2). The order is
  `self > topred > reads = regression > always > named > source > learned > closure`.
- Inside the tier the ranking order wins over the duration hint, so the cap
  keeps the suite with the most GATE_RED builds first.
- The suites sit inside the existing cap and budget. The tier has no cap and
  no reuse path of its own: `bin/suite-reuse.sh plan` sees them as ordinary
  run-list suites.
- A suite that is also `self` keeps rank 0, and its reasons gain `topred …`.
- `--table` changes only in the why column: `topred <n> GATE_RED build(s) in <d>d`.
- Gate stdout gains one summary line,
  `topred: <k> suite(s) from the GATE_RED ranking (<d>d, top <n>): <list>`, or
  `topred: 0 suites in the GATE_RED ranking (<d>d)`, and one
  `topred: dropped <suite> (<why>)` line for each answer suite it cannot run
  (`not a tests/[mc/]*.sh path`, `not in this checkout`).

## Knobs (settings rows)

| row | seed | no row | reader |
|---|---|---|---|
| `builder_gate.topred.enabled` | 1 | 1 | the gate. Only `0` or `1`; any other value is off. |
| `builder_gate.topred_n` | 5 | 5 | the gate, and the route when `n` is absent |
| `builder_gate.topred_window_days` | 14 | 14 | the gate, and the route when `days` is absent |

The seeds are `worker/jobs/schema.d/202611130809-bh-9583-builder-topred-knobs.sql`.

## Fail-open: `topred: off (<why>)`

The first check that fails prints one line, and the gate runs exactly as it
does without the tier:

- `runner plan`: `--runner plan` is the prequeue ledger's list, not the builder gate.
- `test sandbox, no fake client`: under `HARNESS_TEST_SANDBOX=1` the only
  client is `TEST_IMPACT_GATE_JOBS_CLIENT`. A test never calls the real jobs API.
- `no jobs client`: neither `$HARNESS/bin/jobs-client.sh` nor this checkout's is executable.
- `no jq`.
- `settings unreadable`: a `setting-get` outage (rc 1).
- `builder_gate.topred.enabled=0`, `bad builder_gate.topred.enabled`,
  `bad builder_gate.topred_n`, `bad builder_gate.topred_window_days`.
- `no repo`: no `SUITE_REUSE_REPO` and no parsable `origin` url.
- `read failed rc <rc>`: the `gate-red-top` verb failed.
- `bad answer`: the answer has no `.suites` array.

## The route

`GET /api/gate-red/top?repo=<owner/name|project>&n=<int>&days=<int>`
(`worker/jobs/src/routes/gate-red-rank.js`; CLI
`bin/jobs-client.sh gate-red-top <repo> <n> <days>`).

- `repo` is required (`^[A-Za-z0-9._/-]{1,100}$`) and matches `projects.repo`
  or `projects.project`. An unknown repo answers 200 with `suites: []`.
- `n` and `days` must be positive integers when given (else 400); when absent,
  the route reads the rows above.
- Answer: `{repo, days, n, since, rows_read, suites: [{suite, count, last_at}]}`,
  ordered by count desc, then `last_at` desc, then suite asc.

The source is the `jobs` table. `_job_finish` (`bin/lib/rb/gates.sh`) writes a
GATE_RED build as `status='failed'` with `meta` = the first 300 chars of the
RESULT line `GATE_RED <n> red: <a>,<b>; see <build>/gate.txt`
(`bin/lib/selection-gate.sh`). One statement:

```sql
SELECT meta, created_at FROM jobs
 WHERE project IN (SELECT project FROM projects WHERE repo = ?1 OR project = ?1)
   AND status = 'failed' AND created_at >= ?2 AND meta LIKE 'GATE_RED %'
```

`EXPLAIN QUERY PLAN` on 5,000 seeded rows:
`SEARCH jobs USING INDEX idx_jobs_project_status_created (project=? AND status=? AND created_at>?)`,
then `LIST SUBQUERY 1` / `SCAN projects` (a handful-of-rows table; the subquery
is not correlated and runs once). No new table, index or cache: the window
bounds the read.

Each row counts a suite once. The list ends at the first `; see `. A line with
no `; see ` was cut by the 300-char fold, so its last item is dropped: that
name can be cut in half. An item that is not a `tests/[mc/]<name>.sh` path is
dropped.

## Tests

- `worker/jobs/test/gate-red-rank.bh-9559.test.js`: the route (R1-R7).
- `tests/builder-gate-topred.bh-9559-test.sh`: the verb and the gate (V1, T1-T9).
