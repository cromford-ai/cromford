# Wake and scope on the tracker contract, slice C1 (BH-8449)

Doc: tracker-adapter

## What changed

Slice C1 of #7920. Four changes.

- `tracker_read` prints an 11th key, `state` (`open|closed`), on all four
  adapters, by the rule the list rows already used. The Linear `TrkIssue`
  query asks `state { name type }`.
- `bin/wake-loop.sh` `issue_closures` reads a Jira or Linear wake key
  (`CRO-12`) through `tracker_read` and prints it when its `state` is
  `closed`. Before, it answered rc 1 for every tracker but GitHub Issues.
  `released_by` still keeps digits only, so nothing is released through a
  Linear key until C3.
- `bin/lib/rt/scope.sh`: for a Jira or Linear project, `board_section` uses
  the gate diff as the whole scope, and `inapp_released_lines` returns at
  once. The GitHub and in-app readers no longer run for those projects.
- `bin/triage-gate.sh`: a Jira or Linear fingerprint that moved only by our
  own comments is absorbed (`SKIP self-writes-only`). It needs the settings
  row `tracker_<kind>.<project>.self_actors`; with no row the gate runs, as
  before. `bin/gate-selfwrite.py` gains `GATE_SELFWRITE_MODE=ids` for it.

## Why

A Linear or Jira wake key was kept, but its closed state could not be read,
the scope ran GitHub readers against a project that has no GitHub tickets,
and every one of our own comments bought a triage session.

## What it touches

- New settings row `tracker_<jira|linear>.<project>.self_actors`
  (comma-separated author names; no seed row; no row = no absorption).
- `--signal` hashes the whole `tracker_read` doc, so every Jira and Linear
  ticket's signal moves once after this merge.
