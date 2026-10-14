# Classify every BLOCK (BH-5806, wave 1 of #5794)

Doc: DB-COORDINATION-SPEC

## What changed

A new hub lane, `lesson-classify` (`bin/lesson-classify.sh`, hourly at minute
23), reads each BLOCK verdict once and stores one row per finding with a
category. It is the first wave of the block-learning loop (#5794). Wave 2
(#5807) proposes fixes from these rows. Wave 3 (#5808) measures them.

The jobs DB has three new tables, in the fragment
`worker/jobs/schema.d/0016-bh-5806-block-findings.sql` (edit the fragment and
run `bin/schema-build.sh --write`; `worker/jobs/schema.sql` is the generated copy):

- `block_categories`: the taxonomy, as rows. 28 rows are seeded from the
  2026-10 analysis of 300 PRs (27 categories plus `other`), with their group,
  suggested stage and example PRs. The seed is INSERT OR IGNORE, so an
  operator's edit is kept.
- `block_classify_runs`: the dedup ledger, one row per verdict id. Status is
  `claimed`, `ok`, `empty` or `failed`.
- `block_findings`: one row per finding: verdict id, finding number, repo, PR,
  ticket, head, source, category, the model's own label when it named no known
  category, confidence, cause, files, the infra or false BLOCK flag, the text
  and the BLOCK's own time.

Two settings rows: `lesson_classify.max_attempts` (3) and
`lesson_classify.since_days` (14). One model route: `lesson.classify`, rank 0. The seed
copies the hub `review.trivial` rung 0 (the cheap Haiku tier), because no new
model id may be written under `worker/`. To move the lane to a newer Haiku, an
operator PUTs the route (`PUT /api/model-routes`); the model must be in
`model_prices` first.

## Dedup before spend

1. The lane asks `GET /api/block-classify/pending` for BLOCK verdicts in the
   window with no `ok` or `empty` run and attempts under the cap.
2. The lane resolves the model and reads the categories once. If either is
   missing, it claims nothing and calls nothing.
3. For each verdict, `POST /api/block-classify/claim` runs BEFORE the call. It
   is one conditional upsert that adds 1 to attempts. A run that is `ok` or
   `empty` is refused (409 terminal). A run at the cap is refused (409 at_cap).
4. One `bin/agent-call.sh` call, stage `lesson-classify`, role
   `lesson.classify`, fingerprint `lesson-classify:<verdict id>`.
5. `POST /api/block-classify/settle` records the outcome:
   - `ok`: the findings rows are written.
   - `empty`: a blank answer, an empty list, or no findings text. Terminal.
   - `failed`: a billed failure or an unparseable answer. It retries until the
     cap. A call that agent-call refused (rc 74-79, nothing billed) settles
     `failed` with `refund`, which gives the attempt back.

Each BLOCK verdict costs at most 3 paid calls, whatever the poll rate.

## Where the text comes from

- A lead BLOCK: the `lead-job:<job>` token in the verdict note names the job.
  The text is that job's `lead_review_report` artifact. Each `- [BLOCK]` item
  is one finding, with its indented continuation lines. `[NOTE]` items are
  not findings.
- A builder or human BLOCK: the verdict note, less its `key:value` tokens, is
  one finding.
- The lane reads the files of each finding off its text. The model does not
  name files.

## The console

`/lead-reviews` has a new section, BLOCKS BY CATEGORY: per week (Monday, UTC)
and category, the findings, verdicts and PRs. The FINDINGS button opens the
rows, and each row links the PR and the verdict.

## Routes

All behind the HARNESS_SECRET bearer. D1 has no RLS; the bearer is the admin
gate.

- `GET /api/block-categories[?all=1]`
- `GET /api/block-classify/pending?limit=`
- `POST /api/block-classify/claim`
- `POST /api/block-classify/settle`
- `GET /api/block-findings/weekly?weeks=`
- `GET /api/block-findings?category=&week=&verdict_id=&limit=`

## Not in this wave

- Proposals (#5807) and measurement (#5808).
- An enqueue from `bin/lead-review-land.sh`. The lane reads the verdicts table
  instead, so it changes no hot file. A BLOCK waits at most one hour.
- Classifying a lead report the worker cut at its 4000-unit artifact cap. The
  posted review is built from the same cut artifact, and the full report is
  only on the reviewing box. Such a verdict is settled failed with a refund
  and parked (`state/lesson-classify/parked-<id>`). The lane logs the request
  id, box and path. About 19% of lead BLOCK reports (31 of 163) are over the
  cap. #5915 stores the full report where the hub can read it, then
  re-classifies them.

## Where the ticket comes from

A lead report is headed `# Lead review lr-<pr>-<sha12> (<repo>#<pr> at <sha>)`
and names no ticket. The lane reads the PR once, just before an ok settle, and
takes its ticket branch (`ticket/bh-123` gives BH-123), or an `ABC-123` at the
start of its title.
