# BH-7121: a check run with completed_at and a green conclusion is completed

Doc: MERGE-CONDUCTOR

## What changed

- New lib `bin/lib/mc/check-run-state.sh` (sourced, no network, no state). It
  holds one jq rule, `CRS_JQ_DEFS` (`def crs_status`), and one helper,
  `crs_word <check-runs json file> <name>`. The rule: a check run with a
  non-empty `completed_at` and a conclusion in {success, neutral, skipped} has
  the effective status `completed`, whatever `.status` says. Every other run
  keeps its raw `.status`. The rule changes the status only, never the
  conclusion.
- Three queue-path readers use it:
  - `bin/lib/autoenqueue.sh` `_ae_gates` G4 (the required checks before
    `@mergifyio queue`). It still accepts only `completed/success`.
  - `bin/lib/mc/landing.sh` `landing_eligible` step 8 (fast checks). It still
    accepts only `completed/success`.
  - `bin/lib/mc/queue.sh` `mc_mergify_batch_green`. Neutral and skipped
    already counted as green there, so they count with `completed_at` too.
- If the lib cannot load, each reader fails closed: G4 skips the row
  (`'<name>' is unreadable on this head`), step 8 refuses `fast-checks`, and
  `mc_mergify_batch_green` answers rc 75 (unreadable).

## Why

On PR #7099 GitHub reported the check run "Prompt replay evals (prompts/**
only)" as `status: in_progress` with `conclusion: success` and `completed_at`
set. Its workflow run 38900065868 was `completed`. G4 built its word from
`.status` alone, logged `is in_progress/success on this head`, and did not
post the enqueue. The PR waited 20+ minutes until the job was re-run by hand.

## Not changed

- `mc_ci_state` reads `actions/runs`, which has no `completed_at`.
- Other lanes that read check-run status keep their own rule:
  `bin/lib/mc/train.sh`, `bin/lib/mc-foreign-red.sh`, `bin/lead-review.sh`,
  `bin/lib/fixround-preflight.sh`, `bin/lib/archie-fm-queue/common.sh`,
  `bin/alert-verify/main-red.sh`. Each one can prefix its jq with
  `$CRS_JQ_DEFS` in a later change.
- The Mac gate tool is out of scope (the ticket says so).

Test: `tests/check-run-state.bh-7121-test.sh`.
