# Linear adapter on the tracker contract (BH-4077)

Doc: tracker-adapter, settings-knobs

## What changed

- New `bin/lib/tracker/linear.sh`: the contract's verbs (`list`, `read`,
  `comment`, `transition`, `label_add`, `label_remove`, `link_pr`, `close_out`)
  against Linear's GraphQL API, with the contract's rc table. `waiting_on` is the
  shared one.
- `bin/lib/tracker.sh` registers `linear` (`TRACKER_ADAPTERS`, `_trk_pre`), so
  the settings row `tracker_adapter.<project>` may name it. fleet.conf column 4
  never yields `linear`.
- `file_children` answers a `linear` row with
  `FILE_CHILDREN no child-filing lane for linear (<project>)`, rc 1, and files
  nothing. Before, a valid row would have logged "tracker adapter unresolved".
- The shared contract case C7 takes `TC_LINK_WRITE` (default `comment`), because
  Linear's `link_pr` is an attachment, not a comment.

## Why

Wave 4 of BH-3979: a project whose tickets live in Linear needs the same verbs.
Nothing in the pipeline calls the adapter yet. Triage, run-build and close-out
still make their own calls, so this is the adapter only.

## What is not verified

The fixtures in `tests/fixtures/tracker-linear/` are written to Linear's
documented schema, not recorded from a workspace: this box has no Linear key.
The live run against the test workspace is the command block in
`docs/verification-map/tracker-adapter.md`, and it is owed.
