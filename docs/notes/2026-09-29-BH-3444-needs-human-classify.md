# The needs-human classifier, review suffix and triage escalate hook (BH-3444)

Doc: RUN-BUILD-GRAPH

## What changed

This is slice 3 of 5 of BH-3433. It fills in the three classify stubs the
contract (BH-3442) left in `bin/lib/needs-human/classify.sh`, and adds one hook
to `bin/triage-shard.sh`. `bin/lib/rb/review.sh` is not edited: its seams
already call these functions.

- `nh_classify <review.md | --text STRING>` reads only the review's final
  round, the text after the last `=== ` header review.sh writes before a merged
  re-review (the whole file when there is none). Fenced code, `>` quotes and the
  `VERDICT`/`TIER` tag lines are never candidates.
  1. A line starting `NEEDS_HUMAN: <action>` wins, whatever the verdict.
     Placeholders (`none`, `n/a`, `no`, `nothing`, `-`, anything in `<…>` like
     the prompt's own `<one-line action>`) are skipped.
  2. Only when the file's last `VERDICT:` line is `BLOCK`, the first line that
     matches one of four shapes and no negative. The shapes: needs a
     human/person/operator; run … from the hub (or as the hub's GitHub
     identity); paste … output … PR body; a credential, key or env file the
     build box lacks. The negatives: negated need ("does not need a human"),
     `non-blocking`, `(minor)`/`(nit)`, and "was/already/now answered,
     resolved, cleared, addressed". Past-tense "ran"/"executed" is not a shape,
     so hub history never classifies.
  3. Otherwise `none`, rc 1. No args or an unreadable file is rc 2.

  `--text` runs step 2 alone on a bare string, for a triage reason.
  The action is one line, at most 160 characters. The regexes are algorithm
  constants, not settings, so a settings edit can never change which tickets
  hold.
- `nh_on_block <project> <issue> <review.md> <build-dir>` does nothing unless
  the issue is a number (review.sh sets it only on an issues board). On a hit it
  fingerprints the action with `nh_fingerprint`, writes `<build-dir>/needs-human.txt`
  (`action:` and `fp:`), calls `bin/needs-human-hold.sh <project> <issue> <fp> <action> review`,
  appends `<stamp> needs-human: <fp> "<action>" — placer rc=<N>` to
  `pipeline.log`, and prints ` NEEDS_HUMAN:<fp>:<action>`, which review.sh
  appends to `REVIEW_BLOCKED <art>`. It always returns 0 and the placer's
  stdout is discarded, so the terminal word never changes.
- `nh_prompt_field_note` now prints one sentence at the end of the general
  review prompt asking for `NEEDS_HUMAN: <one-line action>` above `TIER:` when
  a BLOCK finding can only be cleared by a person.
- `bin/triage-shard.sh`, right after `decision-log.sh`, reads the same first 40
  `DECISION:` lines (330 chars each). For each `<KEY> :: escalate :: <reason>`
  with a numeric key on an issues board (`fleet-conf board_prefix` is `-`),
  it runs `nh_classify --text "<reason>"` and on a hit calls the placer with
  source `triage`, then logs one `needs-human:` line with the placer's rc to
  `logs/<project>.log`. Fail-open: no lib, no placer, or a product board and
  nothing happens.

## What it does NOT do yet

The suffix means *classified*, not *held*. `bin/needs-human-hold.sh` is still
the BH-3442 stub (exit 0, no gh call) until BH-3433.1 (#3443) replaces it, so
no hold is placed on any issue by this slice. `placer rc=0` today means only
that the stub ran.

## Tests

`tests/needs-human-classify.bh-3444-test.sh`,
`tests/review-needs-human.bh-3444-test.sh` (drives `LENS_REFUSE review` from the
flattened pipeline) and `tests/triage-escalate-needs-human.bh-3444-test.sh`
(runs the real `bin/triage-shard.sh`). `tests/needs-human-contract.bh-3442-test.sh`
C3 now pins the prompt sentence instead of the stub's empty output.
