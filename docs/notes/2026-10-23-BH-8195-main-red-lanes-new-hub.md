# BH-8195: main-red recheck and bisect log lines on the new hub (2026-10-23)

## What changed

1. `bin/main-red-recheck.sh` reads `state/main-red/recheck.last` only when the
   file exists. Before, `tr ... < "$STAMPF" 2>/dev/null` printed
   `line 71: .../recheck.last: No such file or directory` on a first run:
   bash opens the `<` before the `2>/dev/null` applies. The line went into
   `logs/main-red-detector.log` and read as "the script is missing".
2. `bin/main-red-bisect.sh` keeps the detect's stderr in its tick temp dir. A
   `forge-unreachable` line is now
   `<slug> forge-unreachable rc=<n> http=<GH_REST_STATUS> reason=<GH_REST_REASON> why=<last "mrb-detect: " line>`,
   with `-` for an empty value. `http=000` is gh-rest's value for "no HTTP
   status" (no read made, or a network failure). The cron line still sends
   stderr to /dev/null, so this line is the only place the cause shows.
3. `bin/hub-move.sh tick` does not run a lane whose command names an absent
   absolute path with a `/bin/` segment (`tick_missing_script`). It prints
   `tick: <id>: missing script <path>`, records rc 127, and the summary line
   ends `missing=<n>`. Tokens with `$` or a glob, and relative paths, are not
   checked.

## Why

On bh-hub-2 the recheck log showed a bash error and the bisect log showed only
`forge-unreachable rc=75`. Neither line named a cause.

## Not changed

`bin/lib/gh-app-auth.sh` still reads `$HARNESS/env/github-app.env`. If the
bisect line on bh-hub-2 shows `http=401 reason=auth-skipped`, that literal
path (no `/root/harness/env` compat symlink) is the first suspect. It needs
its own ticket, because every gh lane uses it.

Tests: `tests/main-red-recheck-stamp.bh-8195-test.sh`,
`tests/main-red-bisect-unreachable-why.bh-8195-test.sh`,
`tests/hub-move-tick-missing-script.bh-8195-test.sh`.
