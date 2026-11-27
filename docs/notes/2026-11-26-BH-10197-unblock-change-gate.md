# BH-10197: the unblock lane reads a PR from GitHub only after a change

Doc: OPERATING

## What changed

The queue and review collectors of the unblock lane (`bin/lib/unblock/collectors/queue.sh`,
`review.sh`) ask a change gate before their per-PR GitHub-only reads. The gate is
`bin/lib/unblock/change-gate.sh` (`ubg_*`). Its store is the D1 table
`unblock_change_marks`, one row per (repo, site, pr), site `queue` or `review`.

- The change mark is a worker sequence: the newest `wakes.id` for the PR (kind `pr`)
  and for its ticket issue (kind `issue`, from a `ticket/bh-<n>` branch). It is not a
  timestamp compare. The check never returns a mark below the stored mark: wakes
  retention prunes old wakes, and a lower mark would make the newer-only commit change
  0 rows, so a quiet PR would be due on every tick (W11). Only webhook minutes
  (`YYYY-MM-DDTHH:MM:00Z`) decide `settled`: a nudge row on the ticket issue has the
  minute `nudge:<dedupe>`, which sorts above every date as text, and made the PR
  `unsettled` on every tick (W12).
- `POST /api/unblock/change-marks/check` answers per PR: due or not, and the reason.
  First match wins: `first` (no row), `head`, `wake` (a newer mark), `unsettled` (the
  newest wake was in the minute of the last read), `off` (backstop 0), `backstop`
  (the row is older than `UNBLOCK_GATE_BACKSTOP_S` by the worker clock), else `quiet`.
- `POST /api/unblock/change-marks/commit` is one newer-only upsert
  (`WHERE excluded.mark >= stored mark`). Each collector commits once per tick,
  after its reads, and only for PRs whose gated reads all succeeded.
- The row holds the compact GitHub-only answers: queue `cr`, `tt`, `cdate`; review
  `rv` (CR reviews only, body cut to its marker) and `fc` (findings comment on head).

The step is the existing `lane.unblock.gh_source` (BH-10158):

| Step | Gate calls | Reads |
|---|---|---|
| `off` | none | every PR, as before |
| `shadow` (default) | 1 check + 1 commit per collector | every PR, as before; one `GATE_SHADOW <site> <repo>#<pr> field=<k>` line when a PR the gate would skip has a different fresh answer |
| `record` | 1 check + at most 1 commit per collector | a PR that is not due takes its answers from the row: 0 reviews, comments, files or head-commit reads |

Rule 1 (comment 7186843567): in step `record`, a failed check is UNKNOWN. The queue
collector prints one `queue-unreadable` record with input `change-gate` and no
per-PR record; the review collector names `change-gate#<pr>` in its meta. No mark moves.

The file cache of BH-10158 (`state/unblock-prr/`) stays. A PR the gate lets
through on a change reads with `UBP_FRESH=<mark>`: the cache key is `<head>@<mark>`, and
a file is served only when it was read in this tick. So the review collector reuses the
reviews the queue collector read in the same tick, and an older file is never stored
under a newer mark.

## Knobs and rows

- `UNBLOCK_GATE_BACKSTOP_S` (default 3600, 0 = off):
  `catalog/lanes.d/unblock.knobs.d/UNBLOCK_GATE_BACKSTOP_S.json`.
- Settings rows: `unblock.change_marks.items_max` (200),
  `unblock.change_marks.fields_max_bytes` (32768), `retention.unblock_change_marks.days` (14).
- Retention rule `unblock_change_marks.age`: a row is a cache, so it is deleted, not
  archived. A deleted row reads as first seen.

## Operator check before the flip to record

```bash
grep -E ' gate (queue|review) ' /root/harness/logs/unblock.log | tail -20
grep -c 'GATE_SHADOW' /root/harness/logs/unblock.log
```

Flip `lane.unblock.gh_source` to `record` only when the `GATE_SHADOW` count stayed 0 for
24 hours. Then post the spent GitHub calls per hour of `unblock.sh` against 476.

## Tests

- `tests/unblock-change-gate.bh-10197-test.sh`: the production tick, 50 PRs, each step.
- `worker/jobs/test/unblock-change-marks.bh-10197.test.js`: the routes on node:sqlite, EXPLAIN.
