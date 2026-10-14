# Needs-human release: a person's evidence reaches the next build (BH-3446)

Doc: RUN-BUILD-GRAPH

## What changed

This is slice 5 of 5 of BH-3433. It replaces the three stubs in
`bin/lib/needs-human/release.sh`. The hooks in `bin/lib/rb/review.sh`
(`REVIEW_PROMPT`) and `bin/lib/rb/pr.sh` (`NH_PR_SECTION`) already call them,
so neither file changed.

- `nh_release_evidence <slug> <issue>` reads the issue thread through
  `gh_rest`, 100 comments a page, up to 1000. It reads the same way
  `hold_check_thread` in `bin/lib/hold.sh` does, but it does not source that
  lib. The hold is the newest comment whose first line starts with
  `NEEDS-HUMAN:`, from any author, because the placer posts as a Bot. The
  evidence is the newest non-Bot comment after the hold whose first line
  starts with `HUMAN-STEP-DONE:`, or is a `## Hub probe … PASS` header that
  does not also say `FAIL`. "First line" means the first non-blank line, with
  CR and leading blanks stripped. So a comment that quotes the protocol
  (`> HUMAN-STEP-DONE:`), mentions it mid-body, or says "Do NOT post
  HUMAN-STEP-DONE yet" never counts. Order comes from `created_at`. A
  timestamp that isn't ISO sorts oldest, and the REST index breaks ties
  inside one second.
  It prints `comment: <url>`, `author: @<login> at <created_at>` and the
  first 40 lines of the body, with rc 0. If there's no hold, or no release
  after the newest hold, it prints nothing and returns rc 0. If it can't read
  the thread, it prints nothing and returns rc 2. That covers a bad slug or
  issue number (checked before any network call), no `gh_rest`, a non-zero
  read, a non-array page, and more than 1000 comments.
- `nh_prompt_release_note` appends a blank line, then "A person ran the human
  step; their evidence is below. Do not re-block on that finding; check the PR
  body quotes it.", then the evidence.
- `nh_pr_body_section` prints a `## Human step evidence` section, a
  `From <url>:` line and the evidence as a blockquote. A heading inside the
  evidence stays quoted and can't open a PR-body section.
- Both renderers return rc 0 always and print nothing when there is no
  evidence. The prompt and the PR body stay byte-identical then. On a board
  project (not an issues board) `NH_SLUG`/`NH_ISSUE` are empty, so no read
  happens at all.

The contract header in `bin/lib/needs-human.sh` still says every release
function returns rc 0. This ticket said not to edit that file, so it was left
alone. `nh_release_evidence` now returns rc 2 on an unreadable thread, and the
two renderers still return rc 0.

## Pinned by

- `tests/needs-human-release.bh-3433-test.sh` covers these cases:
  - E1-E12: the evidence read against a stubbed REST thread.
  - N1-N2: `REVIEW_PROMPT` cut from the flattened pipeline, with the seam.
  - P1-P2: the PR body through pr.sh's evidence block, over the real
    `gh-rest.sh`.
- `tests/needs-human-contract.bh-3442-test.sh` R1 now expects rc 2 from the
  evidence read against an empty stub reply. N1 now allows gh reads and still
  forbids alert-line and jobs calls.
