# A rescued review reaches `logs/findings.log`: review-rescue clears `.findings-general`

Doc: DB-COORDINATION-SPEC

## What was wrong

`bin/findings-log.sh` writes a `.findings-<lens>` marker in the build dir for
every lens it reads, and skips a marked lens on every later call. The review
stage harvests all lenses when it ends, so a build that died mid-review already
had `.findings-general` set from its DRAFT `review.md`.

`bin/review-rescue.sh` then has its agent rewrite `review.md` as the complete
review, and it left the marker alone. The next harvest (`bin/rule-miner.sh`
walks every build dir and calls `findings-log.sh` on it) skipped the rescued
review. Its findings never reached `logs/findings.log`, so rule-miner's
promotion counts undercounted every rescued build.

## What it does now

In the re-review branch, `review-rescue.sh` takes a `cksum` of `review.md`
before the agent call and again after it. If they differ, it removes
`.findings-general`, and the next harvest reads the rescued review once and
sets the marker again.

- The agent wrote nothing, or wrote the same bytes: the marker stays, and no
  row is logged twice.
- A standing APPROVE reused on a test-tamper block (`REUSED=1`) never calls the
  agent, so the marker stays.
- Only `.findings-general` is touched. `review.md` is the only lens file this
  lane writes, so `.findings-security`, `.findings-refuter` and
  `.findings-prodqa` are left as they are.
- The rescue does not harvest by itself. The next sweep does.

The marker now means "this content was harvested", not "this lens was
harvested once for the life of the build". The header of `bin/findings-log.sh`
says so.

## Known overlap

A finding that appears in both the harvested draft and the rescued review is
logged twice, once per version. `findings-log.sh` dedups within one call, not
against the log. A partial rewrite killed at the deadline and rewritten by the
second attempt can add one more version. Both are bounded by the lane's
two-attempt cap.

## Tests

`tests/review-rescue.bh-118-test.sh` drives the real `bin/review-rescue.sh` and
the real `bin/findings-log.sh`: harvest the draft, rescue with a rewrite, then
harvest again. The rescued row lands once, and a third harvest adds nothing. A
reused APPROVE and an agent that wrote nothing both keep the marker and add no
rows. The security and refuter markers survive a general rewrite.
