# The stack-wait gate reads the parent PR state, not the parent branch (BH-6537)

Doc: MERGE-CONDUCTOR

## Why

The `stacked child builds` block of `bin/lib/rb/gates.sh` used one probe for
"the parent is still open": a fetch of the parent branch. A repo with
`delete_branch_on_merge=false` (example-org/project-6) keeps a merged branch, so
the fetch still succeeded after the merge. TK-260 deferred 4 times (about 2 h)
after its parent PR #275 merged. It built only after a person deleted
`ticket/TK-255`.

## What changed

1. **New lib function.** `sw_parent_pr <slug> <branch>` in
   `bin/lib/stack-wait.sh` makes one REST read,
   `GET repos/<slug>/pulls?state=all&head=<owner>:<branch>&per_page=100`. It
   prints `open|merged|closed <n> <url>`, `none`, `unreadable <rc>` or
   `unchecked`. On several PRs with one head, open wins, then the newest merged
   PR, then the newest closed PR.
2. **The gate decides from that line**, in the `parent PR state (BH-6537)`
   sub-block, before the fetch:

   | State | Branch fetch | Outcome |
   |---|---|---|
   | `merged` | not run | build on the base, not stacked |
   | `closed` (no merge) | not run | build on the base, not stacked |
   | `open` | ok | the BH-5234 and BH-6389 path; an empty `STACK_PARENT_PR` takes the PR url |
   | `none` or `unchecked` | ok | the BH-5234 and BH-6389 path; one log line says branch existence decides |
   | `unreadable <rc>` | ok | `BUILD_DEFERRED stack-wait: … could not be read (rc <rc>)`, exit 3 |
   | any not above | fails | build on the base (the old "could not be fetched" line) |

   `unchecked` means this shell has no `gh_rest` or no `GH_AUTH_SLUG`. The read
   runs in every `STACK_WAIT_PARENT_MERGE` mode and for hotfix children.
3. **Logs.** A merged or closed parent writes
   `stack-wait: parent PR #<n> is merged and its branch <b> still exists — building on <base>, not stacked`
   to `pipeline.log`. An unreadable state writes one `pipeline.log` line and one
   `logs/stack-wait.log` line, `parent-pr=unreadable rc=<n> parent=<b> (deferred)`.

## State

None new. An unreadable deferral writes no `stack-wait` row, so the
`STACK_WAIT_CAP_H` clock does not start. A merged parent leaves an old
`waiting` row as it is; no later decision reads it.

## Knobs

None new. `STACKED_BUILDS=0` or `flags/stacked-builds-off` skips the whole
block, the read included.
