# Lead authority mode: a protected path no longer waits on a human (BH-4145, slice 1 of BH-4140)

Doc: lead-authority, lead-verdict

## Why

the operator, 2026-10-03: "lets remove the whole human review for protected code I just
want an automated factory". Until now a PR touching a protected path
(`catalog/lead-protected-paths.tsv` plus the extras row) had its lead MERGE
withheld until someone posted a `--source human` verdict. `lead-verdict.sh post`
exited 5, the conductor parked the row NEEDS_HUMAN_VERDICT and paged, and
nothing else moved it.

## What changed

- New settings row `lead_authority_mode`, read per repo first
  (`lead_authority_mode.<owner>.<name>`), then global. With no row the mode is
  `lane`. The value is trimmed and lowercased once. Anything other than
  `lane|human` (`off`, `human:precision`, `lane human`, blank) is a hold (rc 2),
  never coerced. An unreadable row is a hold too.
- `la_decide` under `lane`: a protected hit answers rc 0, sets
  `LA_PROTECTED_HIT=1` and `LA_PROTECTED_PATHS` (five names, then `+N more`),
  and the reason ends `cleared to merge on the lead verdict (lead_authority_mode=lane)`.
  The files and the head are still read, and a failed read is still rc 2. The
  authority row `lead_authority.<owner>.<name>` is not read under `lane`, so
  `human` and `human:precision` there revoke nothing until the mode is `human`.
- `la_decide` under `human`: exactly the BH-3683 path.
- `la_human_needed` under `lane` returns 0 with no page and no marker. Under
  `human`, or when the mode can't be read, it pages as before.
- `bin/lead-verdict.sh post` under `lane`: the lead MERGE publishes
  `lead-verdict: success`, the verdict row's note gets `authority:lane-protected`,
  and after the publish one PR comment says
  `touches protected paths <paths>; cleared to merge on the lead verdict`. It is deduped per
  head by `state/lead-authority/lane-hit-<owner_name>-<pr>-<sha12>`, written only
  after the comment POST returned 0. A failed comment is one stderr line, the
  post still exits 0, and the next post retries it.
- The conductor needs no change: every park keyed off `la_decide` rc 1
  (NEEDS_HUMAN_VERDICT, the rc 4 enqueue refusal, the unqueue) stops firing.
  Rows already parked are re-asked each tick and leave the park on their own.

Iron-law, provenance and test-tamper gates are untouched, and so is the
human-token machinery (`source=human` still short-circuits with no read).

## Flip it back

    bin/jobs-client.sh setting-set lead_authority_mode human
    bin/jobs-client.sh setting-set lead_authority_mode.<owner>.<name> human   # one repo

Tests: `tests/lead-authority-mode.bh-4145-test.sh`, `tests/mc/no-human-park.bh-4145-test.sh`.
The header of `bin/lib/lead-authority.sh` is the contract.
