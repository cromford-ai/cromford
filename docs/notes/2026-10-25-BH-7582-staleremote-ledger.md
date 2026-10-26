# staleremote asks the jobs ledger; retention marks ledger rows (BH-7582)

Doc: FLY-POOL, TRIAGE-STATE

## What changed

`bin/fly-pool.sh` keeps `state/remote-results/<p>/<KEY>.json` on the hub as the
backup copy of a pool result on the ledger path. The staleremote check in
`bin/pipeline-health.sh` skipped a json only when a build folder beside it held
`RELAYED`. A pruned folder took the marker with it, so every backup json of a
finished build paged "unconsumed >30m" every 2 hours. On 2026-10-19 the hub
held 3,057 such jsons and `logs/ALERTS.log` held 711 staleremote lines.

This is the rebuild of closed PR #7617. That PR moved jsons to
`state/remote-results/<p>/archive/` and kept its cache and stamp in the same
directory. STATE-PATHS-GUARD refused it: `remote-results` is class `rows` in
`catalog/state-paths.json`. Comment 6401167251 (operator, 2026-10-25) asked for
the rebuild to act on ledger rows through `bin/jobs-client.sh` and to write no
file under `state/remote-results`. This build does that.

## The check

Section 5, between `# >>> staleremote` and `# <<< staleremote`. For a json
older than 30 minutes with no `RELAYED` sibling:

| build folder | ledger answer | page? | counted as |
|---|---|---|---|
| present, no RELAYED | not read | yes | - |
| gone | terminal (or cached terminal, same mtime) | no | `ledger-terminal` / `cached` |
| gone | open row | yes | - |
| gone | no row | yes (a real lost result) | - |
| gone | no jobs client on the box | yes (as before) | - |
| gone | unreadable | no | `unknown` |
| gone | read cap reached this tick | no | `deferred` |

`rr_build_state` in `bin/lib/remote-results-ledger.sh` reads the newest
`kind=build` jobs row of (project, KEY) through `_jobs_req`:

- Terminal: status `done`, `failed`, `abandoned`, `budget_stopped`; or `parked`
  with a result line that starts `PR_CREATED`, `PR_MERGED`, `PR_CLOSED`,
  `PLAN_BLOCKED`, `PLAN_MALFORMED`, `PLAN_STALE`, `DECOMPOSED`, `EXECUTE_EMPTY`
  or `REVIEW_BLOCKED`. This is the ticket's terminal stage list, mapped onto
  jobs-row statuses.
- Open: `running`, `queued_for_retry`, `orphaned`, an unknown status, and every
  other parked row (`QUEUED_FLY`, `BUILD_DEFERRED`).
- Unknown: a transport failure, a body that is not JSON or has no `jobs` array,
  a row about another ticket, kind or project.

One line per project goes to `logs/pipeline-health.log` when a count is above 0:
`<p> staleremote: ledger-terminal N, cached N, unknown N (not paged, ledger unreadable), deferred N (read cap N)`.

## The cache

`state/remote-results-terminal/<p>.tsv`, class `cache` in
`catalog/state-paths.json`. One line per key: `<KEY>\t<json mtime>\t<marked 0|1>`.
A later line wins. `marked=1` means the retention verb wrote the key's ledger
row. A json rewritten by a re-run has a new mtime and is asked again. The
retention verb compacts the file and drops keys whose json is gone. The
retention stamp is `state/remote-results-terminal/<p>.stamp`. Losing either
file costs ledger reads, nothing else.

## The retention rule

`bin/remote-results-retention.sh`. A json is retired when its ledger build row
is terminal AND (its build folder is gone OR it is older than the window).
Retiring writes ONE ledger row through `job_ledger_put`:

```
kind=remote_result  key=<p>/<KEY>  status=retired
detail={"json_mtime":N,"reason":"build folder gone"|"older than Nd","window_days":N}
```

The `ledgers` row has the natural key (kind, key) and upserts, so a re-run
writes the same row. The verb never moves, writes or deletes a file under
`state/remote-results`. The jsons stay on disk. Their row twins
(`pool_record_files`) keep their own retention in
`worker/jobs/src/routes/retention.js`. Retiring the file shadow itself is the
state-paths work of #4951.

One audit line per project per run in `logs/remote-results-retention.log`:

```
<stamp> run project=P dry=0|1 window=N[(default)] jsons=N terminal=N open=N absent=N unknown=N deferred=N young=N marked=N would_mark=N already=N would_page=N errors=N
```

`would_page` counts the jsons the staleremote check pages: older than 30
minutes, no `RELAYED`, and a folder present or an open or absent row. A dry-run
also writes its list to `logs/remote-results-retention-dryrun-<p>.txt`.
A failed `job_ledger_put` is `errors`, is not cached as marked, and is retried
on the next run. The staleremote section runs the verb once per project per
`REMOTE_RESULTS_RETENTION_EVERY_S`.

## Knobs (settings rows of the pipeline-health lane)

| knob | default | what it does |
|---|---|---|
| `STALEREMOTE_LEDGER_READS` | 200 | ledger reads per project per tick (and per retention run) |
| `REMOTE_RESULTS_RETENTION_EVERY_S` | 3600 | how often the section runs the retention verb per project |
| `REMOTE_RESULTS_RETENTION_DAYS` | 7 | the window (1..365); a bad value is 7 and the audit line says `window=7(default)` |
| `REMOTE_RESULTS_RETENTION_APPLY` | 0 | 0 is dry-run (no ledger row), 1 writes the `remote_result` rows |

To turn on the ledger writes:

1. Read one dry-run audit line: `tail -n 20 /root/harness/logs/remote-results-retention.log`.
2. Read the candidate list: `cat /root/harness/logs/remote-results-retention-dryrun-<p>.txt`.
3. Set the row: `bin/harness-ctl.sh set pipeline-health REMOTE_RESULTS_RETENTION_APPLY 1`.

The staleremote check does not need the ledger writes: its cache stops the
pages either way.

## Replay (hub only)

The build box has no hub `state/` and no jobs secret. On the hub:

```
HARNESS=/root/harness bin/remote-results-retention.sh --all --dry-run --max-reads 5000
grep 'dry=1' /root/harness/logs/remote-results-retention.log | tail -10
```

Sum `would_page` over the projects. The target is 0 for finished builds.
