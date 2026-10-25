# BH-8338: the outcome cap writes a finding line, and it is a NOTE unless the ticket has `perf-gate`

Doc: LEAD-REVIEW

## Why

The lead review's outcome cap (`bin/lib/lead-outcome-cap.sh`, BH-6372.3) turned an
agent MERGE-WITH-NOTES into BLOCK when the PR body's Evidence table had an
INCONCLUSIVE claim row and `pt_classify` read the ticket as perf. A perf phrase was
enough. The capped report had no `- [BLOCK` line. `bin/lead-review-land.sh` then
withheld the review as an empty BLOCK and alerted (verdict #3921, PR #8278 at
7afeb74). The PR waited for a person with nothing to fix.

## What changed

- `loc_cap` prints a third line: ONE finding line. It names the claims and the fix
  (name the artifact line for each claim in the Evidence table).
- Under the default knob a perf match by phrase, perf/cost label, target line or
  parent hop gives MERGE-WITH-NOTES and a `- [NOTE] outcome cap:` line. Only the
  `perf-gate` label on the ticket the PR closes gives BLOCK, with a
  `- [BLOCK wrong-data] outcome cap:` line. There is no parent hop for the label.
- An agent MERGE that the cap notes becomes MERGE-WITH-NOTES.
- `bin/lead-review.sh` writes the finding line above the demoted agent text, and
  refuses a BLOCK report with no `- [BLOCK` line on the agent path: it logs one
  line and posts `outcome=failed detail=block-no-finding`. Gate BLOCKs and
  replays do not pass through this check.
- With no ticket text, the cap reads the issue once for the labels and the class
  (`_pt_classify_read` in `bin/lib/perf-ticket.sh`).

## Decision table (verdict MERGE or MERGE-WITH-NOTES, at least one INCONCLUSIVE row)

| knob | perf-gate label | loc_class | recorded verdict | finding line |
|---|---|---|---|---|
| perf | yes | any | BLOCK | `- [BLOCK wrong-data] outcome cap: …` |
| perf | no | perf | MERGE-WITH-NOTES | `- [NOTE] outcome cap: …` |
| perf | no | no | agent verdict | none |
| perf | no / read failed | unknown | agent verdict | none, one `perf class unknown` log line |
| all | any | not read | BLOCK | `- [BLOCK wrong-data] outcome cap: …` |
| off | any | not read | agent verdict | none |

## Knob

`LEAD_REVIEW_INCONCLUSIVE_BLOCK` (catalog/lanes.d/lead-review.knobs.d/), default
`perf`, unchanged. Tests: `tests/lead-review-inconclusive-note.bh-8338-test.sh`,
`tests/lead-review-inconclusive-block.bh-6381-test.sh`.
