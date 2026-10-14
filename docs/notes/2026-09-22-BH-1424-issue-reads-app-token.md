# BH-1424: route close-out issue reads through the App token over REST

What changed: `bin/lib/issue-state-lib.sh` no longer uses the GraphQL-backed
`gh issue view` / `gh issue comment` / `gh issue close` / `gh issue edit`
subcommands. `issue_state` now reads via `gh_rest_issue_state`
(`gh api repos/<slug>/issues/<n>`) and `issue_close_shipped` uses
`gh_rest_comment`, `gh_rest_close` and a `gh api .../labels/ai-build` DELETE.

Why: the hub's fine-grained PAT lacks `Issues:Read`, so the GraphQL issue verbs
fell back to the PAT identity and 403'd. The helper already armed itself with the
repo-scoped App token, but the call shape ignored it. REST issue endpoints
honour the App token.

Token isolation: `_issue_arm` still runs inside the same `$(...)` as each REST
call, so the App token never leaks into the caller's shell. A box whose sync has
not landed `bin/lib/gh-rest.sh` fails safe: `issue_state` answers UNKNOWN
(build as today) and `issue_close_shipped` answers `close-failed` at rc 1 with
`ISSUE_CLOSE_ERR="gh-rest.sh not loaded"`, because nothing was closed and no
caller may log it as closed.

Tests: updated `tests/issue-state-lib.bh-637-test.sh` and
`tests/run-build-skip-closed.bh-637-test.sh` to speak REST; added
`tests/issue-state-lib.bh-1424-test.sh` proving a PAT-only box 403s while an
App-token box reads and strips.

Doc: `docs/AUTH.md`, `docs/verification-map/closed-issue-hygiene.md`.
