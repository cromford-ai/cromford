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
| R8 | Acceptance 2: replay of the last 30 batches, predicted max at or under 14.9 min (comment 6172435630), and the no-ledger fallback count | `bin/ci-shard-replay.sh` (its own suite `tests/ci-shard-replay.bh-6491-test.sh`: 22 passed, 0 failed) | a7aa6ba7 | `## Replay` below | NOT RUN |
| R9 | Acceptance 3: re-measure after merge, mean shard wall time and runner minutes per batch, numbers on the ticket | `bin/ci-shard-replay.sh` `--since` | a7aa6ba7 | `## Re-measure` below | NOT RUN |

R2 and R3 are MET-AMENDED. The ticket asked for a 10 min target and a cap of 8.
BH-7620 (2026-10-20) set 1200 s and 24 after measured merge-queue ejections:
at 480 s and 12 shards, shards ran past the 45 min job cap and Mergify ejected
green batches. That later operator decision stands, and this build changes no
knob. The code fallbacks are still 480 s and 8.

R8 and R9 are NOT RUN. They are not MET. The build box could not read GitHub
(see below). The numbers are still owed.

## Replay

Command: `bin/ci-shard-replay.sh --last 30`, run 2026-10-21T19:41:10Z.

NOT RUN: rc 1 at 2026-10-21T19:41:10Z. stderr:
`ci-shard-replay: runs page 1: gh api repos/example-org/cromford/actions/workflows/harness-ci.yml/runs failed (rc 1: Get "https://api.github.com/repos/example-org/cromford/actions/workflows/harness-ci.yml/runs?status=completed&per_page=100&page=1": Forbidden )`

Cause: the build stage's egress proxy denied `api.github.com:443` (the build's
`egress.log`: `stage=execute DENY api.github.com:443 via=proxy`). The tool
printed no `replay:` line, so this note gives no number. The only replay on
record is from 2026-10-14, before BH-6876, and it does not measure the rule on
main.

To close R8, run it from a box with GitHub read access and paste both
`replay:` lines here. The target is a predicted max shard mean at or under
14.9 min. If the mean is over it, R8 is NOT MET.

## Re-measure

Window 1 is from the merge of today's knobs (#7644, 2026-10-20T10:03:12Z).
Window 2 is from the merge of the sizing notice (#7867, 2026-10-21T18:56:54Z).
Runs before window 2 have no sizing notice: they show sizing `-`, and the
replay uses the knob values for them.

Window 1: `bin/ci-shard-replay.sh --since 2026-10-20T10:03:12Z --last 200`

NOT RUN: rc 1 at 2026-10-21T19:41:10Z, the same `Forbidden` stderr line as `## Replay`.

Window 2: `bin/ci-shard-replay.sh --since 2026-10-21T18:56:54Z --last 200`

NOT RUN: rc 1 at 2026-10-21T19:41:10Z, the same `Forbidden` stderr line as `## Replay`.

To close R9, run both windows from a box with GitHub read access. Paste the
`actual max shard mean` and `runner min per batch mean` lines here, and post
them on #7878. Window 2 is 6 h old at 2026-10-22T00:57Z.
