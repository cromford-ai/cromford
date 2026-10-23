# A comment-only shell change selects only the suites that read it (BH-8099, slice C2 of BH-8050)

Doc: TESTING, MERGIFY

## What changed

A changed `.sh` or `.bash` file whose diff changes only comment lines and
blank lines that bash ignores runs the same commands as before. The new lib
`bin/lib/test-impact-comment-only.sh` finds such paths in `select` and
`ci-select` and drops their `source`, `closure` and `named` rows. The `self`,
`reads`, `learned`, `regression` and `always` rows stay. A suite that scans
the file's directory (a non-comment line names the directory and is not a
pure run or copy line, the fn-reach step-3 rule) also keeps its rows.

A line counts as inert only when a small lexer proves it: it is blank, or its
first non-blank byte is `#` at the start of a command. A line inside a heredoc,
inside an open quote or after a `\` continuation is code. Line 1 `#!` and a
`# shellcheck` directive are code. A `# <tag>:` comment whose tag some script
reads (a git grep over bin, cron, fly, checks, guardrails and tests/lib) is a
directive and falls back. A file that reads its own text (`$0` or
`BASH_SOURCE` on a line with a read verb) falls back. The selector's own libs
`bin/lib/test-impact-*.sh` are never eligible.

Rule P of `bin/lib/test-impact-fn-reach.sh` skips the same inert lines. A diff
that changes code in `f()` and a header comment now narrows to `f` instead of
falling back on a `top-level change`. A diff whose changed lines are all inert
logs `fn-reach: comment only (<p>)`, and the comment-only rule decides it.

In a merge-queue batch, a comment-only `tests/lib/*.sh` helper does not add
its helper closure to the work list.

Env `TI_COMMENT_ONLY=0` is the old selection. Any value other than empty, 0
or 1 is also off and logs one `comment-only: off (TI_COMMENT_ONLY=<v>)` line.
`bin/test-impact.sh inputs` (the suite fingerprint) never runs the rule.

## Measured on this box, 2026-10-23, main 7137c85c

Each of the last 30 first-parent merges of origin/main was checked out on its
own, mapped once, and selected four ways: main's selector and this branch's,
plain and `TI_BATCH_SELECT=1`. (`bin/test-impact-mix.sh` reads the head side
of every path from the current tree, as fn-reach does, so for old merges its
numbers are not what CI saw. The per-merge checkout fixes that.)

| measure | main 7137c85c | this branch |
|---|---:|---|
| median, plain select (30 merges) | 725 | 618.5 |
| max, plain select | 2754 | 2754 |
| median, batch select (30 merges) | 686 | 581 |
| max, batch select | 2753 | 2753 |
| merges whose selection changed | - | 10 of 30 |
| merges with a comment-only shell path | - | 1 of 30 (#8023: 248 to 229) |

Most of the drop is rule P. In 9 of the 10 changed merges, main logged one
or more `fn-reach: fallback (top-level change …)` lines for a lib path, and
this branch logs fewer (19 such lines on main, 2 here, over the 9 merges).
The 10th, #8023, has one comment-only path,
`tests/pool-rereview-row.bh-7635-test.sh` (dropped 20 rows).
Example: #8040 (BH-8028) selected 779 on main and 463 here, because
`bin/lib/lead-carry.sh` now narrows to `lead_carry` (kept 242 of 573
sourcer suites).

The size fixtures of `tests/test-impact-size.bh-8050-test.sh` and the new
lane fixture:

| fixture | main 7137c85c | this branch | bound |
|---|---:|---:|---:|
| Z1 `bin/stuck-work.sh` + its suite (code) | 259 | 259 | 284 |
| Z2 `prompts/build-discipline.md` | 89 | 89 | 97 |
| Z3 `docs/REMOTE-GATE.md` | 62 | 62 | 68 |
| Z5 a header comment in `bin/stuck-work.sh` | 236 | 157 | < 200 |

Z5 keeps 51 always rows, 1 reads row and 111 suites that scan `bin/`. Its log
line: `comment-only: bin/stuck-work.sh: dropped 80 row(s), 112 of 192
suite(s) left, 111 kept by a directory scan`.

Select time on the Z5 range with a prebuilt map, three runs each:

| run | main | this branch |
|---|---:|---:|
| 1 | 1672 ms | 2181 ms |
| 2 | 1666 ms | 2168 ms |
| 3 | 1638 ms | 2130 ms |

The rule adds about 0.5 s, under the 3 s budget of the plan.

## The open gap

The #8050 target is a lane diff under 200 suites and a median batch under 300.
This slice does not meet it. Z1 is a code diff, and the comment-only rule
never narrows a code diff; most of its 259 suites keep a `bin/` directory row
because they scan `bin/`, which C0 keeps on purpose. The batch median is 581.
The comment-only lane shape is under 200 (Z5, 157).
