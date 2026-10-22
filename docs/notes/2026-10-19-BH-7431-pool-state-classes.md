# Every pool state/ path has a class (BH-7431, BH-6896 S4)

Doc: DB-COORDINATION-SPEC, PROJECT-LANES

## Why

Option (a) of the BH-6896 note (docs/notes/2026-10-15-BH-6896-fly-pool-offhub.md)
runs the pool tick on a machine from a snapshot. A `state/` path with no
catalog row and no snapshot-list line has no class: nobody decided if it goes
to the machine, comes back, or stays on the hub. Section 1 of that note found
14 such paths and 4 catalog disagreements.

## What changed

- `catalog/state-paths.json`: 22 new rows (14 from the note, `dispatch-now`,
  and the 7 sourced-lib paths). No new row is class `rows`, so
  `bin/state-paths-guard.sh` blocks no writer it did not block before. Each
  note names the file:line that touches the path and its snapshot class for
  lane `fly-pool`. The `pool`, `fly-pool` and `build-queue` notes now name
  every file the pool writes there (cross-check items 2 to 4).
- `catalog/lane-run-inputs.d/fly-pool.ro` and `fly-pool.rw`: byte for byte the
  lists of PR #7515 (a739d2f19c11, BH-7505, not merged when this was written),
  plus appended lines. The `.ro` adds `state/preplan-files/$p-*` and
  `state/dispatch-now/$p/*`. The `.rw` adds a NOT CARRIED block for
  `state/fly-onboard/*`, `state/merge-queue/*` and
  `state/fly-pool/legacy-caps.$p`. A later merge with #7515 is an append on
  both sides. This branch's `bin/lib/lane-run-inputs.sh` does not read `.wo`,
  so `fly-pool.wo` is not in this change. Lane `fly-pool` has no placement
  fragment, so nothing publishes these lists yet (S5 does).
- `bin/pool-state-paths-lint.sh`: fails (rc 1) on a `state/<seg>` token in
  `bin/fly-pool.sh` with no catalog row and no `fly-pool.ro`/`.rw`/`.wo` line.
  `--trace` checks a normalised find-newer list instead. rc 2 when it cannot
  check. The escape hatch is `guardrail_escape_hatch pool-state-paths`.

## The class of each section 1 path

| path | catalog class | lane fly-pool |
|---|---|---|
| `state/build-queue/<p>/*` | rows | `.rw` |
| `state/fly-pool/<p>/*` (records, `.snapmt`, `.sweep.json`) | rows | `.rw` |
| `state/fly-pool/legacy-caps.<p>` | rows (row `fly-pool`) | NOT CARRIED, hub tick only |
| `state/fly/<p>.json`, `.image` | box-local | `.ro` |
| `state/pool/<p>/**` (every marker and `hold-cache/`) | rows | `.rw` |
| `state/remote-results/<p>/*` | box-local | `.rw` |
| `state/build-notes/<p>/*` | rows | `.rw` |
| `state/preplan-files/<p>-*` | box-local | `.ro` |
| `state/vercel-deploys/<p>.json` | cache | `.ro` |
| `state/auth-accounts.local.json` | box-local | NOT CARRIED (#7515 `.ro` header) |
| `state/overlap-after/<p>/*` | box-local | `.ro` |
| `state/dispatch-now/<p>/*` | box-local | `.ro` |
| `state/quota/*` | box-local | NOT CARRIED |
| `state/fly-cost/*` | box-local | NOT CARRIED |
| `state/pool-tailnet/*` | box-local | NOT CARRIED |
| `state/sibling-serial/<p>/*` | box-local | NOT CARRIED, machine-local |
| `state/fly-onboard/*` | box-local | NOT CARRIED, hub tick only |
| `state/merge-queue/*` | rows | NOT CARRIED, owner box over ssh |
| `state/lane-gate/*`, `state/gh-app-tokens/*`, `state/gh-app-installations.json`, `state/model-routes/*`, `state/flags-cache/*` | cache | machine-local |
| `state/gh-rest-ledger/*`, `state/dispatch-mode/*`, `state/hotfix-announced/*`, `state/hold-ambiguous/*`, `state/alert-line-sent/*`, `state/blind-list/*` | box-local | machine-local |

## NOT CARRIED, and what S5 must do

- `state/quota/*` and `state/fly-cost/*`: fleet-wide ledgers. S5 moves each to
  rows (`@rows` or the jobs worker) before a machine writes them.
- `state/pool-tailnet/*`: the env-bundle failure counter. It goes away with S3.
- `state/auth-accounts.local.json`: a machine spawns on the global account
  until the account routing is a row.
- `state/fly-onboard/*` and `state/fly-pool/legacy-caps.<p>`: the tick
  wrapper writes them, not the pool tick. They stay on the hub.
- `state/merge-queue/*`: written on the owner box over ssh. S5 must use
  the `merge_queue` row only.
- Machine-local paths: each machine fills its own copy. Nothing to carry.

## The metric

Pool `state/` paths with no class: 14 before, 0 after.

- Before (base catalog, 15 rows, no fly-pool lists): `bin/pool-state-paths-lint.sh`
  printed `pool-state-paths: unclassified=19 checked=33` (19 tokens over 6
  segments: `fly`, `dispatch-now`, `fly-cost`, `remote-results`,
  `vercel-deploys`, `auth-accounts.local.json`). Five of the six are in the
  note's 14; `dispatch-now` is the path the note missed. The other 9 of the 14
  are named only in the sourced libs and the tick wrapper, so the trace suite
  and the catalog rows cover them.
- After, on this branch: `pool-state-paths: unclassified=0 checked=33`.
- The trace suite `tests/fly-pool-state-trace.bh-7431-test.sh` runs the real
  `bin/fly-pool.sh` in three fixture states (idle, reap, spawn) and checks the
  find-newer trace with `--trace`: unclassified=0 in each state. On the base
  catalog the same traces had 6, 5 and 1 unclassified paths.

## The spawn-gate markers as rows

Six `state/pool/<p>/<KEY>.*` markers had no row: `.terminal-noted`,
`.terminal-alerted`, `.after-since`, `.after-released`, `.after-loop` and
`.defer-to-human`. Each now has a `pool_markers` row twin (marker
`cap-wait` for `.defer-to-human`; the file keeps its legacy name), behind
`pool_state_rows`, as BH-5001 did for `.spawns`.

- Table: `worker/jobs/schema.d/202610211929-bh-7431-pool-markers.sql`, primary
  key `(project, ticket_key, marker)`, indexes `idx_pool_markers_project_updated`
  (the GET) and `idx_pool_markers_updated` (retention). Retention rule
  `pool_markers.age`, window `retention.pool_markers.days` = 30.
- Routes: `PUT` and `PATCH /api/pool-state/markers`. The read is the `markers`
  list of the one `GET /api/pool-state` a tick already makes: no new read.
- Shell: `psr_marker`, `psr_marker_has`, `psr_marker_read`, `psr_marker_put`,
  `psr_marker_clear` in `bin/lib/pool-state-rows.sh`; one-line calls in
  `bin/fly-pool.sh`.
- THE FILES STAY. Every row write follows its file write. A once-marker is
  present when its file OR its row is there, so a failed-over hub does not page
  or comment again, and a file another writer made
  (`bin/lib/br-pool-terminals.sh`) still counts. A wait clock or release count
  reads its file first and the row only when the file is gone.
- A clear skips the PATCH only when this tick's full marker list answered and
  has no row, so the every-tick removes cost no request on a normal tick. A
  failed GET, an older worker or a cut list cannot prove the row is gone, so
  the clear sends the PATCH: a row left behind reads as live through the union
  readers (refute review: a stale `after-since` row released a key at once
  through the ceiling branch).
- No backfill: marker files written before the knob flip have no row. On the
  live hub the union read makes that safe; a hub that fails over can repeat an
  episode's page once.

## Knob state

`pool_state_rows` is unchanged (seed 0). With the knob off the marker helpers
send no request and read the files only, so this change is dormant until the
knob is on.

## Verify

- `bin/pool-state-paths-lint.sh; echo rc=$?`
- `HARNESS_TEST_SANDBOX=1 bash tests/pool-state-paths.bh-7431-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-state-trace.bh-7431-test.sh`
