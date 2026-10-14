# The pause_flags mirror is retired, and a lint freezes new flags/ writes (BH-4154, slice C0)

Doc: DB-COORDINATION-SPEC, fleet-pauses, verification-map

## Why

BH-4153 moved the ported flag families (`paused-*`, `automerge-disabled[-*]`,
`lanedown-*`, `dispatch-mode-*`) to `harness_flags` rows. Five worker readers
still read `pause_flags`, so every fleet-scope ported write also wrote a
`pause_flags` "mirror" row in the same batch. Two stores held one fact. A
mirror row that was left behind (`active=1` while the `harness_flags` row was
cleared) refused every claim for that project.

## What changed

1. `worker/jobs/src/lib/harness-flags.js` holds one fleet-flag reader. The
   name picks the store:
   - a name that `FLAG_PORTED_RE` matches: its fleet `harness_flags` row. Its
     `pause_flags` row is read only while no `harness_flags` row exists (the
     backfill's own fallback);
   - any other name: its `pause_flags` row.
   The helpers are `readFleetFlag`, `fleetFlagRows`, `activeFleetFlags`,
   `flagActiveSql`, `clearFleetFlagStmt` and `portedSql`. `portedSql` is
   `FLAG_PORTED_RE` as SQL. It is built from the regex at load time, and it
   throws when an alternative is not `literal` or `literal.+`.
2. `mirrorStmts` is gone. `PUT` and `DELETE /api/flags` of a ported name write
   the `harness_flags` row and the audit row only.
3. The readers use the helpers:
   - `checkPause` (`lib/core.js`, every claim): `activeFleetFlags`. The
     refusal reason names the table that answered:
     `paused: harness_flags row paused-<p> is active (updated <t>)`.
   - `GET /api/lanes/status` (`routes/lanes.js`): `fleetFlagRows`.
   - `GET /api/main-red` and `POST /api/main-red/clear`
     (`routes/main-red.js`): `fleetFlagRows`, `readFleetFlag`,
     `flagActiveSql`, `clearFleetFlagStmt`. The list joins `main_red` in JS
     now, because the two rows can live in different tables.
   - `GET /api/metrics/cost-anchored` (`cost-anchor-off`) and the digest
     factory section (`all-off`): `readFleetFlag`.
   - `GET /api/flags`: `fleetFlagRows`, the same merge as before.
   `main-red-*`, `cost-anchor-off` and `all-off` are not ported, so these
   routes read the same `pause_flags` row as before. When a later slice adds a
   name to `FLAG_PORTED_RE`, they follow it with no edit.
4. A fleet `harness_flags` row for a name that is NOT ported (a "stray") is
   ignored by every reader. It does not hide that name's `pause_flags` row.
5. `tests/no-flag-files.bh-4154-test.sh` freezes the `flags/` file writers in
   `bin/`. The allowlist is exactly `bin/lib/jobs/flags.sh` and
   `bin/flags-import.sh`. Every other writer has a count in
   `tests/no-flag-files-baseline/<path under bin/>.txt`. In delta mode (the
   default) a diff that raises a count, or adds a file with a write, is red.
   `--strict` checks the tree against the baseline. `--write-baseline`
   regenerates the directory.

## What did not change

- `worker/jobs/src/lib/sentry.js` still reads `pause_flags` directly. It must
  stay byte-identical with the Cloud worker's copy of `sentry.js`
  (`tests/worker-sentry.bh-5618-test.sh` X1), and the Cloud worker has no
  `harness_flags`. Its flag `lane-off-sentry-report` is not ported.
- `FLAG_PORTED_RE`, `bin/flags-import.sh` and the `pause_flags` table.
- The `GET` response keys `active`, `actor` and `updated_at`.

## Slices left

Each slice ports one family, all of its writers and readers, and deletes its
own baseline files:

- C1 `wip-limit-*` (with the valued-file import and the BH-5635 read in
  `bin/lib/flag-on.sh`);
- C2 `alerted-*`, `noted-*`, `warned-*` latches;
- C3 `main-red-*`;
- C4 kill switches (`*-off`, `*-disabled`, `lane-off-*`, `cost-anchor-off`,
  `all-off`);
- C5 hub and routing flags, and the `*.conf` files in `flags/`. C5 empties
  the baseline.

## Not proven by this change

The tests prove the mechanism (rung BUILT). After deploy, run these probes:

1. `curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/flags?prefix=paused-"`.
   Each row must carry `active`, `actor` and `updated_at`.
2. On D1: `SELECT name FROM pause_flags WHERE (name LIKE 'paused-%' OR name LIKE 'automerge-disabled%') AND updated_at > '<deploy time>'`.
   It must return no rows.

The ticket outcome "`ls /root/harness/flags` is empty on the hub after a full
day" needs slices C1 to C5. This change does not reach it.
