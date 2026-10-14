# Rules and prompts drop the human seat, with a lint (BH-4582, BH-4572.3)

Doc: MERGE-CONDUCTOR

## What changed

the operator, 2026-10-05: the tier is a recorded risk class, never a merge gate.
BH-4579 moved the code (`bin/lib/tier-gate.sh`, `tier_gate_mode`). This slice
moves the text every session reads as policy.

- `rules/topics/01-iron-guardrails.md`, guardrail 1. "the hub's own merge
  sweep, which lands reviewed tier-2 PRs under the operator's standing order of
  2026-08-17" now reads "the merge conductor and merge queue, which land every
  reviewed tier on the same double gate plus its iron-law scan; the tier is a
  recorded risk class, never a merge gate (the operator, 2026-10-05)". The iron-law
  scan stays in the sentence because `bin/merge-conductor.sh` still runs it.
  `rules/CLAUDE.md` was re-rendered with `bin/render-rules.sh --write`. No
  other topic file mentioned tier merging.
- Prompts. `prompts/TEMPLATE-GH.md`, `cromford`, `project-7`,
  `harness-console` and `project-5` said "the operator merges tier-2; tier-1
  auto-merge applies per pipeline defaults". They now say "The factory merges
  every tier on lead review + gates; risk tiers are reported, not gated."
  `project-1`, `project-3`, `project-2`, `remediator` and `plan-contract`
  were left alone: none of them says a person merges (their tier-2 lines are
  the merge sweep, an alert tier, or the recorded demotion).
- `skills/harness/SKILL.md`. "tier-2 waits for the operator" is gone; the line says
  every tier merges on lead review + gates.
- `docs/PRODUCT-ROADMAP.md` does not exist in this repo, so there was nothing
  to edit there. "human seat" appeared nowhere in the tree either; the lint
  bans it going forward.

The one switch that still holds a tier is `tier_gate_mode.<project>=human`
(BH-4579). Its default is `off`.

## The lint: `bin/lint-tier-wording.sh`

It judges the lines a diff ADDS against a base ref and fails (rc 1, one
`<path>:<line>: tier-wording: <text>` line each) when one says a person merges
or holds tier-2 work. It runs as the `tier-wording` row of
`catalog/rules-pack.tsv`, so `bin/fast-lints.sh` runs it on every ordinary PR.

- Scan set: `rules/topics/*.md`, `rules/CLAUDE.md`, top-level `prompts/*.md`.
- Patterns, case-insensitive: `tier[- ]?2 (waits|needs|is for) (for
  )?(operator|a person|a human)`, `human seat`, `awaiting operator`, `operator merges
  tier[- ]?2`.
- Blind spots: a phrase wrapped across two lines, and anything outside the
  scan set (skills, docs, bin). A line already on main is never a finding in
  delta mode; `--all` is the inventory.

Run it:

```bash
bin/lint-tier-wording.sh --base origin/main .   # this branch's added lines
bin/lint-tier-wording.sh --all .                # the whole scan set
bin/rules-pack.sh --only tier-wording           # through the rules pack
```

Tests: `tests/tier-wording-lint.bh-4582-test.sh`.
