# BH-7860: the relay json as a ledger row

Slice C0 of #7860 (the rest of #7803; C3 of #4157: "`state/remote-results/` to DB rows").

Doc: docs/notes/2026-10-21-BH-7803-remote-results-cursor-rows.md

## What changed

A remote build's result reaches its owning box as a relay json, `state/remote-results/<project>/<KEY>.json`.
That json now has a `ledgers` row. `bin/lib/rr-relay.sh` holds the functions.

| Kind | Key | Status | Detail |
|---|---|---|---|
| `rr-relay` | `<project>/<KEY>@<build-id>` | `parked`, then `staged`, `duplicate`, `empty` or `badjson` | the relay payload |

- The key is the key of the `rr-consumed` row for the same json (BH-7803). `rrr_rowkey` is that chain:
  KEY = `.key`, else the file name less `.json`; build id = the `build_dir` last segment, else
  `machine_build_dir`, else the first 16 hex of the file's sha256.
- Writer: `bin/fly-results-ingest.sh` calls `rrr_park` in the relay branch, before it writes the local file
  or sends it over ssh, for every box value. The delivered branch (the builder posted its own close-out)
  writes no json and no row.
- Consumer: `rrc_json_consume` (`bin/lib/rr-cursor.sh`) PUTs the outcome after the `rr-consumed` row. It
  sends no detail, so the worker keeps the parked payload (`detail=COALESCE(?, detail)`).
- Reader: `bin/fleet-status-push.sh` does not count a json older than 30 min as pending when
  `rrr_consumed` finds the `rr-consumed` row for its exact key. No row, an outage or no client counts it as
  before. The GET runs only for a json that would count, so the healthy state makes 0 reads.
- A payload over 3500 bytes has its `.result` cut to 1000 chars, so the detail is always valid JSON.
- A failed PUT writes one `rr-relay: rr-relay row NOT written for <KEY>@<build-id>` line to `$DLOG` (else
  `$LOG`). The relay continues.

## Order

The row is PUT before the file. If the box consumes the file before the parked PUT lands, the row can stay
at `parked`. The `rr-consumed` row still says consumed, so readers ask `rr-consumed`, not `rr-relay`.

## What did not change

The relay json is still written, sent and consumed as before. No reader stages, posts, deletes or skips a
close-out from the new row.

## Retention

`rr-relay` grows one row per relayed remote build, the same rate as `rr-consumed`. [NOTE] candidate for the
operator: add `rr-relay`, `rr-consumed` and `rr-handled` to the BH-6774 settings row
`retention.ledgers.archive_kinds`. An archived row still reads as present.

## Left for C1 of #7860

- `bin/fly-pool.sh` writers (reap and `pool_push_full`) call `rrr_park` (open #7556 holds the file).
- `bin/pipeline-health.sh` stale-remote check reads `rr-consumed` (open #7617).
- `catalog/state-paths.json` `remote-results` names `rr-relay` (open #7572).
- `bin/triage-gate.sh` section 1, `bin/fleet-slo.sh`, `bin/builds-retention.sh` and the staging relay loop
  read rows. Then (C2) retire the cursor and relay file writers.
