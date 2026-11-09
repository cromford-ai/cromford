# BH-9266: bootstrap installs Bun, Playwright and CodeGraph at pinned versions, and a missing pin never stops it

Doc: ADDING-A-BOX, CODEGRAPH

## Cause

An outside audit (cromford-ai/cromford#5 and #6) found three unpinned installs
in `bin/bootstrap-machine.sh` on main 559c281cf3:

- Bun through the bun.sh web installer piped into bash.
- CodeGraph through the install script on the `main` branch of its repo, piped into sh.
- Playwright through `npm install -g playwright` with no version.

The audit's own fix read the versions from the `bake.*.version` rows, but it
stopped the bootstrap with a FATAL exit when the box had no jobs credentials
or no rows. On a new box that is before any useful state exists.

## Fix

1. `bin/lib/bootstrap-tool-pins.sh` (new, sourced). `btp_version <name>` reads
   `bake.<name>.version` through `bake_row_version` (`bin/lib/bake-deps.sh`),
   the reader the Fly image bake uses. A missing row, an outage, no
   credentials, a value that is not `x.y.z`, or a jobs client that does not
   load gives the fallback constant and one
   `WARN: bootstrap pin: bake.<name>.version <why>; using fallback <v>` line.
   The fallbacks equal the live rows on 2026-11-09: bun 1.4.2, codegraph
   1.5.0, playwright 1.48.2. Each constant names its row.
2. Bun comes from the GitHub release zip. The zip must match its line in the
   release `SHASUMS256.txt` (the `bake_sha256` match of `fly/bake-pin.sh`)
   before it is unpacked. A mismatch or an unlisted asset prints `ERROR: bun`,
   removes the download and installs nothing. The asset is
   `bun-linux-aarch64` on arm, `bun-linux-x64` when `/proc/cpuinfo` lists
   `avx2`, else `bun-linux-x64-baseline`. Bun goes to `/usr/local/bin` (the
   image location), with `bunx` linked to it.
3. CodeGraph is `npm install -g @colbymchenry/codegraph@<v>`. Playwright is
   `npm install -g playwright@<v>` plus `npx --yes playwright@<v> install
   --with-deps chromium`. Each install is checked with the tool's own
   `--version` before the `installed` line prints.
4. A tool already at the pin is skipped. A tool at another version, or absent,
   is installed.
5. `bin/bootstrap-machine.sh` calls `btp_ensure_all` from one block between
   `# >>> tool pins (BH-9266)` and `# <<< tool pins`. The block sits after the
   git identity step. The library contains no exit. A failed install is one
   `WARN: bootstrap pin: <name> <v> not installed (rc N)` line, and the
   bootstrap continues.

## Not changed

- Existing boxes keep any `~/.bun/bin` PATH line in `~/.bashrc`. If an old
  `~/.bun/bin/bun` shadows the pin on PATH, `btp_ensure bun` prints one WARN.
- The Fly image (`fly/Dockerfile`) is not changed.

## Test

`tests/bootstrap-tool-pins.bh-9266-test.sh`, cases P1-P8. curl, npm and npx
are PATH stubs; the jobs worker is never called.
