# BH-10198: the blocked resolver reads a quiet park only after a change

Date: 2026-11-26. Ticket #10198 (second round of #9926).

## Problem

On the hub, hour 16 of 2026-11-26, `bin/blocked-resolver.sh` made 1,662 GitHub calls (pulls/{n} 450, issues/{n} 303, issues/{n}/comments 264). Most were reads of parks that ended on a quiet exit (held, escalated, stalled, needs-human). The unchanged skip (BH-5946) held such a row for 1800 s only. Then the lane read it from GitHub again and got the same answer.

## Change

- The unchanged ledger line (`state/blocked-resolver/<p>/.looks/<rkey>`) has two more columns, taken before the row's GitHub reads: `wm` (the wakes watermark: the highest worker wake id in the box's wakes mirror) and `rv` (the PR record version: a sha1 of the record fields a park depends on, then `|<head_sha>`). A write that moves only `refreshed_at` is not a change. No box clock is compared with a worker clock.
- Before the skip, `br_rac_due` (`bin/blocked-resolver.d/bh-10198-read-after-change.sh`) reads the wakes mirror (`prs_wake_seen`) and the PR record (`pr_record_peek`). These are jobs reads, not GitHub calls.
- The gate is asked only past the 1800 s window. Inside the window the skip of today holds, and no record is peeked.
- A wake row with an id above `wm` (kind `issue` for the ticket issue, `pr` for the PR, `checks` for the head) or a new record version: the park is read on this tick.
- No change and every source answered: the park is skipped until `BR_RAC_BACKSTOP_S` (default 21600 s = 6 hours).
- A source that cannot answer, a park with no PR, a PR in another repo, the `job-abandoned` class (a newer job row makes no wake), a tracker that is not GitHub Issues, or an old ledger line: the park is read, as today. GitHub is the fallback. A park with no PR is never quiet, because an App comment or a label change on an issue can make no wake.
- The ledger prune keeps a line to `BR_RAC_BACKSTOP_S` when the fragment is on, because a quiet skip does not rewrite the line.

## Operate

- Knob: `BR_RAC_BACKSTOP_S` (`catalog/lanes.d/blocked-resolver.knobs.d/BR_RAC_BACKSTOP_S.json`). 0 turns the gate off.
- Switch off the fragment: `BR_OPT_OFF=bh-10198-read-after-change`.
- Count: the tick counts `rac-quiet` (a skip past 1800 s) and `rac-changed` (a read that a change caused).
- Measure after the deploy: `bin/gh-ledger-report.sh --per-merged-pr --by-repo --last 24h`, and the `blocked-resolver.sh` lines in `logs/gh-calls/<hour>.log`, against 1,662 an hour.

## Limits

- Only the quiet classes of `BR_UNCHANGED_CLASSES` with a PR use the gate. A row that took a rung is read as before.
- The mark is a local ledger line, not a D1 row. A lost ledger costs one read, never a wrong skip.
- A wake that the worker writes after the mirror's last read has a higher id, so it is seen on a later tick, never lost. A mirror that was reset (its watermark below `wm`) answers unknown.
