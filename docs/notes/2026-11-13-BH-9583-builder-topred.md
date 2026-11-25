# 2026-11-13 — BH-9583: the builder gate runs the top GATE_RED suites

Doc: GATES-VS-REPORTS

## What changed

- `bin/test-impact-gate.sh` has a new tier `topred`, rank 1, right after
  `self`. The ranks below it move down by one (reads and regression 2, always
  3, named 4, source 5, learned 6, closure 7, full 8). The fresh-main segment A
  is now ranks 0-2, so it holds the same suites as before, plus topred.
- The gate reads the top N suites from `GET /api/gate-red/top`
  (`worker/jobs/src/routes/gate-red-rank.js`) through the new jobs-client
  verb `gate-red-top` (`bin/jobs-client.d/bh-9583-gate-red-top.sh`). Inside
  the tier the ranking order wins over the duration hint.
- Three settings rows: `builder_gate.topred.enabled` (1),
  `builder_gate.topred_n` (5), `builder_gate.topred_window_days` (14), seeded
  by `worker/jobs/schema.d/202611130809-bh-9583-builder-topred-knobs.sql`.
- The route reads the `jobs` rows `_job_finish` already writes for a
  GATE_RED build. No new table, index or cache:
  `idx_jobs_project_status_created` serves the read.

## Why

A suite that turned many builds GATE_RED, but that a diff's map does not
reach, ran only in the selection gate after the push attempt. Then the build
was rebuilt. Now the builder gate runs it before the push, inside the same cap
and budget.

## What to look for

One `topred:` line per gate run: the suites it added, or
`topred: off (<why>)`. Every off path runs the gate as it ran before.
`docs/gates/builder-topred.md` lists the reasons, the knobs and the SQL.
