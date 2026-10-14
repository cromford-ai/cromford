# A failed shared-file extraction is named in the split comment, and its WARN carries the reason and the partial list

Date: 2026-09-22
Ticket: BH-1343

## What changed

`paths_of_body` in `bin/lib/fc-issues.sh` already refused to read a failed
extraction as "nothing shared" (the `|| return 2` arm, BH-579.4). Two things it
did not do:

- **The WARN said only that it failed.** The extractor's stderr went to
  `/dev/null` and the rc was never printed, so `pipeline.log` named the body and
  nothing else. It now runs the extractor with stderr captured to
  `<body-dir>/planned-files.err`, writes `<body-dir>/extract-failed.txt`
  containing `rc=<n>` plus the first non-empty stderr line (trimmed to 200
  chars), and both WARN sites render that reason plus the partial
  `planned-files.txt` the dying extractor left behind:

      WARN: …/planned-files.sh failed on child 3's body (rc=1: boom) — no contested paths
      computed for this sibling; partial list left in …/decompose-paths/child-3/planned-files.txt: src/x.ts

  A body that died before writing anything logs `none`, and the driver does not
  create a file the extractor never wrote. The partial list is LOGGED and never
  matched against: `bin/planned-files.sh` writes its output progressively
  (`>`, then `>>`, then a rewrite), so a mid-run death leaves an incomplete
  list, and feeding an incomplete list to the `comm -12` intersection produces
  "nothing shared" for paths that are — the exact false negative the return-2
  arm exists to refuse.

- **Only `pipeline.log` heard about it.** The person the shared-file list is for
  reads the split comment on the parent issue. A dead contract-body extraction
  rendered a comment with no list at all; a dead sibling extraction rendered one
  quietly short by that sibling's paths. Both read as "nothing is shared here".
  The comment now carries one line per failed body, under one sentence, placed
  directly after the contested-paths block:

      We could not check every part for shared files, so any shared-file list above is shorter than it should be, or missing:
      shared-file extraction failed: contract body (rc=1: <reason>)
      shared-file extraction failed: TK-552.2 body (rc=1: <reason>)

  The sibling is named by its `TK-552.<n>` key, which is what the link list in
  the same comment calls it (the GitHub number does not exist until the create
  runs). Like the contested block, the sentence renders only when there is at
  least one line under it, so it is true in both states it can appear in: a
  contract failure leaves no list ("or missing"), a sibling failure leaves a
  short one ("shorter than it should be").

A rollout wave has no contract, so the whole paths block is skipped and none of
this reaches its comment. `EXTRACT_FAILED` is initialised outside the block for
`set -u`.

## Why

Two non-blocking findings from the round-2 review of #730 (BH-591). The `§7`
double in `tests/decompose-contract-first-test.sh` exited 1 without writing
`planned-files.txt`, so the assertions could not tell "the return-2 arm fired"
from "sort read a missing file and came back empty" — both produce nothing. The
double now writes a partial list naming a path the contract owns before it dies,
which makes the "no CONTESTED line on the failed sibling" assertion go red the
moment the return-2 arm is removed.

## Artifacts to read

- `$BUILD/pipeline.log` — the WARN, with reason and partial list.
- `$BUILD/decompose-comment.md` — the exact bytes posted to the parent.
- `$BUILD/decompose-paths/<name>/planned-files.err` — the extractor's own stderr.
- `$BUILD/decompose-paths/<name>/extract-failed.txt` — the rendered reason.
- `$BUILD/decompose-paths/<name>/planned-files.txt` — the partial list, left
  exactly as the extractor left it.

## Files touched

- `bin/lib/fc-issues.sh`
- `tests/decompose-contract-first-test.sh`
- `tests/decompose-extractor-failure.bh-1343-test.sh`

Doc: RUN-BUILD-GRAPH
