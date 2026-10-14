# A `### Task` heading ends the skipped "## Sibling claims" section

Doc: BUILD-CONCURRENCY

## What changed

- **`bin/planned-files.sh` ends the skipped section sooner.** The
  `## Sibling claims (not touched)` section BH-623 skips still ends at the next
  `#` or `##` heading. It now also ends at any level-3-or-deeper heading whose
  title does not start with a ticket key. `### BH-455` and `#### TK-12 notes`
  stay inside it as per-sibling sub-headings. `### Task 1`, `### Files to touch`
  and `#### Step 1` end it. Once ended, a later `### BH-9` does not restart it;
  only the `##` sibling heading turns skipping on.
- Plans without the sibling heading extract exactly what they did before.

## Why

The skip only looked at level-1/2 headings. A plan that wrote `### Task 1`
straight after the sibling section, with no `## Tasks` heading between, lost
every path its tasks named. The claim under-listed, and `bin/conflict-check.sh`
could not see a real overlap with a running sibling. Under-listing is the
direction the extractor is meant never to err in.

Pinned by `tests/planned-files-sibling-heading.bh-1919-test.sh`, with
`tests/planned-files-sibling-claims.bh-623-test.sh` still pinning the
sub-heading, end-of-file and no-marker cases.
