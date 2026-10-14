# A plan's "## Sibling claims (not touched)" section is not its claim

Doc: BUILD-CONCURRENCY

## What changed

- **`bin/planned-files.sh` skips one section.** A plan.md section headed
  `## Sibling claims (not touched)` (case-insensitive) is not scanned by either
  extraction pass, the file-token pass or the bare-directory pass. The section
  runs to the next `#` or `##` heading. A deeper heading stays inside it only
  when its title starts with a ticket key (`### BH-455`); any other deeper
  heading, such as `### Task 1`, ends it (BH-1919). If
  the heading is missing or written at level 3, nothing is skipped, and that
  errs toward over-listing. A path named both in the section and in a task is
  still listed, from the task line. Everything else still over-lists as before,
  including "Out of scope: do NOT edit X" lines.
- **The PLAN prompt says where the note goes.** The ACTIVE FILE CLAIMS clause in
  `bin/run-build.sh` and its stage-module copy in `bin/lib/rb/plan.sh` tell the
  planner to write every note about a sibling's files ONLY under that heading,
  and never to list a file it will edit there.

## Why

The planner is told to read `state/claims/<project>/` and avoid those files, so
plans began quoting them ("Active sibling claim BH-455 edits `docs/x.md` … No
overlap"). The extractor scraped those quotes into the build's own
`planned-files.txt`, the build's claim then matched the sibling's, and
`bin/conflict-check.sh` answered `CONFLICT with <sibling>: p ~ p`. On
2026-09-17, BH-417/418/444/445/446/447/463 were all `BUILD_DEFERRED` against
BH-455 this way.

Pinned by `tests/planned-files-sibling-claims.bh-623-test.sh`.
