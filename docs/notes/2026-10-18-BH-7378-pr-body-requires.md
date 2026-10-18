# The review gets a NOTE for each body item the plan requires and the PR body lacks (BH-7378)

Doc: LEAD-REVIEW

A plan often says the PR body must carry a section or a literal: flip evidence, an owed
re-measure, operator steps, a `TEST-CHANGE:` line, BEFORE/AFTER counts. The build sometimes
did not write it, and the lead review found the gap. Now the plan lists those items in a
fenced block, and the pre-review self-check reports each item the live body lacks.

**The block.** In `.harness/specs/<KEY>/plan.md`, one item per line, `<item>` or
`<item> <- <source>`:

````
```pr-body-requires
## Flip evidence <- T3
TEST-CHANGE: <- ticket line 4
```
````

- The split is on the last ` <- `. An item with no source reads `the plan`.
- The info string is case-blind (```` ```PR-BODY-REQUIRES ```` counts). It must be the only word.
- An unclosed fence gives no items. Blank lines and duplicate items are dropped.
- The match is fixed-string and case-sensitive, anywhere in the body. `## Flip evidence`
  is also found inside `### Flip evidence`.

The planner gets this rule through `pbr_plan_rule` (`UI_PLAN_NOTE` in `bin/lib/rb/plan.sh`,
`PP_PREAMBLE` in `bin/run-preplan.sh`).

**What the review gets.** The rule `body-plan-requires` (`bin/lib/pr-body-requires.sh`,
row in `catalog/pr-self-check.d/bh-7378-plan-body-requires.tsv`) prints one line per item:

```
NOTE body-plan-requires: the body is missing ## Flip evidence (required by T3)
```

`self_check_hold` (`bin/lead-review-enqueue.sh`) and `lgsc_notes`
(`bin/lib/lead-gates-selfcheck.sh`) already forward this shape into the lead review request
notes. The rule prints 10 lines at most, then one `... missing <n> more items` line.

**It never blocks.** The rule is a NOTE in every mode. A `refuse` mode is read as `note`. It
never sets rc 1, so the verdict and the hold do not change. The fix is a body edit, so the
head does not move.

**By hand.**

```
bin/pr-body-requires.sh check --plan <plan.md> --body <body file>
bin/pr-body-requires.sh check --plan <plan.md> --pr <owner/repo>#<n>
```

It prints `[NOTE] PR body lacks <item> (required by <source>)` per item and exits 0. `--pr`
reads the live body with one `gh_rest` GET. A rate-limited read (rc 75) prints
`[NOTE] not verified here: PR body read rate-limited` and calls no item missing.

**The off switch.** Set the row mode to `off` in the fragment.
