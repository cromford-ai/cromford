# The disprove pass on a lead review BLOCK (BH-9047, C0)

Doc: OPERATING, MERGE-CONDUCTOR

Slice C0 of #9047. C1 (the conductor re-review) and C2 (the 7-day report line
and the stop rule) are later slices.

## What changed

After the lead model's verdict is BLOCK, and after the re-review downgrade,
break-it and the review level cap, `bin/lead-review.sh` calls `dp_review`
(`bin/lib/review-disprove.sh`). For each model BLOCK finding with a
`<path>:<line>` it makes ONE no-tools call on route `review-disprove`. The
prompt is `prompts/lead-review.d/disprove.md`, the finding line, the diff hunk
of that file and the file at the head around the line.

- The answer's last non-blank line decides. `DISPROVED <reason> <path>:<line>`
  counts only when the path is a file of the head and the line is a line of it.
  Anything else, a failed call or an empty answer is CONFIRMED (fail closed).
- Not called: `needs-human`, `split-required`, `red-build` (any case), a
  `break-it:` line, and a finding with no location (`unchecked:no-loc`,
  counted confirmed). A location path that starts with `-` or `/` or holds
  `..` is no location, and a DISPROVED answer that cites one is CONFIRMED
  (r2). A rules-pack, console-qa or split-required BLOCK report never reaches
  the pass.
- Protected (never auto-dropped), r2 rule: every finding is protected unless
  its class, trimmed and lower-cased, is exactly one of `wrong-data`,
  `core-flow-broken`, `user-flows`, `hardcoded-knob`, `scalable-tests`,
  `weakened-test` or `model-id` (`_dp_droppable`). So `secret`, `tenant-leak`,
  `auth-bypass`, `money`, `data-loss`, `destructive-migration`, an untagged
  `[BLOCK]`, `Secret`, `auth bypass`, `secret, money` and any unknown class
  stay BLOCK.
- `shadow` (the seed): the review out is not changed. `enforce`: a DISPROVED
  finding becomes `- [NOTE] disproved: (<class>) ... | disprove: <reason>`; a
  DISPROVED protected finding keeps its BLOCK and gains
  `| disprove-said: DISPROVED ...`. With no `- [BLOCK` line left, the verdict
  is MERGE-WITH-NOTES. A rewrite whose verdict no longer reads is restored.
- The report gets a header line `- disprove (BH-9047): ...` and one indented
  line per finding, above `- pr body:`.
- One row per pass in the new D1 table `review_disprove_runs`, through
  `POST /api/review-disprove`. A failed post is one log line; the review stands.

## Knobs (settings rows)

`review.disprove.<project>.enabled` (seed 1 for cromford, fallback 0),
`review.disprove.mode` (shadow), `max_findings` (5), `usd_cap_day` (2),
`call_budget_usd` (0.50), `max_context_bytes` (24000), `min_left_s` (120),
`list_limit` (100) and `list_max` (500) for the GET, and
`retention.review_disprove_runs.days` (90).

The day cap reads the stage `disprove` spend (`llm_gate_spend_today
disprove`) plus what this pass already spent. It is separate from
`lead_review.daily_spend_usd`, which counts stage lead-review only. An
unreadable spend stops the pass (the rest are `unchecked:spend-unknown`).

## Retention

Rule `review_disprove_runs.age` deletes rows older than
`retention.review_disprove_runs.days`, under the retention lane's dry run.
The rows are shadow measurement, not money or history.

## Gate host notes (r6)

r4 and r5 opened no PR. The pre-PR selection gate stopped each one on suites
that are red only on the test host. r5 added a shallow-clone suite and an S2
guard in `tests/lead-review-libs.bh-7455-test.sh`. Its own suite was red by
design on the gate's snapshot tree. r6 removes both and adds one host note
fragment, `catalog/selection-gate-host-notes.d/bh-9047.tsv` (the BH-8725
seam), with two rows:

- `tests/lead-review-libs.bh-7455-test.sh`, class `shallow-context`, ERE
  `^FAIL: S2: `. A `git clone --depth 30` of main eb5b44789 gives
  `130 passed, 4 failed`, all four `FAIL: S2:`. Full history gives 135/0.
- `tests/context-kill-lanes.bh-2309-test.sh`, class `host-timing`, ERE
  `^FAIL: C: `. Main eb5b44789 gave `51 pass, 6 fail` once under load and
  57/0 in 9 later runs.

A host note applies only when every FAIL line of the suite's section matches
the ERE and the suite's own failed count agrees. It changes only the gate's
gate.txt. CI and the merge-queue batch still run and gate both suites on full
history. The real outputs are the fixtures in
`tests/fixtures/selection-gate-host-notes.bh-9047/`, and
`tests/selection-gate-host-notes.bh-9047-test.sh` (N1-N4) pins the rows.
