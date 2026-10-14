# Archie inward ideas prompt (BH-4768, slice 5 of #4760)

Doc: OPERATOR-SETUP

## What changed

- New prompt `catalog/prompts/archie-ideas.md`. Its input is one JSON object:
  `{now, ledgers: {build_outcomes, fix_rounds, parks_by_reason, alert_families, cost_by_lane, rework}, open_ai_build_issues: [{number, title}], recent_ideas: [{slug, title, created_at}]}`.
  Ideas come only from the factory's own ledgers. Outside-world ideas stay
  with `bin/archie-research.sh`.
- The answer is at most one idea, in five lines: `IDEA:`, `EVIDENCE:`,
  `EXPECTED: <metric> from <n> to <n>`, `COST: <n> AI coding sessions` and
  `TICKET:`. Or it is the one line `NONE: <why>`.
- An idea with no number from the input behind it is `NONE: no number`. An
  idea with the same cause as an open ai-build issue or a recent idea is
  `NONE: duplicate of #<n>` or `NONE: duplicate of <slug>`.
- The model never writes a ledger row and never says it filed anything. The
  caller writes the Ideas ledger row with `prow_put`, the way the `propose`
  step of `bin/archie-research.sh` does.
- New replay skill `catalog/prompts/replays/archie-ideas` with 2 recorded
  cases: 01 an idea with evidence (`propose`), 02 ledgers with no number
  (`none`). Run: `bin/archie-skill-replay.sh --root catalog/prompts/replays`.

## Not done here

No script on main reads `catalog/prompts/archie-ideas.md`. The reader is the
report run of #4588. This change adds no lane, cron entry, setting or schema.
