# 2026-10-15 — BH-6801: a stacked PR's shards take the plan job's main merge-base

Doc: MERGIFY

## What changed

A PR whose base is not main (BH-5795), and a `workflow_dispatch` with
`scope=impact`, are diffed against main's merge-base. The plan job and every
shard used to read that merge-base from their own checkout of `origin/main`.
Main can move between the two checkouts. On #6776 the plan job read e961ff7a
(2269 suites, 8 shards) and the shards read 7e4e6c0f (376 suites, 4 shards),
so `--expect-n` refused every shard.

Now `bin/ci-plan.sh` pins it:

- The plan job (no `--expect-n`) writes `CI_PLAN_MAIN_BASE_FILE`:
  `main_base=<40-hex sha, or ->` and `base_ref=<CI_BASE_REF, or ->`. A write
  failure is rc 2, and no shard count is published.
- A shard (`--expect-n`) reads that file and never reads `origin/main`. The sha
  must be a commit in the checkout and an ancestor of HEAD. `main_base=-` means
  no merge-base, the full corpus, as in the plan job.
- A shard with no file, no `main_base=` line, a value that is not `-` or a
  40-hex sha, a sha it does not hold, or another `base_ref` is rc 1. The
  message names BH-6801 and the cause.
- The shard summary says `impact against main's merge-base <sha8> (pinned by
  the plan job)`.

`.github/workflows/harness-ci.yml` sets the variable to
`${{ runner.temp }}/ci-durations/main-base.txt` on both ci-plan steps. The file
rides the existing `ci-durations` artifact. No new artifact, output key or
knob. `--expect-n` is unchanged.

A PR on main, a merge-queue batch, a push, the nightly tier and a full dispatch
never read or write the file.

Test: `tests/ci-plan-pinned-base.bh-6801-test.sh`.
