# 2026-10-19 BH-7455: lead-review optional libs are fragment files

## What changed

`bin/lead-review.sh` had a block of 21 optional-lib loads. Each ticket that
added a lib appended one entry (a comment and a `. "$H/bin/lib/<x>.sh" ... || log ...`
line) at the end of that block. Two builds that each added one lib conflicted on
the same hunk. The file had 12 conflicts in 30 days.

The 21 entries moved byte for byte into one file each in
`bin/lib/lead-review/libs.d/`. The host keeps one loader stanza in the place of
the block. The stanza sources every `*.sh` file in `libs.d/`, at top level,
sorted by name under `LC_ALL=C`. No entry changes what it does.

## Add an optional lib

1. Write one new file `bin/lib/lead-review/libs.d/<yyyymmddhhmm>-<ticket-key>-<name>.sh`.
   Use the UTC minute you create it, for example `202610201230-bh-7600-foo.sh`.
2. Line 1 is `#!/bin/bash`. Line 2 is `# shellcheck shell=bash`. Line 3 is
   `# bin/lib/lead-review/libs.d/<own file name> — <what it is>`.
3. Lines 4 and on are the entry, as it would stand in the host: a comment and
   the source line with its fail-open `|| log "..."` or `|| true`.
4. Run `bin/lead-review-libs-build.sh --check`. It must print
   `lead-review-libs: <n> fragments ok`.

Do not edit `bin/lead-review.sh` for a new lib.

## The name rule

The moved entries are `NNNN-<name>.sh`, step 10 in the old order (`0010` to
`0210`). A new entry is `<yyyymmddhhmm>-<ticket-key>-<name>.sh`. This is the
`bin/schema-build.sh` rule (BH-5788). A picked "next free" `NNNN` collides with
the next build's pick. The ticket key makes the name unique, and the minute
stamp sorts every new file after all `NNNN` files, in creation order. Under
`LC_ALL=C`, `-` sorts before `0`, so `...-bh-7455-a.sh` loads before
`...-bh-74550-a.sh`.

## The tool

`bin/lead-review-libs-build.sh --print` prints the join of the fragments
(lines 4 and on, in load order). Nothing is rendered to disk and nothing goes
in `.gitignore`: the host joins the fragments when it runs. A committed render
would conflict as the host did.

`bin/lead-review-libs-build.sh --check` refuses a bad name, a file in
`libs.d/` that is not `*.sh`, a bad header, a `# module:` line, a fragment that
fails `bash -n`, two fragments with the same entry, an empty directory, and a
tracked render (`bin/lib/lead-review/libs.sh` or `libs.d.sh`).

## Fail closed

If `libs.d/` is missing or has no `*.sh` file, the tick writes one log line
`bin/lib/lead-review/libs.d/ has no fragment; lead-review tick skipped`, one
`LEAD REVIEW LIBS MISSING` alert (id `lead-review-libs-<hostname>`), and
exits 0. It sends no jobs request. This copies the module loader (BH-6293). A
missing directory is a broken checkout, and running on would silently drop
`LG_OK` and every gate the libs load.

## The lint row

`catalog/list-files.tsv` has a row for `bin/lead-review.sh` with input
`bin/lib/lead-review/`. `bin/list-file-lint.sh` refuses a PR that grows the
host and adds no new file under `bin/lib/lead-review/`. The fix: put a new lib
in a new `libs.d/` fragment, and put new code in a module in
`bin/lib/lead-review/` (BH-6293) that the host calls in one line.
`bin/split-host-growth-lint.sh` (max 40 lines) still applies too.

## Test selection

The host's source line names `bin/lib/lead-review/libs.d/`, so
`bin/test-impact.sh` maps every suite that reaches the host to that directory
and, through it, to each lib a fragment sources. A change to one fragment, or
to a lib like `bin/lib/review-level.sh`, selects the suites that reach the host
(for example `tests/lead-review-lane.bh-1950-test.sh`).

Tests: `tests/lead-review-libs.bh-7455-test.sh`.
