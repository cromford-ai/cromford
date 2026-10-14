# Single-site issue reads and writes moved to REST

Doc: GH-REST

## What changed

Eight scripts stopped calling the GraphQL `gh issue view|list|comment|close`
and now go through `bin/lib/gh-rest*.sh`. `bin/lib/gh-rest.sh` itself is unchanged.

- `bin/lib/revdep-lib.sh` `revdep_issue_state`: `gh_rest_issue_state_var`.
  The state is upcased (`closed` becomes `CLOSED`). A 403, 429, 75, or unknown state returns rc 1.
- `bin/wake-loop.sh` `closed_diff`: `gh_rest_issue_list <slug> closed ai-build 50`,
  filtered on `.closed_at`. A failed read prints nothing. The revdep tail still runs.
- `bin/review-rescue.sh`: retires a candidate only when the REST read says `closed`.
  A read that did not answer is not a closed ticket.
- `bin/planned-files-cheap.sh`: reads the body with `gh_rest GET repos/<slug>/issues/<n>`.
  A failed read logs `could not read ticket #N (HTTP <status>)`, never "empty ticket body".
- `bin/hotfix-after-deploy.sh`: `gh_rest_comment`, then `gh_rest_close`, which
  returns 0 only on a fresh `closed` re-read. Both CLOSEOUT_ALERT lines keep their exact wording.
  No temp file for the comment body means no comment, no close, and the no-comment alert.
- `bin/load-project.sh`: both title dedupes use `gh_rest_issue_list <slug> all "" 1000`.
  A failed read still means WARN and no create. The helper stops at 10 pages of
  raw `/issues` rows and pull requests count toward them, so on a repo with many
  PRs this proves a title absent over fewer than the 1000 issues the old CLI read.
- `bin/up10-lane.sh`: the dedupe is `gh_rest_issue_list <slug> open ai-build 1000`
  plus an exact title match. The Search API (`--search`) is gone. A failed read still dies.
- `bin/bootstrap-machine.sh`: the access probe is `gh_rest GET repos/<slug>/issues -F per_page=1`.
- The App-token ratchet: `bin/planned-files-cheap.sh` has no raw gh call left, so
  its `raw-pat (BH-425)` marker and `tests/gh-app-ratchet-baseline/planned-files-cheap.sh.txt`
  are gone. It is not marked `app-token`: gh-rest.sh arms nothing, so the read
  still runs on the ambient token, same as before. The registry now holds two
  entries. `tests/ratchet-markers-test.sh` converts two entries and then runs its
  guard cases on what is left, so its slice now adds one fixture-only raw lane
  that sorts after every real entry.

## Why

These reads spent GraphQL quota. When they failed, several of them could not
tell "did not answer" apart from "nothing there". BH-1641 moves decision reads
onto the three-rc REST contract described in docs/GH-REST.md.

Tests: `tests/issue-reads-rest.bh-1641-test.sh`, plus the REST arms added to
the existing suites of each script.
