# The board API conformance lane, skeleton (BH-3958, part 1 of BH-3947)

Doc: BOARD-API-CONTRACT

## What changed

New hub lane `board-conformance`: `bin/board-conformance.sh`, registered in
`catalog/lanes.d/board-conformance.json` and run daily at 07:35Z by
`cron/lanes/724-board-conformance.cron` behind `hub-lease.sh check`.

```
bin/board-conformance.sh <project> | --all [--dry-run]
bin/board-conformance.sh --file-ticket <project>
```

For each fleet.conf project with an in-app board (`--all` reads
`bin/fleet-conf.sh --projects-with-board`) it resolves the token and base
variable through `bin/lib/board-creds.sh`, reads `MIGRATION_TOKEN` and the prod
origin, runs `bc_probe_board`, `bc_probe_origin` and `bc_write_routes`, and
writes `state/board-conformance/<p>.json` via tmp + mv:

```
{project, probed_at, probe: "ok"|"failed", probe_note,
 items: {<name>: {status, note}}, gaps: [sorted missing|malformed names]}
```

`unverified` is never a gap. A failed probe (unresolved creds, or
`bc_probe_board` rc 3) writes `items:{}` and `gaps:[]`. `bc_alert_on_change`
runs only after the state write and only when the probe is `ok`. A project
whose board prefix is `-` prints `skip <p>: GitHub-Issues lane`.

rc: 0 no gaps, 1 gaps, 2 usage or no state written (unknown project, an empty
`--all` list), 3 probe failed. Under `--all` the worst wins. One line per project
goes to `logs/board-conformance.log`. A second run while one holds
`locks/board-conformance.lock` exits 0.

Knobs: `BC_TIMEOUT_S` (curl `-m` per GET, default 20) and `BC_NOW` (the one clock
read, a test seam, `settable:false`).

## Status

Only the frame is real. `bin/lib/board-conformance/common.sh` (`bc_get`,
`bc_class`, `bc_item`) is real. `board.sh`, `origin.sh`, `writes.sh` and
`report.sh` are stubs with their final signatures: they record nothing, so
every state is `probe:"ok"`, `items:{}`, `gaps:[]`, and no alert fires.
`--file-ticket` prints `--file-ticket: not implemented yet` and exits 2. The
other three BH-3947 parts fill those bodies in.

Tests: `tests/board-conformance.bh-3947-test.sh` on the shared fixture
`tests/lib/board-conformance-fixture.sh`.
