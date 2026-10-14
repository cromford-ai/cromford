# BH-113 — every box indexes its own harness checkout

Doc: CODEGRAPH

## What changed

`bin/codegraph-ensure.sh` already gave target project clones a
capability-tested code graph at build time. The box's own
`/root/harness-checkout` was never indexed, so a ticket that changes the
harness itself had grep and nothing else.

`bin/harness-sync.sh` now calls `bin/codegraph-harness-index.sh` on its deploy
path, right after `stamp_state harness-sync-last-success`. The wrapper runs the
same ensure script with `CODEGRAPH_REPO=/root/harness-checkout`. That inits the
index when `.codegraph/` is missing, syncs it when codegraph reports pending
changes, and does nothing when it is current. None of ensure's logic is copied.

## Where the answer lives

- `/root/harness/state/codegraph-harness-checkout`: line 1 is `# <UTC time>`,
  then ensure's own `CODEGRAPH AVAILABLE (...)` or `CODEGRAPH NOT AVAILABLE (...)`
  lines. Overwritten each run.
- `logs/update-runners.log` gets the first line of that note, one line per run.

## What it never does

- It never fails or delays the sync. It runs after the success stamp and
  outside `locks/harness-sync.lock`, its output is discarded, and it always
  exits 0. harness-sync's stdout is still one status line.
- It never waits. `locks/codegraph-harness-index.lock` is taken with
  `flock -n`; a second run logs "another run is indexing, skipped" and leaves
  the note as it was.
- It never reads a hang or an empty answer as available. It is bounded by
  `CODEGRAPH_INDEX_TIMEOUT_S` (code default 90 s, env override). A timeout
  records `NOT AVAILABLE (indexing <checkout> timed out after Ns)`, and output
  with no verdict line records `NOT AVAILABLE (ensure produced no verdict)`.
- `--check` exits before this point, so the pre-build freshness probe does not
  index or write anything.
- The index is never committed: `.codegraph/` is in `.gitignore`, and the
  harness-sync dirty check ignores untracked files anyway.

It puts `/usr/local/bin` on PATH first. The daily update-runners lane runs
under the cron PATH (`/usr/bin:/bin`), where neither `codegraph` nor the
`node` its shim execs resolves, and without that the backstop would record
"CLI not installed" on a box that has it and skip the refresh.

A box with no checkout (project-10) records ensure's `no main clone at ...` line like
any other NOT AVAILABLE.

Suite: `tests/codegraph-harness-index.bh-113-test.sh`.
