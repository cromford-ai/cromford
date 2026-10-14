# The decompose parent close only closes a split it can verify

Doc: EVENTS

## What was wrong

`bin/decompose-parent-close.sh` closed #594 three times (2026-09-16 23:43Z,
2026-09-17 01:23Z, 2026-09-19 01:23Z). Its close comment listed four children
as "closed without a PR". Three things were wrong together:

1. #594 still carried `ai-build`. The only label check was "is the parent in
   the ai-build issue list", and that list was `--limit 100`, so a parent past
   row 100 read as unlabelled. `parent_state()` never asked for labels.
2. All four children were closed NOT_PLANNED. Any CLOSED child counted as a
   delivered part.
3. A child with no PR still let the parent close, and the comment printed
   "closed without a PR" for it. An OPEN PR on the child's branch was also
   accepted as the PR that shipped it.

#935 (folded in) added that a child's PR is often only named on the child's
own thread, so branch/title matching missed it.

## What it does now (GitHub-issues lane only)

- Both list reads are `--limit 1000` (the REST paging ceiling
  `bin/lib/gh-rest-list.sh` already fixes). The issue list also reads
  `stateReason`. A split past the ceiling reads as incomplete and is skipped.
- `parent_state()` reads `number,state,title,labels`. An OPEN parent carrying
  `ai-build` (any case) is refused. So is one whose view has no `labels` field.
- Every child has to be CLOSED with `stateReason == COMPLETED`. A missing
  reason counts as unknown and the parent is skipped.
- Every child has to resolve to a MERGED PR. The pass tries the PR list first
  (branch `ticket/<key>-<n>` or title `<KEY>-<n>:`, merged only). If that finds
  nothing it reads the child's own comments and takes this repo's `pull/<n>`
  links, newest first, at most three. Each one must be MERGED in the list or
  have `merged_at` on `GET repos/<repo>/pulls/<n>`. Another repo's link is
  never read. The URL in the comment is rebuilt from the verified number.
- The comment line is `- #<k> <title>, merged in <url>`. The "closed without a
  PR" line is gone, because a split with a child like that no longer closes.
- A split whose children have all closed but that is refused writes
  `PARENT_CLOSE_SKIPPED #<N> — <reason>` to `logs/<project>.log`. The reason is
  one of `parent carries ai-build`, `child #k closed <REASON|unknown>`,
  `child #k has no merged PR` or `parent state unreadable`. It is logged once
  per change of reason. The watermark is
  `state/parent-close-skip-<project>-<N>`, and a verified close removes it.
  `--dry-run` logs without touching the watermark.

- The refusals that need only the list (label in the list, a NOT_PLANNED or
  unknown child, a short `Order: n of m` split) run for every parent before any
  lookup, and they don't count against `PARENT_CLOSE_MAX`.
- The paid lookups rotate. The live dry run showed why: with 1000 rows the list
  carries dozens of masters that were closed long ago, and each one costs a view
  to find out. A pass that always started at the lowest number spent all ten
  lookups on the same closed masters every tick and never reached #594.
  `state/parent-close-cursor-<project>` holds the last parent looked up, and
  the next pass starts after it and wraps around, so every candidate is reached
  within ceil(candidates / `PARENT_CLOSE_MAX`) cooled passes. Losing the file
  restarts from the top. `--dry-run` neither reads nor moves it.

The stdout contract, the comment-then-close order, the
`parent-close-commented-*` marker, the cooldown, `PARENT_CLOSE_MAX` and the
kill switch are unchanged. The in-app lane is untouched.

## Cost per cooled tick

The label, stateReason and in-list checks read the one list already fetched.
Each candidate parent costs 1 view. On top of that, each child without a merged
list hit costs 1 comments read and at most 3 pull reads. The pass stops at the
first child that doesn't resolve.

Pinned by `tests/decompose-parent-close.bh-949-test.sh`.
