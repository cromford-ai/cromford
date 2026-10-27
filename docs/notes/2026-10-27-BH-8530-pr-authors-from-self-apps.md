# The PR author set derives from HARNESS_SELF_APPS; an UNKNOWN-AUTHOR streak warns once (BH-8530)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

The board App, `cromford-board`, opens PRs on some projects (project-6-desktop #6). The default PR
author set in `bin/lib/gh-pr-list.sh` was a literal that did not name that App. The REST filter dropped
the PR, every harness lane read it as absent, and merge-conductor logged `prs=0` for project-6-desktop.
`HARNESS_SELF_APPS` (`catalog/lanes.d/_lib.harness-self.json`) already listed the App.

## What changed

- `HARNESS_PR_AUTHORS_DEFAULT` is now the operator login plus `app/<slug>` for each slug of
  `HARNESS_SELF_APPS` (lowercase; `app/` and `[bot]` are removed first). The lib reads that variable from
  the environment only. When the box does not export it, the code fallback `_HPL_SELF_APPS_FALLBACK` is
  the registry default. `tests/gh-pr-list-self-apps.bh-8530-test.sh` A3 keeps the two the same set.
- An explicit `HARNESS_PR_AUTHORS` still wins exactly. The verdict set (`HARNESS_VERDICT_AUTHORS`) does
  not change: the board App lists PRs but does not issue verdicts.
- `bin/merge-sweep.sh`'s inline fallback adds `app/cromford-board`.
- An open `ticket/*` PR that the author filter drops on more than `GH_PR_LIST_UNKNOWN_STREAK_DAYS`
  consecutive UTC days sends ONE warn `fleet_alert` (akey `prauthorunknown-streak:<repo>#<num>`) and one
  ALERTS.log line per streak. The daily UNKNOWN-AUTHOR line and daily alert do not change.
  The streak is one jobs ledger row per PR (kind `pr_author_unknown`, key `<repo>#<num>`, detail
  `<first> <last> <warned>`), not a file under `state/`, so all boxes share it.

## Operator

- To add a new App: put its slug in `HARNESS_SELF_APPS` in `env/global.env`. Both trust lists read it.
- Knob `GH_PR_LIST_UNKNOWN_STREAK_DAYS` (`lib.gh-pr-list`, `catalog/lanes.d/_lib.json`): int, default 2,
  0 = never warn.
- State: `$HARNESS/state/pr-author-unknown/<owner>_<repo>#<num>`, one line `<first> <last> <warned>`.
  Each call deletes a file whose `last` is before yesterday (a broken streak).
