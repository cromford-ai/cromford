# BH-7117: the triage pass takes hotfix tickets first

Doc: VERIFICATION-MAP

## What changed

- `rt_gate` (`bin/lib/rt/gate.sh`) now starts with `triage_hot_intake`
  (`bin/lib/triage-hotfix-lib.sh`). It reads the open `ai-build` + `hotfix`
  issues (the tick's memoised `triage_hot_load` read) and offers them to
  `bin/launch-fastpath.sh`, oldest first. It runs before
  `bin/orphan-reconcile.sh`, the cost gate, the throttle and every SKIP exit.
  It makes no model call.
- One project-log line per pass with an open hotfix:
  `HOTFIX-INTAKE offered #<n>[,#<n>]; declined <keys|none|rc N>`. A live builds
  pause withholds the offer and logs `HOTFIX-INTAKE withheld #<n>: builds pause`.
  No hotfix open: no call and no line.
- `bin/launch-fastpath.sh` condition 11 (`## Scope` / `## Acceptance tests`
  headings) does not apply to an issue with the hotfix label
  (`hotfix_labels_json_has`: exact name after trim and lowercase, lane on).
  Every other condition (HOLD, blockers, open PR, ledger, lock, prior build,
  pause, dispatch mode) still decides.
- A full-sweep tick (`SCOPE_N=full`) with an open hotfix leads its prompt with
  `HOTFIX FIRST: open hotfix issues #<n> ...`. No hotfix: the prompt is
  byte-identical.
- Switch `hotfix-intake-off` (box-scoped, `lane_switch ... file`) turns the
  intake off. `hotfix-lane-off` / `HOTFIX_LANE=0` also turn it off.

## Why

#7066 (`ai-build` + `hotfix`, main red) was filed at 06:38Z and had no build
row at 07:36Z, also not after a run_triage. The wake's fastpath declined its
incident body (no spec headings), the reconciler launches in board order after
a grace, and a SKIP or held tick never reached a session.
