# An intent review for a medium-risk head (BH-6967)

Doc: OPERATING

Part of #6544, wave 1 of 4.

## What changed

A medium-risk head can get an INTENT review in place of the full lead review.
The reviewer checks four things and does not read every line: the acceptance
tests are in the diff and ran red then green, the diff stays inside the planned
files, the iron laws hold, and the PR body names its lane. The prompt section is
`prompts/lead-review.d/intent.md`. The full prompt (`prompts/lead-review.md`) is
not edited.

The switch is off by default. With it off, every head gets the review it got
before this change.

## The knob

`risk_tier.medium_mode` (settings row): `full` or `intent`. The seed is `full`.
`bin/lead-review-enqueue.sh` reads it once a tick, trimmed and in any case. No
row, an unreadable row or any other value is `full`. A bad value writes one log
line a tick.

`risk_tier.*` is a protected prefix. The worker refuses `full -> intent` without
the human verdict token, because it lowers review depth. Turn it on with:

```bash
bin/protected-setting.sh risk_tier.medium_mode intent "BH-6967: intent review for medium heads"
```

Turn it off with the same command and the value `full`.

The seed row is unsigned, like the `risk_tier.mode` seed. While
`human_verdict_sig_mode=enforce`, the worker answers 409 on an unsigned row.
The enqueue and the reviewer then log `unreadable` and use `full`. That is safe,
but sign the row with `bin/protected-setting.sh` even to keep it at `full`.

Before an operator sets `intent`, run the M5 case live once:
`REVIEW_INTENT_EVAL_MODEL=<the review-intent rung 0 model> HARNESS_TEST_SANDBOX=1
bash tests/review-tier-medium.bh-6967-test.sh`. The stubbed M5 proves only the
prompt and the report parser, not that the model blocks an unplanned file.

## The tokens

The enqueue classifies a head with the risk tier (BH-5022). It ends the request's
`scope_notes` with one group:

| Head | Tokens |
|---|---|
| low (requested, or a withheld sign-off) | `review-tier:low review-mode:full` |
| medium, row `intent`, not a delta request | `review-tier:medium review-mode:intent` |
| medium, any other case | `review-tier:medium review-mode:full` |
| high (protected paths included) | `review-tier:high review-mode:full` |
| no tier (risk mode off, a Lead-Lane commit, an unreadable compare, a lead-authored PR that is not a rules-text low) | none |

The group counts only as the LAST part of the notes. The parts before it carry
text that a PR author or a commenter controls: diff paths and commit subjects in
a self-check note, a `HUMAN-STEP-DONE:` body, the `lead-prev` file lists. So
`request()` rewrites `review-tier:` and `review-mode:` in those parts to
`review-tier=` and `review-mode=`. `bin/lead-verdict.sh request --notes` and the
in-build ask (`bin/inbuild-lead-review.sh`, its risk reason) do the same, so
only the enqueue writes the tokens. The reviewer and land match the group only
as the end of the notes (`(^|; )review-tier:<t> review-mode:<m>$`).

The first ask stores the group in
`state/lead-review-enqueue/review-tier-<slug>-<n>-<sha12>` (pruned after 7 days).
A re-confirm sends only what that file holds. The worker refuses other notes on
the same head with 409, so the notes of a head never change.
The summary line counts `review_intent=<n>`.

## The route

`review-intent` (`model_routes`). The seed fragment
`worker/jobs/schema.d/202610152133-bh-6967-review-intent.sql` copies rung 0 from
`triage.light` rung 0 (Sonnet class) and rung 1 from `lead.review` rung 0
(today's lead model). It writes both rungs, or none when a source row is absent.

`bin/lead-review.sh` reviews a request in intent mode only when all of these
are true:

1. The scope notes END with `; review-tier:medium review-mode:intent`.
2. They carry no `lead-delta:` token.
3. The row `risk_tier.medium_mode` reads `intent` at review time. The reviewer
   reads it again, so a forged note cannot go around the protected row, and a
   request queued before the row went back to `full` gets the full review.
4. `prompts/lead-review.d/intent.md` is readable.
5. `model_for review-intent` answers.

Then the prompt is `prompts/lead-review.md` + `intent.md` with no checklist and
no builder review section. The report header says
`- review mode: intent (risk tier medium, route review-intent)` and
`- checklist: none (intent review)`. The cost row note is `lead-mode=intent`.
If the row is not `intent`, or the route or the prompt file is missing, the review is the full review on
`lead.review`, with a `full review (<why>)` log line.

## The verdict row

`verdicts` has two new nullable columns, `review_tier` (`low|medium|high`) and
`review_mode` (`full|intent|risk-tier`). The worker adds them on the first POST
(`ADDED_COLUMNS.verdicts`) and refuses any other value with 400.
`bin/lead-verdict.sh post` takes `--review-tier` and `--review-mode` and refuses
a bad value with exit 2 before any request.

| Writer | Tier | Mode |
|---|---|---|
| `bin/lead-review-land.sh` (a lead review result) | from the request's tokens | from the request's tokens |
| the enqueue's risk-tier sign-off | `low` | `risk-tier` |
| the enqueue's lead replay | none | the replayed row's mode, `full` when it has none |
| human, box, carried, in-build and worklist rows | none | none |

The worklist path (`LEAD_REVIEW_WORKLIST=1`) creates its own requests with no
tokens, so its reviews are full.

## Tests

`tests/review-tier-medium.bh-6967-test.sh` (the enqueue, the reviewer, land,
`lead-verdict.sh post` and the seed) and
`worker/jobs/test/verdicts-review-tier.bh-6967.test.js` (the worker).
