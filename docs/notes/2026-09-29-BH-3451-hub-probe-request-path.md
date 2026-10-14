# The hub-probe request path: HUB_PROBE: lines from a build's own output (BH-3451)

Doc: RUN-BUILD-GRAPH

## What changed

This is slice 4 of BH-3434. The contract (BH-3447) gave us `hp_request` and
`hp_validate`. This slice is the side that asks.

- New lib `bin/lib/hub-probes/request.sh` (sourced, never run):
  - `hp_parse_request_lines <file>` is pure. It prints `probe<TAB>args` for each
    whole line matching `^HUB_PROBE: ([a-z0-9-]+)( [^ ]+)*$` that `hp_validate`
    accepts, de-duplicated. It skips lines inside a ``` or ~~~ fence, any line
    carrying `lead-verdict`, and any line with a control character. A dropped
    `HUB_PROBE:` line is logged on stderr. rc 2 on an unreadable file.
  - `hp_file_requests <project> <ticket_key> <file> <requested_by>` calls
    `hp_request` once per parsed line, args as a jq-built JSON array of strings.
    rc 1 when any line failed to file.
- `RESULT()` in `bin/run-build.sh` is the one place every build terminal passes
  through. After it writes and echoes the line, it files the requests in
  `$BUILD/review.md` (`build:review`) and `$BUILD/execute-run.txt`
  (`build:execute-run`) into `pipeline.log`, and returns 0. The lib is sourced by
  the fail-open `hub-probe request seam` block, so a box without it files nothing.
- The rule: D44 in `prompts/build-discipline.md` (the builder loads it; the
  reviewer is pointed at it) and a `HUB PROBES (D44)` paragraph on `REVIEW_PROMPT`
  in `bin/lib/rb/review.sh`, the prompt the in-build review actually loads.

## Why

A check that needs the GitHub App or D1 used to end in "needs a human". Four of
them are now probes the hub can run itself, so the build asks for the probe.

## Notes

- The ticket's name pattern was `[a-z-]+`, which can never match `d1-count`.
  The lib uses `[a-z0-9-]+`; `hp_validate` still gates the name.
- `prompts/lead-review.md` is not edited. The lead lane's output is a PR
  comment that nothing in this path reads.
- Suite: `tests/hub-probe-request.bh-3434-test.sh`.
