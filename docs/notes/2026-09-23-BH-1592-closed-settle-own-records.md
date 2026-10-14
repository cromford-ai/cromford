# The closed-unmerged settle reads the harness's own PR records, not the repo's closed list

Doc: MERGE-CONDUCTOR

## What was wrong

`tick_project` in `bin/merge-conductor.sh` found closed-unmerged PRs with
`harness_pr_list "$SLUG" closed … 30`. That call pages the repo's raw closed
list (`GH_PR_LIST_REST_PAGES` pages of 100, `sort=created`) and filters by
author afterwards. On example-org/project-9, 289 of the last 300 closed PRs were
aepod's, so every tick hit the page cap. A harness PR that was created before
the 300th closed row but closed later was never seen. Its row stayed in its last
live state, and the "closed without merging, issue still open" alert never fired.

## What it does now

The conductor no longer walks the closed list. `closed_unmerged_rows` gathers
candidate PR numbers from three places the harness already holds:

1. this slug's pr-state rows whose state is not `CLOSED`/`MERGED`;
2. build records (`builds/*/RESULT`, first line `PR_CREATED <url>`);
3. a closed-watch memo that `closed_watch_seen` writes the first time this
   tick's open list shows a PR. This covers drafts and ticket/* PRs with no
   record. It costs no API call.

It drops numbers that are on this tick's open list and numbers whose memo says
`merged`, `closed` or `gone`. Then it reads each one with
`GET repos/<slug>/pulls/<n>` through `gh_rest`, which sends If-None-Match. The
least recently probed go first, then the newest PR number. It stops after
`GH_PR_LIST_REST_PAGES` reads (default 3), which is what the old walk cost
at most. A read that is not 200/304/404 stops the pass for the tick, writes no
memo and changes no row. That PR leads the next tick.

A PR that answers CLOSED goes through the same settle loop as before (PR lock,
`mc_is_harness_pr`, `ticket_open`, `mc_transition … CLOSED`, `mc_alert`). If
its lock is held, `closed_watch_reoffer` resets its memo to `open 0` so the next
tick reads it first.

## State and the ledger line

- `state/merge-conductor/closed-watch/<safe-slug>/<num>`: one line per PR,
  `state TAB last-probe-epoch TAB url TAB branch`. It is a memo only. The CLOSED
  row is still the record of a settle. Files untouched for 30 days are deleted at
  the end of the pass. Losing one costs one re-read.
- The per-tick read cap is `GH_PR_LIST_REST_PAGES`, now registered as a knob of
  the `merge-conductor` lane in `catalog/lanes.d/merge-conductor.json` (int,
  default 3, 1..30) because the lane script reads it. It is the same variable
  that caps `bin/lib/gh-pr-list.sh`'s REST pages. A value that is not a positive
  integer reads as 3.
- Every tick with at least one candidate logs
  `<slug> CLOSED-PROBE candidates=<n> probed=<m> closed=<c> deferred=<d> budget=<B>`
  to `logs/merge-conductor.log`. A tick with no candidates logs nothing and makes
  no request.

## Why not the search API

Search costs one request per harness author per repo per tick, in a 30/min
bucket that every project on one App installation shares. Its results don't
carry the head branch either. Reading our own records needs no search, so there
is no search bucket to ledger.

## What it no longer sees

A harness PR that was never on an open list the conductor read, has no build
record on this box and has no pr-state row is no longer found. The old walk
found one only if it fell inside the first 300 closed rows.

Pinned by `tests/merge-conductor-closed-settle.bh-1592-test.sh`.
