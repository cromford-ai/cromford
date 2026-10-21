# The review gets a NOTE when the merge with main still names a path the PR deletes (BH-7815)

Doc: LEAD-REVIEW

A PR deletes or renames a path and ports every caller its plan found. Then main adds a new
suite that reads the old path. The PR's own CI does not run that suite, so the merge queue
goes red after the review. Three BLOCKs in 14 days had this shape (#6519 three times, #6093
once). Now the pre-review self-check looks at the merge of main and the head.

**What it does.** `cnp_scan` (`bin/lib/callers-not-ported.sh`):

1. Lists the paths the PR deletes or renames: `git diff --name-status -M --diff-filter=DR`
   of the merge base against the head. No such path: no output, and no grep.
2. Writes the merged tree with `git merge-tree --write-tree <base> <head>`. A conflicted
   merge still gives a tree, and it is read.
3. Drops an old path the merged tree still has (main kept or re-added it).
4. Runs one `git grep -F` over the merged tree. It skips binary files and the frozen records
   under `.harness/specs/` and `docs/notes/`.
5. Counts a hit only on a path boundary. `catalog/x.tsv.` and `"catalog/x.tsv"` count.
   `catalog/x.tsv.bak`, `catalog/x.tsvx` and `xcatalog/x.tsv` do not.
6. Names the commit that added a referencing file when the PR does not change that file.

**What the review gets.** The rule `callers-not-ported` (row in
`catalog/pr-self-check.d/bh-7815-callers-not-ported.tsv`) prints one line per
(file, line, old path), 20 at most, then `and <n> more`:

```
NOTE callers-not-ported: tests/a-test.sh:3 still references catalog/x.tsv, which this PR deletes or renames; port it after you merge main. (tests/a-test.sh was added by 0123456789ab, not in this PR's diff)
```

`self_check_hold` (`bin/lead-review-enqueue.sh`) and `lgsc_notes`
(`bin/lib/lead-gates-selfcheck.sh`) each have one added line that forwards it into the lead
review request notes. A step that cannot run prints `could not run: <why>`.

**It never blocks.** The rule is a NOTE in every mode. A `refuse` mode is read as `note`, and
the rule never changes the self-check's rc. Set the row's mode to `off` to turn it off.

**By hand.** `bin/callers-not-ported-lint.sh --base origin/main [--head <ref>] [--repo <dir>]`
prints the same lines as `[NOTE] callers-not-ported: ...`. It exits 0 in every case.

Tests: `tests/callers-not-ported.bh-7815-test.sh`.
