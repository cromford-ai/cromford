# The pre-PR gate runs again on the head that opens the PR

Doc: RUN-BUILD-GRAPH

## What was wrong

BH-1706's pre-PR gate runs `bin/checks-run.sh --tree .` and
`bin/test-determinism-lint.sh` once, right after execute. The review fix rounds
and the pre-PR rebase onto `origin/$BASE` both come later and both can move the
head. On #1983 (BH-1715) a review fix round added a raw `rm -rf "$PD/…"` in a
test, and the rebase pulled in main's new `sigpipe-negative` lint rule (BH-1818)
for a line the build already had. Neither was scanned. CI went red and the lead
fixed both by hand.

The ticket blamed diff mode dropping `tests/`. That is true of
`bin/checks-run.sh` diff mode, but the pre-PR gate has used tree mode since
BH-1706, so it was not the cause on this path.

## What it does now

`bin/run-build.sh` has a `# >>> prepr late` block right after
`# <<< pre-pr rebase`, before tier classification, the push and the PR. It calls
`prepr_gate_late . "$BASE" "$BUILD"` from `bin/lib/prepr-gate.sh`:

1. The first pass now writes the head it judged to `$BUILD/prepr-head`. If the
   head has not moved, the late pass writes `state=unchanged` and does nothing
   else.
2. Otherwise it runs the same scan, fix turn and re-scan, with artifacts under
   `$BUILD/prepr-late/` and one `PREPR late state=` line in `pipeline.log`.
3. The diff base is `origin/$BASE` when that ref exists, so after the rebase a
   stale local main does not turn main's own files into this build's findings.
4. There is still one fix turn per build: `RB_PREPR_FIX_TURNS` minus the
   `fix_calls=` the first pass recorded. With the turn already spent, an
   in-diff finding is `red` and the PR body says the turn was spent. With the
   knob at 0 it is `off`, as before.
5. A late verdict from a scan that ran replaces `PREPR_STATE`, `PREPR_NOTE` and
   `PREPR_SECTION`, so the PR body and ` | prepr=red` describe the head that
   opens. A late `could-not-run` keeps the first pass's verdict and records no
   head.

A late fix commit lands after `review-head`, so the head-bound approval gate
re-reviews it like any other drift.

Not covered: lead PRs (`lead/*`) never run `bin/run-build.sh`, and
`bin/checks-run.sh` diff mode is unchanged.

Suite: `tests/rb-prepr-late.bh-2021-test.sh`.
