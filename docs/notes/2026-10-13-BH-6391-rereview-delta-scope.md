# BH-6391: a lead re-review reads the delta, and keeps old findings stable

Doc: LEAD-REVIEW

**Why.** From 2026-10-06 to 2026-10-13 the lead gave 908 verdicts on 415 PRs.
158 re-reviews followed only a main merge, with no new own commit. 30 of those
changed the verdict on the same PR code (20 BLOCK to approve, 10 approve to
BLOCK). After a small own push, 28 approvals turned into a BLOCK. A full re-read
finds new items each time, and each new BLOCK starts a fix round.

**What changed.**

- `bin/lib/lead-prev.sh` (new) computes, parses and fits one scope-note group.
- `bin/lead-review-enqueue.sh` adds the group to a request when the PR has an
  earlier lead row (MERGE, MERGE-WITH-NOTES or BLOCK, not a `lead-replay:` row)
  on another head G. This is in delta and full mode alike:

  ```
  lead-prev:<G40> word:<W> report:state/lead-reviews/lr-<pr>-<G12>.md own-commits:<n|?> own-files:<csv|-|?> main-files:<csv|-|?>
  ```

  `own-commits` counts the non-merge commits in `H ^G ^main`, or is `?` after a
  rebase. `own-files` is the own delta (the tree `ld_classify` counts from, to
  H). `main-files` is what main changed between `merge-base(main,G)` and
  `merge-base(main,H)`, limited to paths the PR touches. A `?` list means git
  could not answer. It does not mean "no delta". A list ends `,+<k>` when it
  left out k paths that are not plain. Over the worker's 4000-char
  `scope_notes` cap, a list becomes its count (`own-files:+30`).
  The enqueue log says `re-review of <G12> (<W>): own-commits:<n>`.
- `bin/lead-review.sh` adds a `## Re-review` prompt section between
  `## Rules pack` and `## Host suite`. It names G, its word, the own commits,
  the own files, the main files and G's report. In delta mode the report is
  already in the diff, so the section leaves it out.
- The NOTE rule. After the model answers BLOCK and G's word was MERGE or
  MERGE-WITH-NOTES, `lpv_downgrade` reads `git diff -U0 G H`. Each
  `- [BLOCK] <path>:<n>[-<m>]` line on lines that did not change becomes
  `- [NOTE unchanged-since <G12>]`. A line that ends with `main-cause: <p>` for
  a `<p>` in the main files stays a BLOCK. `[BLOCK needs-human]`,
  `[BLOCK split-required]` and a BLOCK with no `path:line` never change. With no
  `- [BLOCK` line left, the verdict is MERGE-WITH-NOTES, and the report header
  gets `- re-review: from <G12> (<W>); <k> BLOCK finding(s) on lines unchanged
  since then kept as NOTE`. If git cannot read G or H, the BLOCK stands and the
  log says `re-review check could not read git`.
- `prompts/lead-review.md` has a `## Re-review rules` block: the NOTE rule and
  its `main-cause:` exception, "a BLOCK lists every finding at once", and "a
  BLOCK on code the earlier review read ends with `missed-because: <why>`". The
  last two are prompt rules only. No code checks them.
- `bin/lead-review-land.sh` step 2a-flip logs ONE line per request when the
  group says `own-commits:0` and the verdict class (BLOCK vs MERGE and
  MERGE-WITH-NOTES) differs from its word:

  ```
  flip <repo>#<pr> <G12> <W> -> <H12> <V> own-commits:0 request:<id>
  ```

  The marker `state/lead-review-land/flip-<id>` keeps it to one line across
  reruns. It gates no post, no stamp and no counter.

**How to count it.** On the hub: `grep -c ' flip ' logs/lead-review-land.log`.
On a lead review box: `grep 'kept as NOTE' logs/lead-review.log`.

**Not covered.** Requests filed outside the enqueue (`bin/lead-verdict.sh
request`, in-build requests) carry no group, so they get no section, no NOTE
pass and no flip line. `ld_classify` (replay, delta or full) is not changed.

Verified by `tests/lead-review-delta-scope.bh-6391-test.sh`.
