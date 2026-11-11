# BH-8739: the fewest tickets, one per area or flow

Ticket: BH-8739 (the operator, 2026-10-28). Doc: BUILD-CONCURRENCY, rules/topics/12-qa-findings.md

## What changed

- Rules: topic 12 is now "Findings and splits: the fewest tickets, one per area
  or flow". A screen is never the unit. Triage keeps one ticket with a
  checklist and asks only when two asks conflict (topic 02). A review files at
  most one follow-up per area, never per screen (topic 13 and its iron-law
  fragment). The stage prompts say "per area or flow", and the plan stage asks
  for a `SLICE-REASON:` line on a SLICE.
- `bin/size-gate.sh` prints `SIZE_SLICES_EXPECTED: <n>` =
  max(1, ceil(lines / max-lines), ceil(files / max-files)) on the declared and
  the estimated path.
- `bin/lib/slice-gate.sh` (new) and `bin/run-decompose.sh`: the model proposes
  one slice per unit of work with `est_lines`. `sr_coalesce` merges every slice
  that has no reason to stand alone. A new child starts only for:
  - ordering: an `after` that names slice 2 or later;
  - file-overlap: a path of the open child, or of child 2 or later (a path
    only child 1 owns is no reason, because every later child waits on child 1);
  - context-ceiling: est_lines x `SLICE_TOKENS_PER_LINE` (400) past the
    build-execute `ceiling_tokens` (500000).
  Every child body opens with `Slice reason: <class>: <why>`. The model's copy
  stays in `children.proposed.json`.
- The confirm gate: when the larger of `SIZE_SLICES_EXPECTED` and the merged
  child count is above `SLICE_CONFIRM_OVER` (5), the decomposer posts the
  grouping on the parent (marker `<!-- decompose-proposal: <KEY> -->`), places
  a NEEDS-HUMAN hold on an issues parent, and exits 3. A person's
  `HUMAN-STEP-DONE:` (issues) or a reply by another author (board) after the
  proposal releases it. An unreadable thread holds; nothing files blind.
- One merged child: rc 4 `DECOMPOSE_NOT_NEEDED`, and the size gate in
  `bin/lib/rb/plan.sh` builds the parent whole.
- A legacy spec (no `est_lines`) files as before, and `SLICE_GATE=0` turns the
  whole gate off.
- QA findings (`bin/lib/group-findings.sh`): `gf_run` groups by area. The area
  is the first route segment, or the board's row
  `lib.group-findings.<board>.group_findings_areas` (JSON, route prefix to area
  name). The follow-up floor still matches a core-flow token against each
  finding's screen, and it no longer drops the last token of
  `review.core_flows` (a read loop with no final newline did).

## Knobs

`lib.slice-gate.<project>.slice_gate | slice_tokens_per_line |
slice_confirm_over | slice_ceiling_tokens`;
`lib.group-findings.<board>.group_findings_areas`.
