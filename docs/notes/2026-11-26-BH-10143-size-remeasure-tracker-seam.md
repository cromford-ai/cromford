# BH-10143: size-remeasure calls the issues API through the tracker seam

Date: 2026-11-26. Ticket: #10143 (main red on `193706086c`).

## What failed

`tests/tracker-direct-calls-ratchet.bh-7919-test.sh` failed on main: `14 passed, 1 failed`, R1, `ratchet: NEW bin/size-remeasure.sh`. Each merge queue batch runs this ratchet, so each batch failed.

## Cause

PR #9520 (BH-9502) added `bin/size-remeasure.sh` with three direct `gh api` calls to the issues API. The ratchet lets only the files on its allow list do that.

## Fix

The script loads `bin/lib/gh-rest.sh`, `bin/lib/tracker.sh` and `bin/lib/tracker/github-issues.sh`, as `bin/web-task.sh` does. The three calls are now:

- `trk_gh_issue_raw` for the read of each gate issue.
- `trk_gh_comments_page` for each page of the #6025 thread.
- `trk_gh_comment_raw` for the one comment POST. The body goes as `-F body=@<file>`.

The allow list is not changed.

## Behaviour difference

The rc in a failure line is now the rc of gh_rest: 44 for not found, 75 for unreadable. Before, it was the exit code of the gh CLI. A gate issue that is not found now logs `rc 44`. Before, it logged `rc 1`. The text of each log line is the same.

## Test change

`tests/size-remeasure.bh-9502-test.sh` fakes the gh CLI. Its stub now answers the `gh api -i -X <method> <path>` calls of gh_rest with a status line, a blank line and the body, from the same fixture files. No assertion changed.
