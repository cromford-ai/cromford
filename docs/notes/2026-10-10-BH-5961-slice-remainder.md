# A merged slice files the rest of its issue (BH-5961)

Doc: MERGE-CONDUCTOR

## What changed

A merge whose plan says `SLICE: C<k> of #N` and finds no open child issue now files the
remaining slices the plan names (C<k+1>..C<m>) as child issues. Before, the close-out
posted "No child issue carries the rest yet" and raised a warn alert, and the parent
stalled. `bin/lib/slice-remainder.sh` parses the plan and calls `fc_file_issues` with the
new kind `slice`. The filer comments on the parent and takes `ai-build` off it.

A SLICE plan that names no remainder now pages critical `SLICE_REMAINDER_UNKNOWN` once, in
place of the warn alert. `slice:no-keyword` (no SLICE line) is unchanged.

## Where

- `bin/lib/issue-state-lib.sh` `issue_slice_settle` and `bin/lib/mc/classify.sh`
  `mc_close_shipped`: the no-children arm.
- `bin/lib/fc-issues.sh`, `bin/lib/file-children.sh`: the `slice` kind.
- `bin/hotfix-after-deploy.sh`: `close-deferred:remainder` has its own OWED text.

## Knobs

`SLICE_REMAINDER_FILE` (default on), the `slice-remainder-off` switch (`lane_switch`), `SLICE_REMAINDER_MAX`
(default 6). Operator notes: `docs/verification-map/slice-remainder.md`.
