# A "this branch must not touch X" arm must gate on its own slice

Doc: TEST-DETERMINISM

**What changed.** `bin/test-determinism-lint.sh` gained an `error` rule,
`branch-arm-ungated`. It fires on a shell suite line that captures this
checkout's diff against main (`git diff --name-only` with `origin/main` or a
`$BASE`/`$MB`/`$MERGE_BASE`/`$REF`/`$B` ref) when the block around it asserts on
the result (`bad`, `eq`, `fail`) and nothing in that block says whose branch it
is judging. Two ways to be quiet, both a code line in the same block: grep the
diff for the ticket's spec directory (`.harness/specs/BH-N/`), or carry an
`own-slice: <paths>` marker. A comment saying either is not a gate.

**Why.** An arm like that runs on EVERY PR's CI, so it goes red on whoever edits
that path next, for their own ticket, with nothing to fix. On 2026-09-21 #1158
went red on `tests/inapp-prompt-blocked-rule.bh-903-test.sh` for editing
`worker/`, and #727 on `tests/file-children.bh-981-test.sh` for editing
`bin/triage-gate.sh` on BH-590. #1260 gated those two by hand, #1344 did the
same for `run-rollout.bh-984` and #1356 for `priority-rank`'s A10. Four hotfixes
for one shape is a class, and a class belongs in the lint that already runs on
every PR.

**What it touches.**

- `catalog/determinism-lint.conf` — the `rule` line plus four knobs:
  `branch_arm_gate_re` (what a gate looks like), `branch_arm_assert_re` (what
  counts as judging: `bad`, `eq`, `fail`), `branch_arm_skip_re` (the command
  quoted as prose in a SKIP message is not an arm) and `branch_arm_break_re`
  (where "the same block" ends: a blank line, or a `──`/`----`/`====` header).
  The gate regex deliberately does not require a slash after the ticket number:
  a block covering two sibling tickets writes it as a character class, which is
  what `tests/priority-rank-test.sh` does with `.harness/specs/BH-64[45]/`.
- `bin/test-determinism-lint.sh` — the block/gate/assert pass, beside the
  existing `race-sleep` and `clock-rolling-window` special cases, and the
  finding's message.
- `tests/hotfix-lib-test.sh` — the #368 "no new `bin/alert-*` sink" arm now
  gates on `own-slice: bin/lib/hotfix-lib.sh bin/lib/triage-hotfix-lib.sh` and
  prints a `note:` on every other branch.
- `tests/render-rules-test.sh` — the B6 "five consumers of rules/CLAUDE.md are
  untouched" arm gets the same gate on
  `own-slice: bin/render-rules.sh bin/lib/render-fragments.sh rules/topics/`.
  That arm already retires itself on main through the `main already split` SKIP,
  so this is belt and braces — but the lint reads the text, not the reachability.
- `tests/test-determinism-lint.bh-1261-test.sh` — thirteen cases, mostly
  negatives: a fixture-tree diff, a `--diff-filter=U` read, a capture with no
  assertion in its block, the command quoted in an `echo`, a gate sitting at the
  `if` head above the captures, and a comment that names a spec dir and must
  still be a finding.

The whole tree is clean under the new rule on the day it lands: the two arms
above were the only ungated ones in 709 scanned test files.
