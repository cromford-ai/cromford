# The needs-human contract: lib seams, stub placer, knob and hooks (BH-3442)

Doc: RUN-BUILD-GRAPH

## What changed

This is slice 1 of 5 of BH-3433. It adds the interface the other four slices
build on. Runtime behavior does not change: no hold is placed, no alert fires,
the RESULT line gets no suffix, the review prompt gets no text and the PR body
gets no section.

- `bin/lib/needs-human.sh` (sourced) holds the constants `NH_MARKER_PREFIX`
  (`NEEDS-HUMAN:`), `NH_DONE_PREFIX` (`HUMAN-STEP-DONE:`) and `NH_FP_TAG`
  (`nh-fp`, the hidden `<!-- nh-fp:<fp> -->` marker). It also holds the one
  real function, `nh_fingerprint <text>`. That lowercases the text and strips
  D-rule cites (the whole parenthesis), `FRAUD: <class>` tags, backticks and
  punctuation. It drops whole-token hex runs of 7 or more that contain a digit,
  then digits, tokens under 4 characters and stopwords. The rest is sorted and
  deduped, and it prints the first 12 hex of the sha1. When nothing survives,
  it prints nothing and returns 1, so two empty findings never share a
  fingerprint. The header documents every signature and rc contract below.
  The lib sources `needs-human/{classify,trip,release}.sh` from its own
  directory, each one fail-open, and is guarded against a double source.
- The stubs, each returning its documented default:
  - `nh_classify` prints `none` and returns 1.
  - `nh_on_block`, `nh_prompt_field_note`, `nh_trip_on_block`,
    `nh_release_evidence`, `nh_prompt_release_note` and `nh_pr_body_section`
    print nothing and return 0.
  - `nh_trip_note` returns 1 (no trip). It never claims a trip it did not
    measure.
- `bin/needs-human-hold.sh <project> <issue> <fp> <action> <source>` checks
  that it got 5 arguments (usage and exit 2 otherwise). It then prints
  `needs-human: placer not implemented` on stderr and exits 0. It makes no gh
  call and writes no file.
- `catalog/lanes.d/_lib.needs-human.json` registers the lib knob
  `NEEDS_HUMAN_TRIP_COUNT` (int, default 2, min 2, max 10; settings key
  `lib.needs-human.needs_human_trip_count`). Its note documents the kill switch
  `lane_switch needs-human-hold-off`. No code reads either of them yet.
- `bin/lib/rb/review.sh` gets three hooks:
  - A `needs-human seam` block sources the lib fail-open and sets
    `NH_ISSUE`/`NH_SLUG`. They are set only for an issues board (fleet.conf
    board prefix `-`) and are empty otherwise.
  - `REVIEW_PROMPT` ends with `nh_prompt_field_note` and
    `nh_prompt_release_note`.
  - `LENS_REFUSE review` calls `nh_on_block` and `nh_trip_on_block` before
    `RESULT "REVIEW_BLOCKED <art>${NH_SUFFIX}"`.

  The terminal word stays `REVIEW_BLOCKED`. The security and refute cases are
  untouched.
- `bin/lib/rb/pr.sh` computes `NH_PR_SECTION` from `nh_pr_body_section` after
  the `CLOSES_LINE` block, but only for an issues board. `PR_BODY_FOR` appends
  it after the repro section. Empty output keeps the body byte-identical.

## Pinned by

`tests/needs-human-contract.bh-3442-test.sh` covers the following:

- The fingerprint's stability and difference cases, and the empty rule.
- The double-source guard, and a half-synced lib that is still fail-open.
- Every stub's default.
- The placer's argc check, and that it has no side effects.
- The knob, composed through `bin/lanes-build.sh`.
- The seam block, cut from the flattened pipeline.
- `LENS_REFUSE`, with and without the lib, and with a stubbed suffix.
- The PR body, byte-identical with the stub lib and wired when a section is
  returned.
