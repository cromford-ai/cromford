# BH-1483: the branch delete retargets a stacked child instead of closing it

Doc: merge-rest

## What was broken

`_gpm_delete_branch` in `bin/lib/gh-pr-merge.sh` read the merged PR's head ref
and issued `DELETE repos/<slug>/git/refs/heads/<ref>` with two guards and no
third: the head ref had to read, and the head had to live in the base repo. It
never looked at the open PRs whose `base` was that ref.

GitHub closes a PR whose base branch is deleted. `delete_branch_on_merge` is
`false` on these repos, so GitHub's own retarget-on-delete never runs and there
was nothing to catch it. example-org/cromford#1453, from its own event log:

| time (Z) | event | actor |
|---|---|---|
| 14:27:13 | #1441 (`ticket/bh-1385` → `main`) merged | cromford[bot] |
| 14:27:15 | `base_ref_deleted` on #1453 | cromford[bot] |
| 14:27:16 | `closed` on #1453 | GitHub's auto-close |
| 14:48:57 | reopened + `base_ref_changed` | operator, by hand |

#1481 blamed `hold.sh` for that close. It was not hold.sh — `mc_hold_keeps_pr`
only guards the harness's own closers, and this close came from the merge family.
`mc_retarget_base` (`bin/lib/mc/rebase.sh:451`) does retarget a stacked child, but
only on a later conductor tick, by which time the child has been closed for
minutes.

## What changed

`bin/lib/gh-pr-merge.sh`, one function and two new helpers beside `_gpm_del_ref`:

- **`_gpm_open_children <slug> <ref> [token]`** — `GET
  repos/<slug>/pulls?state=open&base=<ref>&per_page=100`, the ref `@uri`-encoded
  because a ref with a `/` is the normal case. rc 0 and one PR number per line
  when the body parsed as a JSON array of fewer than 100; rc 1 with a reason
  phrase on stdout otherwise. A full page is rc 1 on purpose: `_gpc_split` drops
  the `Link` header, so a second page cannot be proven absent, and 100-and-stop is
  not "there are no more" (D12).
- **`_gpm_patch_base <slug> <n> <base> [token]`** — `PATCH repos/<slug>/pulls/<n>`
  with `-f base=<base>`, through `_gpc_split` so the caller branches on the HTTP
  status and never on gh's exit code (D10). REST rather than `gh pr edit --base`
  for the reason `mc_retarget_base` already carries at `bin/lib/mc/rebase.sh:448`:
  that verb has reported success on this object and changed nothing.
- **`_gpm_delete_branch`** — takes `.base.ref` from the pull object it was already
  reading (no extra call), then, between the ownership check and the DELETE:
  lists the children, PATCHes each one to that base, and deletes the ref only when
  every PATCH answered 200. The PATCHes always go out first.

Where a child goes is the merged PR's OWN base, literally — not the repo's
default branch. A doubly stacked PR's base is itself a feature branch, and
retargeting to `main` would silently flatten a stack nobody asked us to.

Every arm that cannot finish the sequence KEEPS the branch and logs one line
naming why: base unreadable, list non-200, list body not an array, list a full
page, any PATCH refused. `_gpm_delete_branch` returns 1 in those arms, which is
new — so the call site in `_gpm_rung` became
`if [ "$del" = 1 ]; then _gpm_delete_branch … || true; fi`. Under a caller's
`set -e` the old bare `&&` form would have made that rc the lane's exit status,
and it is not a failed merge: the merge landed before this function was entered.

One log line per retargeted child, never a silent skip.

## What it costs

One extra GET per merged PR with `delete=1`, and one PATCH per stacked child, on
the REST budget only. `bin/merge-sweep.sh`'s budget counts MERGES per pass, not
API calls, so no cap moves. `bin/merge-conductor.sh:1879` (the stacked-child arm)
is the only consumer of the state this changes: after the retarget the child's
base already equals `PBASE`, so that arm finds nothing to do and the row falls
through to the generic `WAIT_CI checks none` kick at `bin/merge-conductor.sh:2351`,
which is what fires CI on a head a base change never touched.

## Not fixed here

`gshim_prw_delete_branch` (`bin/lib/gh-shim/pr-write.sh:113`) carries the same
defect. The shim is not on any box's PATH yet and the `gh pr merge
--delete-branch` fallback lines it would serve only run when every REST rung
failed or the kill flag is on. Extracting a shared helper and calling it from both
libs doubles this diff and its review surface; it is worth its own ticket.

## Tests

`tests/merge-branch-delete-children.bh-1483-test.sh` — 33 assertions against a
stub `gh`, asserting on the call log, its ORDER, the pipeline log and true exit
codes. One open child (PATCH line before DELETE line), two children, no children,
a `[]` answer while a `ticket/bh-1385-followup` branch exists (GitHub's `base=`
filter is exact and the lib must do no prefix matching of its own), list 500, list
body not an array, list full page, PATCH 422, base unreadable, fork head, no token
value in any artifact, and a mutation block that redefines `_gpm_open_children`
away and asserts the lib then does what it did before this fix.

`tests/merge-rest-test.sh` and `tests/poll-commands-merge-pr.bh-892-test.sh` got
fixtures only: a `children` arm in each stub and `resp children '200 OK' '[]'` plus
a `base.ref` on the pull object in the cases that reach the DELETE. No new
assertions there — the new cases all live in the BH-1483 suite.
