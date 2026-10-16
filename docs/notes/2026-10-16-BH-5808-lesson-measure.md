# Measure and retire lessons (BH-5808, wave 3 of #5794)

Doc: DB-COORDINATION-SPEC

## What changed

A new hub lane, `lesson-measure` (`bin/lesson-measure.sh`, daily at 07:23,
`cron/lanes/734-lesson-measure.cron`), after `lesson-propose` (06:41). It
keeps one durable row per merged lesson in the new D1 table `lessons`
(routes in `worker/jobs/src/routes/lessons.js`), judges each lesson once a
week, escalates the lessons that do not work, removes the plan lessons that
a later check supersedes, and sends a weekly digest to the operator. The
console shows the same digest on `/lead-reviews`, section LESSONS.

## Why

Wave 2 (`bin/lesson-propose.sh`, BH-5807) keeps ONE ledger row per category
(`ledgers kind=lesson_proposal key=<category>`). The next proposal for the
category overwrites it, so no record of a merged lesson stayed, and nothing
measured whether a lesson cut its BLOCKs.

## One tick

1. Gate: `lane_gate_or_exit`, `lane_env_apply`, `LESSON_MEASURE_ENABLED=0`
   stops before any request, `flock -n locks/lesson-measure.lock`.
2. Sweep. `GET /api/ledger?kind=lesson_proposal&limit=1000`. A `merged` row
   is recorded with `merged_at` = its detail `at`. An `open` row is read live:
   a merged PR, or an issue closed as completed, is recorded with the live
   time. `POST /api/lessons` is idempotent on `(repo, kind, number)`. If the
   ledger cannot be read, the lane writes one log line and stops. The lane
   never writes `lesson_proposal` rows.
3. `GET /api/lessons/pending`. Each escalation issue that has no `lessons`
   row of its own (`escalated_open`) is read live the same way. A closed
   completed escalation becomes a lesson with the escalation stage and
   `source=escalation`.
4. Weekly, once per ISO week. `job_ledger_claim lesson_measure <YYYY-Www>
   running 3600 done`. `POST /api/lessons/measure`, `POST
   /api/lessons/retention`, `GET /api/lessons/digest`, then
   `bin/archie-tg-send.sh lesson-digest:<YYYY-Www> <text>`. rc 0: the week row
   is `done`. rc 2 (no token or target): `done`, `digest.sent=false`. Any other
   rc, or a truncated measure: `failed`, and the next tick claims the week
   again. The `archie_tg` ledger of archie-tg-send stops a double send.
5. `GET /api/lessons/pending` again, then escalate, read the open removal
   PRs (`removing`) and retire (below). Escalate and retire share `LESSON_MEASURE_MAX_PER_TICK` GitHub writes.
6. One summary line in `logs/lesson-measure.log` for a tick that did work:
   `recorded= escalated= removal_prs= retired= reopened= held= judged= working= not_working= digest=`.
   `removal_prs` counts removal PRs opened, `retired` counts removal PRs read
   merged, `reopened` counts removal PRs read closed without a merge.

## Decision rules

- Window. W = `lessons.window_days` (14). Before = [merged_at - W,
  merged_at). After = [merged_at, merged_at + d) for the first whole day d >= W
  at which the after-window holds `lessons.min_reviewed` (30) reviewed PRs. It
  grows day by day to `lessons.max_window_days` (42). Past that, the lesson is
  `inconclusive`. A lesson is never judged on a partial window.
- A reviewed PR is a distinct `(repo, pr)` with a `verdicts` row in the window
  (all sources). A BLOCK is a distinct `block_findings.verdict_id` of the
  category. rate = blocks x 100 / reviewed.
- Working iff before_blocks > 0 and after_rate <= before_rate x (100 -
  `lessons.min_cut_pct`) / 100, in integers. Exactly a 30% cut is working.
  No baseline (0 BLOCKs or 0 reviewed PRs before) is `inconclusive`.
- A window read over 50 000 rows answers `truncated` and writes nothing.
- Escalate. Stage order is the settings row `lessons.stage_order`
  (`plan-lesson,builder-rule,check,harness-bug`). A not-working row gets ONE
  `ai-build` issue titled `Lesson escalation: <category> needs a <stage>
  [lesson:<category>]`. The title tag is the one wave 2's `lp_marker_hit`
  reads, so wave 2 does not propose for the category while the issue is open.
  `escalation_stage` is marked before the POST. Only a 201 with a number marks
  `escalation_number`. The body marker `<!-- lesson-measure: escalate
  lesson=<id> ... -->` heals a lost mark. A not-working `harness-bug` has no
  stronger stage: one log line, no issue.
- Retire. A `plan-lesson` row is superseded when the same category has a LATER
  `check` or `harness-bug` row. One REST PR (`harness/lesson-retire-<category>-<id>-<main sha8>`,
  title `Lesson retired: <category> superseded by a <stage> [lesson-retire:<category>]`)
  removes only the §10 bullets of `prompts/plan-contract.md` that end with
  `(lesson-propose: <category>)`, the suffix wave 2 writes. A hand-written
  bullet, another category's bullet, the `- docs/OPERATING` bullet and every
  line outside §10 stay. No such bullet: the row is `removed`,
  `removal_note=absent`, no PR. The lane holds (no PR) while an open PR is a
  wave 2 lesson PR on plan-contract or another removal PR. A 201 with an
  https `html_url` records the PR as `removal_number`. The row is NOT
  `superseded` yet: its status stays, and `GET /api/lessons/pending` lists
  it in `removing`. Each tick reads that PR live. Merged: the row is marked
  `superseded`. Closed without a merge: `POST /api/lessons/mark
  {clear_removal:true}` clears the PR, the row is in `retire` again, and the
  next tick opens a new PR on a branch named for the current main sha. Open:
  nothing changes. The digest counts `superseded` and `removed` as retired,
  and a row with an open removal PR as `removing`.

## Digest

`GET /api/lessons/digest?days=` (default `lessons.digest_days`, 7): the
overall BLOCK rate (distinct BLOCK heads / distinct reviewed PRs in
`verdicts`), the per-category BLOCK counts and rates, the lesson counts by
status and the lessons added in the window, the newest `lessons.list_limit`
(100) rows, and the top 5 uncovered causes (most BLOCKs, not `other`, no
lesson in `measuring` or `working`). The lane renders it as plain text, at
most 3500 characters. The console section reads the same JSON.

## Settings rows (seeded by the schema fragment)

`lessons.window_days` 14, `lessons.min_reviewed` 30, `lessons.min_cut_pct`
30, `lessons.max_window_days` 42, `lessons.digest_days` 7,
`lessons.stage_order`, `lessons.retention_days` 730,
`lessons.list_limit` 100. The routes read them
through the per-isolate settings memo (`settingsRows`). A junk value uses the
code fallback.

## Indexes

`idx_lessons_status (status, merged_at)` (measure, escalate),
`idx_lessons_cat (category, status, merged_at, removal_number)` (digest GROUP BY, covering),
`idx_lessons_type (change_type, category, merged_at)` (retire),
`idx_lessons_merged (merged_at)` (digest list, retention),
`idx_lessons_esc (escalation_number)` (record, escalated_open),
`idx_verdicts_created (created_at)` (reviewed-PR counts, new on `verdicts`,
additive). The `block_findings` reads use `idx_block_findings_cat` and
`idx_block_findings_at` (BH-5806). `worker/jobs/test/lessons.bh-5808.test.js`
X1-X4 run EXPLAIN QUERY PLAN on 20 000 findings, 20 000 verdicts and 500
lessons. The plan listed `idx_lessons_cat` as `(category, merged_at)` and had
no `idx_lessons_type`; the build changed both so the digest and retire reads
have a matching index.

## Retention

`lessons` is a history table (about 1 to 5 rows a week, about 260 a year).
Its rows are kept: BH-6730 says history rows are archived, never deleted.
The weekly tick runs `POST /api/lessons/retention`, which only COUNTS the
judged rows older than `lessons.retention_days` (working, inconclusive,
superseded, removed, and not-working rows that were escalated). The route
has no delete path. The count goes into the week's `lesson_measure` ledger
row (`retention:{eligible, cutoff}`), one audit record per run.
`lesson_measure` rows are 52 a year. A delete is also unsafe here: the
category's `lesson_proposal` ledger row outlives the lesson, so the daily
sweep would record a deleted lesson again as a new `measuring` row with an
old `merged_at`. That row would make every weekly measure read a span over
the row cap and answer `truncated`.

## Off switches and knobs

`LESSON_MEASURE_ENABLED=0`, `flags/lane-off-lesson-measure`, or
`bin/harness-ctl.sh off lesson-measure`. `LESSON_MEASURE_MAX_PER_TICK`
(default 3, 1..20): GitHub writes one tick may make. Registry:
`catalog/lanes.d/lesson-measure.json`. No model call.

## Follow-ups

- `bin/lesson-propose.sh`: after an escalation closes, draft only at the
  escalated stage or stronger (a `min_stage` per category on the triggers
  route), so a category does not fall back to plan text.
- A `block_findings` retention rule (owed by BH-5806 / BH-5807).
