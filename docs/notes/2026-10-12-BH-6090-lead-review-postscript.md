# The lead review keeps the review, not the postscript (BH-6090)

Doc: LEAD-REVIEW

## What happened

`bin/agent-call.sh` writes `$OUT` from the claude CLI envelope's `.result`. That is the model's
LAST assistant message only. On #5980 (head e71a491c80b7) the lead model wrote its review (1 BLOCK,
5 NOTEs), then one more message: "The monitor expired ... The review above is final and does not
change. VERDICT: BLOCK". `bin/lead-review.sh` stored that postscript as the whole report, the
`lead_review_report` artifact and the result. `bin/lead-review-land.sh` posted it as a
REQUEST_CHANGES review. A BLOCK with no finding cannot be answered by a fix round or a person.

On box, 12 of 643 stored reports in `state/lead-reviews/` were postscripts only. Some of
them carried a MERGE verdict, so the defect is not only on BLOCK.

## What changed

1. `bin/agent-call.sh` writes `$OUT.session` after a claude attempt that has a session id. The
   file is one line: `<session-id><TAB><config-dir>`. The config dir is the account's
   `CLAUDE_CONFIG_DIR`, else `$HOME/.claude`. The start of each attempt and a LEDGER HIT exit
   remove it, the same as `$OUT.account`. It holds no token.
2. `bin/lead-review.sh` has two new functions beside `lr_verdict`:
   - `lr_has_findings <file>`: rc 0 when the text has a `Findings` heading (`Findings`,
     `## Findings`, `**Findings**`, `Findings:`, any case) and then a `- [BLOCK`, `- [NOTE`,
     `- none` or `no findings` item, or `Findings: none` on one line.
   - `lr_pick_review <out> <key>`: when the answer has findings, it does nothing (the report is
     byte-identical to before). Otherwise it reads the session transcript that `<out>.session`
     names (`<config-dir>/projects/*/<sid>.jsonl`). It joins the text blocks of each non-sidechain
     assistant message (by `.message.id`), and walks the messages from the last to the first. The
     first one with findings AND a valid `VERDICT:` line replaces the answer. The log line is
     `kept review message <i> of <n> from session <sid> for <key>; the last message held no
     findings`.
3. When `lr_pick_review` finds no such message, the verdict is `unknown`. That is the existing
   path: one retry call, then `<key>.empty`, the `{empty:true}` artifact and
   `outcome=failed detail=empty` (BH-5793). lead-review-land requeues an `empty` failure up to
   `LEAD_REVIEW_ENV_RETRY_MAX`. The log line is `no readable review (findings and a verdict) from
   <model> for <key> after one retry`. A bare `VERDICT: MERGE` with no findings is now unreadable.
4. `bin/lead-review-land.sh` step 2b does not post a REQUEST_CHANGES review when the body is this
   head's whole report (not truncated, not the `Full report:` pointer) and has no line that
   starts `- [BLOCK`. It writes one ALERTS line (flag `state/lead-review-land/emptyblock-<id>`,
   once per reset), stamps the request and dismisses nothing. The BLOCK verdict row stands. If the
   ALERTS append fails, nothing is stamped and the next tick tries again.

No new knob, env var, schema or prompt change. A codex, grok or OpenRouter answer has no
`$OUT.session`, so a postscript from those runners takes the failed-empty path.

## How to check it

- Lead box: `grep 'kept review message' logs/lead-review.log` names each recovered review.
- Hub: `grep "no '- \[BLOCK' finding line" logs/ALERTS.log` names each withheld review.
- Tests: `tests/lead-review-postscript.bh-6090-test.sh` and
  `tests/agent-call-session-sidecar.bh-6090-test.sh`.
