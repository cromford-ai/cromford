# Flag writes land in config_changes (BH-2377)

Doc: DB-COORDINATION-SPEC

This is the flags slice of BH-2330. the operator's RESUME of 2026-09-27 keeps one audit store, `config_changes`, so this slice adds no table and no schema. It only starts writing the `flag` kind that BH-2375 added.

- `PUT /api/flags` (`worker/jobs/src/routes/flags.js`) reads the flag's `active` before the write and batches its upsert with `configChangeStmts(..., CONFIG_KINDS.FLAG, name, was, { active }, ['active'], actor, reason, t)`. One row lands when the flag is new or `active` changed. The same `active` with a new reason or actor writes no row. The upsert and the audit row are one D1 batch.
- `POST /api/lanes/all-off|all-on` (`worker/jobs/src/routes/lanes.js`) does the same for the `all-off` row. An all-on with no `all-off` row is a create and logs `NULL -> {"active":0}`. A repeated all-off or all-on logs nothing.
- The 400s on both routes (bad name, missing `active`, missing actor or reason) still return before any DB touch and log nothing. Both response bodies are unchanged.
- `GET /api/flag-changes[?name=][&limit=]` is a filtered read of `config_changes` with kind `flag`, through `listConfigChanges`. It answers `{changes, truncated, as_of}` like `GET /api/config-changes`. A `name` outside `/^[A-Za-z0-9._-]+$/`, empty included, is a 400, never an unfiltered read.

Not audited here: `POST /api/main-red/clear` also writes `pause_flags`, but it already records into `main_red_events` and the RESUME names only the two routes above. There is still no pruning of `config_changes` for any kind; the `change_log.keep_per_key` knob is not built.

Pinned by `worker/jobs/test/flag-changes.bh-2377.test.js` and `worker/jobs/test/route-table.d/200-flags.txt`.
