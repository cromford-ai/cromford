# Shared untriaged read layer: bin/lib/untriaged-lib.sh (BH-2751 part 1, BH-2752)

Doc: GH-REST

## What changed

New sourced library `bin/lib/untriaged-lib.sh`. It has no callers yet. The
BH-2751 siblings (the untriaged-wake lane and the daily digest) import it, so
they all read GitHub-Issues boards the same way.

- **`ut_gh_projects [fleet_conf]`** prints `<project> <owner/repo>` for every
  fleet.conf row whose board-api-prefix (col 4) is `-`. The default conf is
  `${HARNESS:-/root/harness}/fleet.conf`. Comments and blank lines are skipped.
  It uses the same predicate as `bin/fleet-conf.sh --projects-with-board`,
  flipped, so the two always agree. A missing or unreadable conf is rc 1 with
  no output.
- **`ut_open_issues <owner/repo> [max_pages]`** prints ONE compact JSON array
  of `{number, comments, created_at, title, body}` for open `ai-build` issues,
  with pull requests dropped. It is a thin projection over
  `gh_rest_issue_list` (`bin/lib/gh-rest-list.sh`), which owns the paging, the
  `.pull_request` filter and the partial-page rule. `max_pages` (default 5)
  becomes a row cap of `max_pages*100`. A result that reaches the cap sets
  `UT_OPEN_ISSUES_CAPPED=1` (0 otherwise), so a caller knows the list may be
  incomplete.

## Failure rule

A failed read is never "no tickets". A 403, 404, 429 on any page, a dead
`gh`, a bad slug or a bad `max_pages` all print nothing and return 1. `[]`
under rc 0 is a real empty board. The read runs as a plain command writing to
a temp file, so `GH_REST_STATUS` and `GH_REST_REASON` are still set in the
caller's shell for `gh_rest_alert`.

Pinned by `tests/untriaged-lib.bh-2752-test.sh`, which drives the real
`gh_rest` through a stub `gh` on PATH.
