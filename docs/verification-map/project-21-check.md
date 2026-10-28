# project-21 dependency check of every build (BH-8079)

**What it is:** every build sends the lockfiles its worktree TRACKS
(package-lock.json, pnpm-lock.yaml, yarn.lock, requirements.txt, go.sum,
composer.lock, Cargo.lock, Gemfile.lock, at any depth) to project-21 in ONE request,
`POST ${PROJECT_21_BASE_URL-https://project-21.example}/v1/check`, after the push and before
the PR body renders. The result is the PR body section
`## Dependency advisories (project-21)`. It is a tripwire: no path stops a build.

## How to reach it

- The build lane: the block `# >>> project-21 check (BH-8079)` in
  `bin/lib/rb/pr.sh`, right after `# <<< pr push`. It calls
  `project-21_build_run` (`bin/lib/project-21.example`), which runs `bin/project-21-check.sh`
  once per head and sets `PROJECT_21_SECTION`; `PR_BODY_FOR` prints it.
- By hand: `bin/project-21-check.sh <worktree> [--out <file>] [--head <sha>]`.
- The review: the self-check rule `project-21-upgrade`
  (`catalog/pr-self-check.d/bh-8079-project-21-upgrade.tsv`), through
  `bin/pr-self-check.sh check ... --only '^project-21-upgrade$'`.
- The daily lane: `bin/project-21-daily.sh` at `41 6 * * *`
  (`cron/lanes/773-project-21-daily.cron`), every box and the hub.

## What to look at

| artifact | what it says |
|---|---|
| `$BUILD/project-21.json` | the result: `state` (affected, clean, partial, failed, nothing, off), `reason`, `head`, `files`, `local_skipped`, `checked`, `affected`, `skipped` |
| `$BUILD/project-21.txt` | the CLI's stdout: one `project-21: affected ...` line per advisory, `project-21: skipped ...`, `none known`, `check failed (<reason>)`, and `PROJECT_21_SUMMARY <json>` last |
| `$BUILD/pipeline.log` | `project-21 state=<s> checked=<n> affected=<n> skipped=<n>` |
| the PR body | `## Dependency advisories (project-21)`: the table (dependency, version, severity, fixed in, upgrade, advisory), or `None known`, `Check failed (...)`, `Nothing to check`, `Partial coverage` |
| the lead review request notes | `project-21-upgrade: <dep>@<version> has a fix in <x> that this PR does not apply: <upgrade> (<url>)` |
| `logs/project-21-daily.log` | `failed=<f> counted=<n> window=<h>h threshold=<p>%` per run |

`None known` prints only for a 2xx answer with a valid shape, `checked` > 0, no
affected item and no skip. A skip (for example `partial_coverage`) is listed and
the section says it is not a clean result.

## Knobs and switches

- `lib.project-21.project-21_enabled` (1): 0 = no call and no section.
- `lib.project-21.project-21_review_block` (0): 1 = the `project-21-upgrade` lines are a
  REFUSE, which holds the lead review.
- `lib.project-21.project-21_timeout_s` (30), `project-21_rows_max` (50),
  `project-21_field_max` (200), `project-21_note_max` (10).
- `lane.project-21-daily.project-21_daily_fail_pct` (50),
  `lane.project-21-daily.project-21_daily_window_h` (24);
  off: `flags/lane-off-project-21-daily`.
- `PROJECT_21_BASE_URL` (env, `env-templates/lanes/385-project-21.env.example`): unset =
  https://project-21.example, empty = not configured (every test sandbox).

## Tests

`tests/project-21-check.bh-8079-test.sh`, `tests/project-21-pr-section.bh-8079-test.sh`,
`tests/project-21-review-note.bh-8079-test.sh`, `tests/project-21-daily.bh-8079-test.sh`.
They use the fake API `tests/lib/fake-project-21-api.bh-8079.py` on 127.0.0.1.
