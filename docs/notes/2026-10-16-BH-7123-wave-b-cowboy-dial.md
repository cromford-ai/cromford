# BH-7123 wave B: the cowboy dial, no follow-up chains, the ratchet floor

Doc: docs/REVIEW_SEVERITY_AUDIT_2026-10-16.html

## What changed

Wave A (bff31f499) put the review levels in place: an ALWAYS-BLOCK floor
(`catalog/review-always-block.tsv`), a mechanical demoter (`rl_cap`) and the
settings rows `review.mode[.<project>]` / `review.mode_until[.<project>]`.
Wave B is the operator's dial on those rows, its clock, and the three places
the system would otherwise undo the levels on its own.

### The dial (`bin/review-mode.sh`)

```
bin/review-mode.sh <project|fleet> <strict|shadow|levels|cowboy|off> [--for <Nm|Nh|Nd|forever>] [--why "<text>"]
bin/review-mode.sh show [project|fleet]
```

One row per project (or the fleet) plus its expiry, written through
`setting_set`, so every flip is a `config_changes` audit row. `cowboy` and
`off` default to `--for 6h`; `levels`, `strict` and `shadow` to no expiry.
"No expiry" is stored as `never` (`PUT /api/settings` refuses an empty value,
and a stale until row has to be cleared, not left to fire). A refused call
(unknown mode, a project not in `fleet.conf`, a bad `--for`) writes and
announces nothing. A successful write posts one operator line through
`bin/alert-line.sh`. The readers (`rl_mode`, `rl_cap`) pick the row up on the
next review: no deploy, no restart.

### The clock (`bin/review-mode-expire.sh`, hub lane `review-mode-expire`)

Every 15 minutes behind the hub lease (`cron/lanes/472-review-mode-expire.cron`)
it reads the settings snapshot once; a `review.mode_until[.<p>]` in the past
whose mode row is not `levels` is flipped to `levels`, its until row cleared,
one log line and one operator line `review.mode[.<p>] expired: <old> -> levels`.
A row already at `levels` only has its stale until cleared. `never`, `-` and an
empty value mean no expiry; junk is logged and skipped. Idempotent; an
unreadable settings read or a failed write changes nothing (the next tick
retries). Off: `flags/lane-off-review-mode-expire`.

### No follow-up chains

* `bin/lib/gh-shim/followup-guard.sh` (sourced by the gh REST shim beside the
  other handlers) and `gshim_cmd_issue_create` in `issue-write.sh`: a build
  whose own ticket is a follow-up (first body line `Follow-up-of: #<n>` or the
  QA marker `<!-- findings-followup-of: -->`) gets rc 1 and one stderr line on
  `gh issue create`; nothing is posted. The ticket body comes from the build's
  own `builds/<project>-<ticket>-*/ticket-meta.json`, else ONE issue GET cached
  under the build dir (or `state/gh-shim/`), only for a numeric key. Every issue
  a build does file gets `Follow-up-of: #<ticket>` as its first body line (the
  key as given: `#7123`, `#BH-7123`, `#TK-233`). `review.followup_chain=1`
  (seed 0, `worker/jobs/schema.d/202610162032-bh-7123-wave-b.sql`) turns the
  guard off.
* `bin/lib/group-findings.sh`: when every open issue of a group has an approved
  PR and the first of them is itself a follow-up, the new scope is a comment on
  it, never a third ticket. The follow-up floor `review.followup_min_level`
  (`always|core|never`; per board `review.followup_min_level.<board>`) is read
  through `rl_knob`: `never` files no group ticket, `core` files only a group
  with a high|critical row or a core-flow screen (`review.core_flows.<board>`),
  `always` is today. Rows under the floor end `floor` in the ledger with the
  reason. The CODE default is `always` (today's behaviour when no row is
  readable); the DB seed from wave A is `core`. An urgent data-leak or
  launch-blocker is filed by `_gf_urgent` before the groups and is not subject
  to the floor.

### "Judged at" and the ratchet

* `rl_judged_mode <report>` (appended to `bin/lib/review-level.sh`) reads the
  mode from a report's `Review level (BH-7123)` marker; no marker reads
  `strict`. `bin/lib/review-judged.sh` resolves a PR's judged mode from the
  hub's `state/lead-reviews/lr-<pr>-*.md` (header-checked for the repo), else
  the verdict row's `report:` token (`GET /api/verdicts?repo=&pr=`), else
  `unknown`.
* `bin/lesson-propose.sh`: BLOCK verdicts judged under `cowboy`/`off` leave a
  trigger before anything else (the verdict rows name the ids; with no rows
  reachable a cowboy report of a PR takes one BLOCK off the count); a trigger
  that falls under `min_blocks` is skipped with a log line. A lesson may propose
  a GATE only when its category's cause is on the floor
  (`catalog/review-ratchet-categories.tsv` maps `block_categories` ids to
  ALWAYS-BLOCK classes); every other category gets a NOTE-level check or a
  prompt sentence, the drafting prompt says so, and the issue body carries
  `Level: note` / `Level: gate (class ...)`.
* `bin/review-tighten.sh`: a merged PR judged under `cowboy`/`off` leaves both
  the numerator and the denominator of the reverted/merges ratio; the log line
  carries `cowboy_skipped=<n>`.
* `bin/lead-review-precision.sh` (`bin/lib/review-false-block.sh` `rfb_count`):
  the false-BLOCK counter demoted / (demoted + standing) over the lead reports
  in the window, as `false_block` in the day file and on the log line.
  Report-only.

## Gaps, said plainly

* `rl_cap` writes its marker only when it ran, i.e. on a model BLOCK. A report
  whose model verdict was already MERGE carries no marker and reads `strict`,
  so a cowboy sprint's clean merges are invisible to review-tighten. The fix is
  `bin/lead-review.sh` (owned by wave B2) printing the `## Review level` mode
  into every report header.
* `lead-review.sh` passes no `--note` with the mode; the verdict row's `note`
  carries `report:<ref>` (bin/lead-review-land.sh), which is what
  `review-judged.sh` follows.
* The lesson-propose evidence list is not trimmed by the dropped verdicts (the
  rows do not name which evidence line belongs to which verdict); the counts
  and ids are.

## Tests

`tests/review-mode-dial.bh-7123-test.sh`, `tests/followup-chain-guard.bh-7123-test.sh`,
`tests/lesson-propose-floor.bh-7123-test.sh`. Each was written first and run
red against the tree without the change.
