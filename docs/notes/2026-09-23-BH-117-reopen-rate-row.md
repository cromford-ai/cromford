# The reopen rate is a D1 row; the build reads it through jobs-client

Doc: RUN-BUILD-GRAPH

## What was wrong

The reopen demoter (the `# >>> reopen trust signal` block of `bin/run-build.sh`,
and its dark twin in `bin/lib/rb/gates.sh`) read `state/reopen-rate.json`. Only
the hub writes that file (`bin/reopen-metrics.sh`), so on every watcher box the
read found nothing, the signal was inert, and the build didn't say so.

## What it does now

- `bin/reopen-metrics.sh` still writes the file first. Then it writes one
  `ledgers` row per project (`kind=reopen_rate`, `key=<project>`,
  `status=measured`, `detail={"reopens_14d":N,"builds_total":D}`), read back
  from the file it just wrote. A failed PUT isn't counted: the lane prints
  `reopen_rate rows: <ok> written, <n> failed` and writes one ALERTS line naming
  the projects.
- New jobs-client verbs in `bin/lib/jobs/settings.sh`: `reopen_rate_put` and
  `reopen_rate_get`. The getter returns rc 2 for no row and rc 1 for an
  outage or a row that isn't two non-negative integers.
- The signal block reads the row first and falls back to the file for no row,
  an outage or a malformed row. On every build it writes one line to
  `$BUILD/pipeline.log`: `TRUST: reopen signal from <db row …|file …|none>: N/D — …`.
  Thresholds, the demoter and the extra-lens knob are unchanged.

Out of scope, per the ticket's rescope: nothing syncs `state/reopen-rate.json`
to boxes (`bin/harness-sync.sh` is untouched). `bin/cost-rollup.sh` still reads
the hub file. There is no worker, schema or route change, because the
`ledgers` table and `/api/ledger` already exist.
