# Tracker contract: one verb set, two adapters, the adapter chosen by a settings row (BH-4075)

Doc: BOARD-API-CONTRACT, tracker-adapter, fc-board, fc-issues, settings-knobs

## What changed

- New `bin/lib/tracker.sh`: the verbs `list`, `read`, `comment`, `transition`,
  `label_add`, `label_remove`, `link_pr`, `close_out`, `waiting_on`, one rc
  table for every adapter (0 ok, 1 failed, 3 unsupported, 44 label not there,
  75 rate-limited), and `tracker_adapter <project>`.
- New adapters `bin/lib/tracker/github-issues.sh` and `bin/lib/tracker/board.sh`.
  `waiting_on` is `bin/triage-gate.sh --buildable` for both, not a copy of it.
- The tracker a project uses is the D1 settings row `tracker_adapter.<project>`
  (`github-issues` | `board`). No row, or no worker answer, falls back to
  fleet.conf column 4. Any other value is refused and nothing is filed.
- `file_children` picks its lane through `tracker_adapter`. `fc-issues.sh` and
  `fc-board.sh` make their parent-side calls through the adapters. The logs and
  request bodies they write are byte-identical to before (pinned against goldens
  from `0dab314` in `tests/fixtures/tracker-port/`). One new file:
  `children/comment.html` on a board split.

## Why

Wave 2 of BH-3979: Jira and Linear (waves 3-4) become one adapter file each and
pass `tests/tracker-contract-test.sh` unchanged.

## How to set the row

`bin/jobs-client.sh setting-set tracker_adapter.<project> board "why"`. No row
exists anywhere today, so nothing changes until an operator sets one.
