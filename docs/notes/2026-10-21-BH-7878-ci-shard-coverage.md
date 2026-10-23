# BH-6491 coverage: shard sizing by measured time (BH-7878)

Doc: ci-durations

## Why this note exists

The last merged slice of #6491 (PR #7867) had no requirements coverage table.
Its close-out could not prove the scope was built, so it filed #7878. This note
maps each #6491 requirement to the code and the test on main `3b1153e2`
(2026-10-21T19:26Z). `tests/ci-shard-coverage.bh-7878-test.sh` pins every row
to the tree: a cited path, line or symbol that moves turns that suite red.

The code of #6491 shipped in three merges:

- `d1bf60e3` (#6997, BH-6876, 2026-10-16): the time sizing, its knobs and the
  logged count fallback.
- `0dccbf3a` (#7644, BH-7620, 2026-10-20T10:03Z): knob defaults 480 s -> 1200 s
  and 12 -> 24 shards.
- `a7aa6ba7` (#7867, BH-6491, 2026-10-21T18:56:54Z): the
  `::notice title=ci-plan sizing::` line, `bin/ci-shard-replay.sh` and the
  acceptance-1 test.

## Requirements coverage

| R | #6491 requirement | On main | Commit | Test | Status |
|---|---|---|---|---|---|
| R1 | Size the shards by recorded suite duration | `size_by_time` at `bin/ci-plan.sh:1076`, fed by `CI_PLAN_DURATIONS_FILE` | d1bf60e3 | `tests/ci-plan-shard-by-duration.bh-6491-test.sh` D1 | MET |
| R2 | Target wall time per shard: a DB row, default 10 min, code fallback | knob `catalog/lanes.d/ci-plan-settings.knobs.d/CI_SHARD_BUDGET_S.json` (default 1200 s), code fallback 480 s at `bin/ci-plan.sh:343` | d1bf60e3, 0dccbf3a | `tests/ci-plan-shard-by-duration.bh-6491-test.sh` D4 | MET-AMENDED |
| R3 | Between 1 and 8 shards | knob `catalog/lanes.d/ci-plan-settings.knobs.d/CI_MAX_SHARDS.json` (default 24), code fallback 8 at `bin/ci-plan.sh:342`; floor 1 at `bin/lib/suite-runner.sh:165` | d1bf60e3, 0dccbf3a | `tests/ci-plan-shard-by-duration.bh-6491-test.sh` D1 (`cap 8` with no variable) | MET-AMENDED |
| R4 | Longest-processing-time-first bin packing over the selected suites | `suite_shard_size` at `bin/lib/suite-runner.sh:155`, over the LPT split of `suite_shard_plan` | d1bf60e3 | `tests/ci-plan-shard-by-duration.bh-6491-test.sh` D1, D5 | MET |
| R5 | A suite with no recorded duration counts as the corpus median | median at `bin/lib/suite-runner.sh:132` | d1bf60e3 | `tests/ci-plan-shard-by-duration.bh-6491-test.sh` D1 (48 of 93 suites at the median) | MET |
| R6 | No ledger: the count split, and the fallback is logged | fallback block at `bin/ci-plan.sh:1104`, line `sizing: count, ceil(...) cap N (<why>)`, run-page notice at `bin/ci-plan.sh:1139` | d1bf60e3, a7aa6ba7 | `tests/ci-plan-shard-by-duration.bh-6491-test.sh` D2, D3, D7 | MET |
| R7 | Acceptance 1: the test, red on main | `tests/ci-plan-shard-by-duration.bh-6491-test.sh` (D7 was red before a7aa6ba7) | a7aa6ba7 | its own run on 3b1153e2: `ci-plan-shard-by-duration: 20 passed, 0 failed`, rc 0 | MET |
| R8 | Acceptance 2: replay of the last 30 batches, predicted max at or under 14.9 min (comment 6172435630), and the no-ledger fallback count | `bin/ci-shard-replay.sh` (its own suite `tests/ci-shard-replay.bh-6491-test.sh`: 22 passed, 0 failed) | a7aa6ba7 | `## Replay` below | NOT MET |
| R9 | Acceptance 3: re-measure after merge, mean shard wall time and runner minutes per batch, numbers on the ticket | `bin/ci-shard-replay.sh` `--since` | a7aa6ba7 | `## Re-measure` below | MET |

R2 and R3 are MET-AMENDED. The ticket asked for a 10 min target and a cap of 8.
BH-7620 (2026-10-20) set 1200 s and 24 after measured merge-queue ejections:
at 480 s and 12 shards, shards ran past the 45 min job cap and Mergify ejected
green batches. That later operator decision stands, and this build changes no
knob. The code fallbacks are still 480 s and 8.

R8 is NOT MET. The replay at the knobs on main (1200 s, 24 shards) predicts a
max shard mean of 18.8 min. The target is 14.9 min or less. The no-ledger
fallback fired 0 of 30 times. At a 600 s budget the same rule predicts
11.3 min, so the sizing rule can meet the target. The knob default 1200 s
(BH-7620) stops it. A product decision is owed to the operator: lower
`CI_SHARD_BUDGET_S` (near 840 s) to meet 14.9 min, or keep 1200 s against the
BH-7620 ejection risk and drop the target. This note changes no knob.

R9 is MET. Both windows are measured below.

Source of every `replay:` line below: the BH-7878 r2 plan stage on 2026-10-22,
which could read GitHub. The r2 execute stage could not (its `gh api` call
gave `Forbidden` at 2026-10-22T08:34Z), so it pasted the plan stage's lines
verbatim and derived no number. No commit touched `bin/ci-plan.sh`,
`bin/lib/suite-runner.sh` or the sizing knobs between 2026-10-20T10:03Z and
main `311e161c`.

## Replay

Command: `bin/ci-shard-replay.sh --last 30`, run 2026-10-22T07:58Z to 08:04Z,
rc 0. This is the rule on main (knob defaults 1200 s and 24 shards):

replay: 30 batches; actual max shard mean 21.3 min; predicted max mean 18.8 min; no-ledger fallback 0 of 30; runner min per batch mean 276.6; sizing=time 30 of 30
replay: read 30 runs (30 selected-mode) in the window

Result: predicted max mean 18.8 min > 14.9 min, so R8 is NOT MET. No-ledger
fallback: 0 of 30.

Counterfactual at the ticket's 600 s target, NOT the rule on main:
`bin/ci-shard-replay.sh --last 30 --target 600 --max 24`, ended by
2026-10-22T08:20Z, rc 0:

replay: 30 batches; actual max shard mean 21.3 min; predicted max mean 11.3 min; no-ledger fallback 0 of 30; runner min per batch mean 276.6; sizing=time 30 of 30
replay: read 30 runs (30 selected-mode) in the window

History: r1 (2026-10-21T19:41:10Z) could not run the replay. Its egress proxy
denied `api.github.com:443`.

## Re-measure

Window 1 is from the merge of today's knobs (#7644, 2026-10-20T10:03:12Z).
Window 2 is from the merge of the sizing notice (#7867, 2026-10-21T18:56:54Z).
Window 2 is the primary window. Runs before window 2 have no sizing notice:
they show sizing `-`, and the replay uses the knob values for them.

Window 2: `bin/ci-shard-replay.sh --since 2026-10-21T18:56:54Z --last 200`,
ended 2026-10-22T08:09Z, rc 0 (13 h of data):

replay: 33 batches; actual max shard mean 21.3 min; predicted max mean 18.8 min; no-ledger fallback 0 of 33; runner min per batch mean 290.4; sizing=time 33 of 33
replay: read 33 runs (33 selected-mode) in the window

Window 1: `bin/ci-shard-replay.sh --since 2026-10-20T10:03:12Z --last 200`.
A first try hit `timeout 580` (rc 124). The second try, with `timeout 1800`,
ended 2026-10-22T08:32Z, rc 0:

replay: 110 batches; actual max shard mean 22.3 min; predicted max mean 25.8 min; no-ledger fallback 0 of 110; runner min per batch mean 285.8; sizing=time 33 of 110
replay: read 111 runs (110 selected-mode) in the window

Window 1 caveat: 77 of the 110 runs are older than the sizing notice. For
those runs the tool used `CI_SHARD_BUDGET_S`/`CI_MAX_SHARDS` from the shell,
else 480 s and 8. The shell set neither, so they were predicted at 480 s and
cap 8, not at the knobs on main. The predicted mean 25.8 min does not measure
the rule on main. Only the actual and runner numbers of window 1 are
re-measure data. Both windows asked for 200 runs. GitHub artifacts expire
after 3 days, so the tool found 33 and 111.

Re-measure numbers: mean selected-mode max shard wall time 21.3 min (window 2)
and 22.3 min (window 1); runner minutes per batch 290.4 (window 2) and 285.8
(window 1). The PR body of BH-7878 r2 carries them under `## Re-measure
numbers`, and the close-out comment on #7878 quotes that section.
