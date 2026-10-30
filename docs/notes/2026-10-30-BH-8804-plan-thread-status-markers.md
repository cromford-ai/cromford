# BH-8804: the plan-thread gate skips our App's status comments

Doc: RUN-BUILD-GRAPH

## Why

On 2026-10-30 at 00:48:58Z our App posted a stop report on #8775 (comment
6512133562). A build of #8775 had run since 23:50Z. At 01:40:52Z the pool
reaped it: `PLAN_STALE uncited comment(s) newer than the plan: 6512133562`.
`ptg_classify` counted every newer, uncited comment by our App as steering.
Only the build's own-post ledger was exempt.

## What changed

- `catalog/plan-thread-status-markers.txt` (new): one ERE per line,
  `<ERE><TAB># <writer path> — <what>`. The lib reads only lines that start
  `^<!-- `. A missing or unreadable file means no markers (the old rule).
  Test seam: `PTG_STATUS_MARKERS`.
- `bin/lib/plan-thread.sh` `ptg_classify`: a candidate by one of our Apps
  (Bot type and `hs_ours`) whose first non-blank line matches a catalog ERE
  is skipped. A person is never skipped. The rc 0 line is now
  `ok<TAB><n> newer by a person or our App, each cited, our own post or a status report, <k> status comment(s) skipped`.
  The refuse line is unchanged.
- Writers put the marker on line 1:
  - `<!-- harness-status: selection-gate -->`: `sg_notice` in
    `bin/lib/selection-gate.sh` (the GATE_RED notice).
  - `<!-- harness-status: board-closeout -->`: the GitHub branch of
    `bin/board-closeout.sh`.
  - `<!-- harness-status: results-sweep -->`: the results sweep close-out and
    stop comments, in `prompts/TEMPLATE-GH.md` and the 10 GitHub-board
    prompts rendered from it.
- Not registered on purpose: holds, steers, `comment_issue`, grouped
  findings, nightly red reports. Each of these can change scope.

## Check

`HARNESS_TEST_SANDBOX=1 bash tests/plan-thread-status-marker.bh-8804-test.sh`
(M1-M8). On a box: `grep -h 'status comment(s) skipped' /root/harness/builds/cromford-*/pipeline.log`.
