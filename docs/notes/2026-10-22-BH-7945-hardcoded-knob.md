# A literal limit with no DB knob is [BLOCK hardcoded-knob] (BH-7945)

Doc: LEAD-REVIEW

## Why

The fleet rule says business values are DB-driven and a code constant is only a
documented fallback (`rules/topics/04-building-software.md`). The lead review
checklist item 4 made "a hardcoded threshold or rate" only a `[NOTE]`. So
builders shipped literals and the lead review passed them.

In one project, interview answers were cut at 1024 output tokens with no prod
row. The brain call (900), the promise draft (900), the proposal draft (1200)
and the builder draft (8000) had no DB key at all.

## What changed

- `prompts/lead-review-checklist.md` item 4: `[BLOCK hardcoded-knob]` for a new
  or changed literal limit, rate, threshold, price, timeout, cap or
  `max_tokens` with no DB row or knob read. The literal may stay only as the
  documented fallback of a knob that exists. `[BLOCK model-id]` and the
  `${KNOB:-literal}` `[NOTE]` stay. Checklist-Version is not bumped (open PR
  #7963 bumps line 1); the `## Changes` list has one unversioned line.
- `catalog/review-always-block.tsv`: a new row `hardcoded-knob`. Without it,
  `rl_cap` (`bin/lib/review-level.sh`) demotes a `[BLOCK hardcoded-knob]` line
  to `[NOTE demoted ...]` whenever the report carries any other class tag.
- The class is in the ALWAYS-BLOCK list of `rules/topics/13-review-levels.md`,
  `prompts/iron-laws.d/20261016-review-levels.md`, `prompts/lead-review.md`,
  `bin/lib/rb/review.sh` and `bin/review-prs.sh`.
- Builder side: D69 in `prompts/build-discipline.md` and one bullet in
  `rules/topics/04-building-software.md` (rendered to `rules/CLAUDE.md`): a new
  limit is a seed row in the settings or config table plus a code fallback with
  a comment that names the row, in the same PR. D69, not D68: open PR #7471
  adds D68.

## The class ERE

The ERE keeps an untagged finding standing only when it names the class, or a
literal limit word next to "no DB/settings row/knob":

- stands: `[BLOCK hardcoded-knob] ...`, `[BLOCK: hardcoded-knob] ...`,
  `[HIGH] max_tokens 900 is a literal with no settings row`,
  `[BLOCK] hardcoded timeout of 30000 ms, no knob read`.
- does not stand: `card padding is 14 px, hardcoded` (no limit word),
  `max_tokens read from settings row ... with 1024 fallback` (a knob read),
  `hardcoded-knobs heading` (plural), `hardcoded threshold in a test fixture`
  (no "no row/knob").

## Test

`tests/lead-checklist-hardcoded-knob.bh-7945-test.sh` replays two PRs from
`tests/fixtures/lead-checklist-hardcoded-knob.bh-7945/` through the real
`bin/lead-review.sh` tick: `max_tokens: 1024` gives a BLOCK report whose
`[BLOCK hardcoded-knob]` line survives `rl_cap`; the same value read through
`settingInt('interview.max_tokens', 1024)` is not BLOCK. The model is graded
only in opt-in live mode (`LEAD_CHECKLIST_EVAL_MODEL`).

Not in scope: a mechanical `no-hardcoded-limits` lint (a separate ticket).
