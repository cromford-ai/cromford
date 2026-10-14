# 2026-10-13 BH-6372.3: the lead review caps INCONCLUSIVE evidence on perf PRs at BLOCK

Doc: LEAD-REVIEW

## What changed

`bin/lead-review.sh` `review_one` calls `loc_cap` (`bin/lib/lead-outcome-cap.sh`)
once, after the agent gave a readable verdict and before the report is written.
When the cap fires:

- the recorded verdict is BLOCK (the report's `- verdict:` line, the result
  post, the job artifact);
- the report header carries `- outcome cap: <reason>`, for example
  `18 INCONCLUSIVE claim rows (claim 1, …) on perf parent:#5354
  (LEAD_REVIEW_INCONCLUSIVE_BLOCK=perf); agent verdict MERGE-WITH-NOTES`;
- each verdict-shaped line of the agent's text is kept as a `> ` blockquote,
  and the report ends with one `VERDICT: BLOCK` line.

The cap fires when all of these hold:

1. The agent verdict is MERGE or MERGE-WITH-NOTES.
2. The PR body has at least one evidence row that matches
   `^\|[[:space:]]*claim[[:space:]]+[^|:]+:[^|]*\|[[:space:]]*INCONCLUSIVE([[:space:]]|$)`.
   That is the `| claim N: … | INCONCLUSIVE — … |` row that
   `bin/evidence-summary.sh` writes. The settled-tier row, the
   `EVIDENCE VERDICTS:` line, `REBASE_VERIFY_INCONCLUSIVE`, prose, a
   blockquoted row and a CONFIRMED row whose note says "inconclusive" do not
   match.
3. The knob `LEAD_REVIEW_INCONCLUSIVE_BLOCK` (lane `lead-review`, fragment
   `catalog/lanes.d/lead-review.knobs.d/`) allows it:
   - `perf` (default): only when `pt_classify` (`bin/lib/perf-ticket.sh`) says
     the ticket the PR body names (`Closes #n`, else `Refs #n`), or its parent,
     is a perf/cost ticket. A class that cannot be read (no ticket number, a
     failed REST read) is no cap and one log line `perf class unknown`.
   - `all`: every PR.
   - `off`: never.
   - Any other value is read as `perf`, with one log line.

`prompts/lead-review-checklist.md` is version 7. Item 14 asks the reviewer to
compare a perf/cost PR's outcome replay with the `Target metric:` target and
to name each fallback or escalation hit rate as k of N.

## Why the agent's verdict line is blockquoted

`bin/lib/verdict-parse.sh` reads two anchored verdict lines in the final block
that disagree as no verdict at all. A report that only appended
`VERDICT: BLOCK` after the agent's `VERDICT: MERGE-WITH-NOTES` read as
`unknown`, and the replay path then failed the job as `empty`. A `>` line is not
a verdict to the parser, so the trailing BLOCK is the only one, and the agent's
words stay readable.

## What reads it

`lr_verdict` on a replay (artifact or disk report) reads BLOCK from a capped
report. `finish_done` and the replay paths are unchanged. The cap adds no
agent call: it runs after the paid-once call. Its only new external read is
`pt_classify_issue` (one issue read, at most one parent hop), and only when
the body has INCONCLUSIVE rows under the `perf` knob.

Test: `tests/lead-review-inconclusive-block.bh-6381-test.sh`.
