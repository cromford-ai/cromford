# BH-9028: every client question carries a recommendation, reasons and a default

Doc: RUN-BUILD-GRAPH, OPERATING

## Why

the operator, 2026-11-03. A bare list of questions on a board makes the client do the
thinking. Each question the fleet writes to a client must give the answer we
recommend, 1 to 3 plain reasons and what happens with no reply, so the client
can answer with one word.

## What changed

1. Every `prompts/*.md` (44 files) ends with the same rule block, between
   `<!-- client-questions:begin (BH-9028) -->` and `<!-- client-questions:end -->`.
   The triage shard SOP and the planner both read these prompts, so a triage
   `needs_clarification` comment and a planner that stops use the four-part form.
2. A planner that stops writes its questions in one fenced `client-questions`
   block in plan.md: a JSON array of `{question, recommended, reasons[], default}`.
3. `bin/lib/client-questions.sh` (`cq_block`, `cq_check`, `cq_render`) checks and
   renders the block. `bin/client-questions.sh check|render <plan.md>` is the CLI
   the LLM board sweeps run. rc 0 ok, rc 3 no block, rc 5 refused, rc 2 usage.
4. `pb_notice` (`bin/lib/plan-blocked.sh`) posts the rendered questions when the
   plan has a block. A block with a question that has no recommended answer, no
   reason or no default returns the new rc 5: one `plan-blocked notice refused on
   ...` log line, no comment, no mark file, RESULT unmarked. A plan with no block
   keeps the excerpt comment as before.
5. `rules/topics/02-board-triage.md` has a one-line rule, rendered to `rules/CLAUDE.md`.

No knob: "1 to 3 reasons" is prompt guidance, and the code has no cap.

## Test

`tests/client-questions.bh-9028-test.sh`.
