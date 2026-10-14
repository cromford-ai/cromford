# The lead review reads an oversize diff in parts; split required replaces the blind BLOCK (BH-5803)

Doc: OPERATING, RUN-BUILD-GRAPH

## What changed

- `bin/lib/lead-diff-parts.sh` is a new lib of `bin/lead-review.sh`. When a
  full-review diff is over `LEAD_REVIEW_DIFF_MAX_BYTES` (settings row
  `lane.lead-review.lead_review_diff_max_bytes`, default 400000), `ldp_build`
  packs whole files in this order: the plan file(s) in the diff
  (`.harness/specs/*/plan.md`) and every changed file whose path the plan
  names, then the tests, then the rest. A file that does not fit is skipped and
  named. It is never cut in half.
- Generated files and fixtures (`linguist-generated`, binaries, lockfiles,
  `fixtures/`, `testdata/`, `__snapshots__/`, `generated/`, `*.min.js`,
  `*.map` and the like; `ldp_class`) are never read. They are listed by path
  and size.
- The prompt gets a `## Diff coverage` section before `## Diff`. It states the
  totals, the plan file, what was read per tier, and every file not read with
  its bytes. Lists stop at 200 rows with an exact `+N more`. 32768 bytes of
  the limit are kept for this section, so the prompt is not larger than before.
- The report header of such a review has
  `- diff read in parts: <read> of <total> files; not read: <paths>; digest: <n> files`.
- When a test file of the PR does not fit, the lane makes no model call. The
  report is a BLOCK with `- review mode: split required (...)`,
  `- reviewer model: none:split-required`, one finding
  `[BLOCK split-required] <n> of <m> test files do not fit ...; this is not a finding on the code.`,
  a `## Proposed split` (each test stays in the part of the file it names) and
  the coverage section. The wire verdict is BLOCK, because the worker accepts
  only MERGE, MERGE-WITH-NOTES and BLOCK.
- `prompts/lead-review.md`: "If you could not read the diff, the verdict is
  BLOCK" now applies only when the diff could not be read at all. A file listed
  as not read is outside the verdict: no BLOCK for that alone, a [NOTE] for each
  unread file that is not generated, and MERGE-WITH-NOTES at best.
- `bin/size-gate.sh` reads an optional `DIFF_KB:` in the plan's `## Size`. The
  limit is `LEAD_REVIEW_DIFF_MAX_BYTES / 1000` from the env (400 when unset or
  bad), with the same tolerance band as the other axes. Over the band is
  `SIZE_OVER: diff_kb=<n>><limit>` and exit 2, so the plan is decomposed. A
  plan without the key prints and decides exactly as before. The planning
  prompt in `bin/lib/rb/plan.sh` asks for the key.

## Unchanged

- A diff at or under the limit, and every delta review, build the prompt as
  before.
- No lib on the box, `ldp_build` rc 1 (git could not list or read the diff), or a
  delta review whose delta is over the limit: the same split-required BLOCK with
  no model call. Its finding names the reason. No reviewer reads a cut diff, so
  a cut diff can never get a bare MERGE (lead review BLOCK at b5426ef9d). Before
  this, these cases got the old `head -c` cut with no `## Diff coverage`.
- Coverage lists that outgrow `LDP_RESERVE` (many long paths) no longer make
  `ldp_build` fail: the last files read move to the not-read list until the parts
  file fits.
- Nothing merges unread (the operator's decision on #5803, 2026-10-12). A file that is
  not generated or a fixture and does not fit, test or not, makes the review
  split required with no model call. The finding lists the files, and the report
  carries a proposed split. Only generated files and fixtures (the digest) may be
  left unread, and they are listed by path and size.
- After a split-required BLOCK the existing blocked-resolver ladder runs. Its
  rebuild re-plans the ticket, and the new plan's `DIFF_KB` sends it to the
  decomposer.

## How to see it

On the hub, `grep -E 'read in parts|split required|parts not possible' /root/harness/logs/lead-review.log`,
then open `state/lead-reviews/lr-<pr>-<sha12>.md` for that key.
