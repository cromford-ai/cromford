# The merge close-out leaves a sliced issue open

Doc: MERGE-CONDUCTOR

## What was wrong

On 2026-09-25 PR #2390 merged C0, the first slice of master ticket #2320. Its body said `Refs #2320`, its plan said "The build for THIS ticket is C0", and C1 to C6 (#2407 to #2412) were open. The merge conductor still posted "Closing this issue." and closed #2320. `mc_close_shipped` and `issue_close_shipped` took the issue number from the build key and closed it without asking whether the merge delivered it.

## What it does now

`issue_close_guard` in `bin/lib/issue-state-lib.sh` checks the build's `plan.md` for the slice marker, then the PR body for a closing keyword for this issue, then the issue timeline for open children. Both close-out helpers run it first when the caller passes a PR url, and all five merge close sites now pass one. A slice gets one `Slice delivered: #<pr>` comment and stays open (`kept-slice:<why>`, rc 0). An unreadable answer writes nothing (`close-deferred:<what>`, rc 1). The knob is `ISSUE_CLOSE_GUARD_PAGES` (default 5). Details are in `docs/verification-map/closed-issue-hygiene.md`.

Suites: `tests/issue-close-guard.bh-2477-test.sh`, `tests/merge-settle-slice.bh-2477-test.sh`.
