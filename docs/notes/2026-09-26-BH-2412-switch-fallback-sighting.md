# Kill switch fallback is read-only and sighted; switch-migrate runs daily (BH-2412)

Doc: CONFIG

This is a slice of #2412. It ships the daily migrate and the read-only-with-sighting
fallback. The ratchet floor to 0 (`tests/switch-ratchet.bh-2320-test.sh` `FLOOR`) is
left for a later slice, after the C1–C4 conversions (#2407–#2410) land.

## What changed

- **`lane_switch` never writes `flags/`.** With no `switch.*` settings row, step 3 is
  now `_ls_legacy` in `bin/lib/lane-switch.sh`. It used to call `flag_active`, whose
  `flag_sync` created `flags/<name>` from an active pause_flags row and removed it on
  a newer inactive one. `_ls_legacy` reads the same row (`GET /api/flags/<name>`) and
  applies the same last-writer-wins rule against the file's mtime, but it only
  answers. It loads the jobs client itself (`_lg_ensure_client`) so the answer does
  not depend on whether this process refreshed the settings cache.
  - row `active=1` -> ON, `LANE_SWITCH_SRC=legacy-row`, no file made
  - row `active=0` at or after the file's mtime, or no file -> OFF, `legacy-row`, the
    file (if any) is left where it is
  - row `active=0` older than the file -> ON, `legacy-file` (a later local touch wins)
  - no row (404), an outage, an unreadable row, or no jobs client -> the file
    decides, `legacy-file`
  The old single value `legacy` is gone.
- **A file that decides on its own is sighted.** When the answer is ON because of a
  file with no row behind it (no pause_flags row, or an inactive one older than the
  file), `_lg_flag_seen <name> "" "" 1` posts `POST /api/lanes/flag-seen` with an
  empty `lane`. It is the existing `lane_flag_sightings` rail, throttled by
  `state/lane-gate/.seen-<name>`: one post per state change plus the hourly refresh,
  and the marker moves only when the worker took the post. Any answer decided
  without a file (a settings row, a pause_flags row, no file) sends the clear, which
  costs nothing without a marker. An outage, an unreadable row and no client post
  nothing. A sighting never changes the answer.
  No screen shows these rows yet: `GET /api/lanes/status` matches sightings to
  lane flag names (`all-off`, `lane-off-*`), and a switch name is neither. Until a
  view is added, the rows are read from `lane_flag_sightings` in D1.
- **`bin/update-runners.sh` runs `bin/switch-migrate.sh` daily** (block
  `# >>> switch migrate`), after harness-sync and cli-update and before the rules
  render. Output goes to `logs/update-runners.log` prefixed `switch-migrate:`.
  rc 0 is silent beyond that, rc 75 (settings unreadable or no client, nothing
  written) is one log line, and rc 1 or any other rc is one `ALERTS.log` line
  `[<box>] switch-migrate rc=<n> — <refused/failed lines> see <log>`. It never
  changes update-runners' own exit code.
- **`switch-migrate` skips a switch that is still read bare.** If any code line in
  `bin/` or `fly/` still tests `[ -f .../flags/<name> ]` (the switch-ratchet
  pattern), the switch prints `bare <name> <file:line>` and gets no row. A row for
  such a switch splits it: removing the file, which is how an operator re-arms it,
  moves the bare reader, while the `lane_switch` readers keep obeying the row.
  Today that holds back `cost-autohalt-off`, which `bin/pipeline-health.sh` reads
  bare until #2433 converts it. It migrates on the first daily run after its last
  bare reader goes. `bare` is not a failure: rc stays 0 and no ALERTS line.
- **It also skips a switch whose catalog readers do not all call `lane_switch`.**
  The bare-file regex only sees one shape. After BH-2431's registry grew to cover
  switches read as `[ ! -f .../flags/<name> ]` (`alert-quarantine-disabled` in
  `bin/beat.sh`) or `flag_on <name>` (`batch-resolve-off`,
  `blocked-resolver-disabled`), a dry run offered rows for all three. So a switch
  migrates only when every file in its `catalog/switches.d/<name>.json` `readers`
  has a code line calling `lane_switch <name>`; otherwise it prints
  `bare <name> <reader>` (or the registry file, when it lists no reader).

## What did not change

- The settings-row steps and the "row says 0, flags/<name> ignored" log line.
- No row is written by merging this. The first write on each box is its next
  05:17Z update-runners run, and only for registered switches whose file that box
  holds.
- `flag_active` / `flag_sync` themselves, and every bare `[ -f flags/<x> ]` reader.

## Tests

`tests/switch-legacy-sighting.bh-2412-test.sh` (L1–L8, S1–S6) and
`tests/update-runners-switch-migrate.bh-2412-test.sh` (U1–U5, U1 on the real
`bin/switch-migrate.sh` through the block extracted from the real
`bin/update-runners.sh`), and `tests/switch-migrate-bare-reader.bh-2412-test.sh`
(B1–B4: `cost-autohalt-off` is not migrated while `bin/pipeline-health.sh` reads it
bare; B5 runs `--dry-run` on the real tree against the whole registry and asserts
no row is offered for a switch with a reader outside `lane_switch`; B6 pins the
`flag_on` and no-readers cases). `tests/lane-switch.bh-2320-test.sh` A6 now pins that
`flag_active` is not called.
