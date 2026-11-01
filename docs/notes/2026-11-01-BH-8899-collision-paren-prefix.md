# BH-8899: pc_resolved reads the decision word past a (PR #N sha) parenthetical

Doc: RUN-BUILD-GRAPH

## What changed

`pc_resolved` (`bin/lib/plan-collisions.sh`) reads a `## Design collisions`
bullet in two steps:

1. The first word after the backticked name decides, as before.
2. If that word is not `combine` or `needs-human`, the first word after the
   first colon that follows the name decides. This step runs only when no
   backtick sits between the name and that colon.

So `- \`spawn_one\` (PR #8351 abc123): combine — additive, ...` now reads as
combine. The BH-8813 rule stays: only the first word of the chosen spot counts.
The rc contract (0 combine, 1 unresolved, 2 needs-human) does not change.

## Why

The planner and its repair pass write the `(PR #N sha)` shape. The `(` cut the
decision word to "", so the line read unresolved. BH-6025, BH-7877, BH-8364
and BH-8848 stopped PLAN_BLOCKED on 2026-10-30/31 with every collision answered.

## Limits

A colon inside the parenthetical (`(PR #1 at 12:30): combine`) still reads
unresolved. That is the safe direction: one repair pass, then PLAN_BLOCKED.

## After merge

Re-put BH-6025, BH-7877, BH-8364 and BH-8848 with `bin/queue-line-put.sh`.

Test: `tests/plan-collisions-paren-prefix.bh-8899-test.sh`.
