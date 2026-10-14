# DEAD column holds back build rows whose GitHub issue is closed

Doc: SCHEDULER, DB-COORDINATION-SPEC

## What changed

- New hub lane `issue-state-ledger` (`bin/issue-state-ledger.sh`,
  `cron/lanes/710-issue-state-ledger.cron`, `*/15`, lease-gated, `flock -n`
  dedupe). For every fleet.conf project whose `board_prefix` is `-` and whose
  repo is real (project-5, cromford, project-6, project-7,
  harness-console) it pages `repos/<repo>/issues?state=all&since=<watermark>`
  through `gh_rest` and writes one harness-jobs ledger row per issue:
  `kind=issue_state`, `key=<project>#<n>`, `status=closed|open`. Pull requests
  in that list are skipped.
- The per-project watermark is its own ledger row, `kind=issue_state_wm`,
  `key=<project>`, `status=<ISO updated_at>`. It moves only past items that
  were written (or skipped as PRs), and is written once when the project
  stops. A GitHub failure (rc 75 included), a failed PUT or a non-list page
  stops the project there; a watermark read outage skips it. No watermark
  means a backfill of `ISSUE_STATE_BACKFILL_DAYS` (14).
- Bounded per tick by `ISSUE_STATE_MAX_PUTS` (300) and `ISSUE_STATE_MAX_PAGES`
  (10 per project). Hitting either logs `DEFERRED <project> at <wm>` and the
  next tick resumes. Summary line per tick in `logs/issue-state-ledger.log`.
- `console-ui/functions/api/dash/kanban/pipeline.js` reads
  `GET harness-jobs/api/ledger?kind=issue_state&limit=1000` (Bearer
  `HARNESS_SECRET`, cached 60 s per isolate) after the console worker has
  answered 200, and after `archiveDead`. In the default view it drops DEAD
  **build** cards (not dead-letter commands) whose `<project>#<n>` is closed,
  where `n` is the trailing number of a `<PREFIX>-<n>` ticket key, and reports
  `dead_closed`. `?include=archived` returns them flagged `closed_issue`.
  Every response carries `dead_closed_known`; a missing secret, a non-200, a
  malformed body or a thrown fetch sets it false and hides nothing.
  `dead_closed_complete` is false when the ledger page came back full, and
  the DEAD note's tooltip then says some closed-issue rows may still show.
- The Kanban DEAD note shows `· N closed-issue` (with `(fleet)` under a project
  filter) and the SHOW ALL toggle even when nothing is age-archived. Audit
  view cards and list rows carry an `ISSUE CLOSED` tag.

## Why

project-5's pipeline showed `dead_failed=29` with every underlying issue
closed. The worker that assigns DEAD is not in this repo, so the fix is a
read-time join in the one layer we control, fed by a ledger the hub keeps.

## Not covered

Board-API projects (project-1, project-2, project-3, project-4, project-8,
project-9): their "closed" is a board status, not an issue state. The Pages
project needs `HARNESS_SECRET` (already required by `/api/coord/*`); without
it the join stays off and the column is the worker's own count.
