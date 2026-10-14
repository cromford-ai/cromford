# apply-migrations finds a fifth board's app base, board-invariants reads a served keyPrefix

Doc: OPERATOR-SETUP

## What changed

- **`bin/apply-migrations.sh` resolves unnamed projects generically.** The four
  explicit arms (project-1, project-2, project-3, project-4) are byte-identical. Any other
  project whose fleet.conf `board_prefix` is a real path now takes its base from
  the one `*_APP_BASE=` / `*_API_BASE=` line in its env file
  (`app_base_var`, `bin/lib/internal-token.sh`). If the env file is missing, has none, has
  two, or has one that is empty, the cron tick writes ONE ALERTS line naming the
  reason, then exits 0. The line is deduped to once per 24h per project by the
  mtime of `state/apply-migrations-nobase-<project>.stamp`. `--files` still
  answers `{"status":"no-endpoint"}` with rc 5. A `-` prefix, a project fleet.conf
  does not list, or an unreadable fleet.conf stays silent, as before.
- **`bin/board-invariants.sh` reads `keyPrefix` from the board list** (the same
  board `[0]` it takes the id from, array or `{boards:[…]}` shape). It is used to
  build `<prefix>-<number>` for a ticket with no `.key`. The `KEYPFX` map is the
  fallback when the board serves none. A served `.key` still wins.
- **`docs/OPERATOR-SETUP.md`** no longer tells an operator to add lines to the
  live crontab. Since BH-1247 the cron suites read the render of committed
  sources, so the doc now says to put the box in the `.boxes` of the registry
  lanes it runs (`catalog/lanes.d/<id>.json`), put a line with no lane in a
  `cron/boxes/<box-id>.d/` fragment, and install with
  `bin/render-crontab.sh <box-id> | crontab -`. No suite changed.
- **Golden fixtures.** The ten `catalog/fixtures/golden/*/inputs.md` that showed
  `cat flags/build-slots` + `count-builds.sh` now show the `free-slots.sh` line
  production reads, with the same slot arithmetic.

## Why

Issue #1956 (items 7, 14, 15 and 17 of #232). A fifth in-app board had a
migration lane that exited 0 on every tick and never said why.
