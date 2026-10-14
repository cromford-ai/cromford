# A comment holds only on its first line, and every lane reads it one way (BH-6297)

Doc: VERIFICATION-MAP, OPERATING

## What happened

On 2026-10-12 at 15:22Z the operator posted a decision on #5239, a launch blocker with
the hotfix label. A later line of that comment said the Cloud PRs #4761 and #4792
"are on HOLD here". The fastpath matched the capital word anywhere in a comment
(`HOLD_WORD_RE`) and logged `FASTPATH-DECLINED 5239 :: HOLD in comment` at
15:23:03Z. No later event woke the ticket. It did not build for 4 h 27 min,
until a `RESUME` comment at 19:48Z.

`hold_classify` in `bin/lib/hold.sh` had the same rule, so triage, the conductor
and the hold-push guard read the comment as a HOLD too. The fastpath also had
its own thread walk, with no bot filter and no NEEDS-HUMAN or human-fix arm.

## What changed

1. A comment holds only when its first non-blank line starts with the capital
   word `HOLD` (`HOLD_COMMENT_RE`): `HOLD`, `HOLD —`, `HOLD:`, `HOLD this …`.
   A later line, `Please HOLD`, `> HOLD`, `- HOLD`, a code span, `HOLD-free`,
   `HOLDING` and `HOLD_X` hold nothing. `hold_classify` and `hold_ambiguous`
   pass it as the comment HOLD test. The newest decisive person comment still
   wins.
2. `bin/launch-fastpath.sh` condition 12 is now `hold_classify`'s verdict, run
   in bash and handed to the python step as `FP_HOLD`. The fastpath now skips
   bot comments, parks on NEEDS-HUMAN and human-fix markers, declines the
   `hold` label (`HOLD label`) and declines an unreadable verdict
   (`hold unreadable`). Its own walk runs only on a box without the lib, and it
   uses the first-line literal.
3. A ticket with the hotfix label that the fastpath declines for a HOLD writes
   one ALERTS line through `bin/alert-line.sh --id fastpath-hold-<project>-<KEY>`.
   The line quotes the comment line that decided. The marker
   `state/fastpath-hold-alert/<project>/<KEY>.<sha12 of the line>` stops a
   repeat on the next tick. The decline, stdout and exit code do not change.

`HOLD_WORD_RE` stays defined and exported: the python fallbacks in
`bin/orphan-reconcile.sh` and `bin/launch-fastpath.sh` (the T1.32 verbatim
block) read it on a box that has not synced the lib.

## Who reads it

Every caller of `hold_classify` and `hold_check`: triage-state, the hold-push
guard, the orphan reconciler, execute-empty, ticket-ownership (the conductor),
mc/rebase, the pool's hold check, the blocked resolver, needs-human-hold, and
now the fastpath. A ticket that was held only by a HOLD word below line 1 of
its newest decisive comment is buildable on the next tick in all of them.

Pinned by `tests/hold-parse-shared.bh-6297-test.sh`.
