# A lead CHANGES_REQUESTED survives main merges, and a silent Mergify queue holds

Doc: MERGE-CONDUCTOR, MERGIFY

## What was wrong

- #2158 merged over the lead's CHANGES_REQUESTED. The block gate read review TEXT only (a
  `## BLOCKING` body has no `BLOCK` marker), and it read any head authored after the review as a
  fix. The two heads after the review were `Merge origin/main`.
- #2196 merged at the very head the review named, and it did so through the degraded path: the
  Mergify queue acknowledged nothing, so the conductor merged directly around it.

## What changed

- `bin/lib/block-gate.sh` `bg_cr_standing` (first in `bg_scan_read`, so every merge lane) reads
  the review STATE:
  - a standing non-bot, write-access CHANGES_REQUESTED on the live head blocks;
  - so does one on an older head whose own diff (`compare/<base>...<sha>`, +/- lines per file)
    the live head still carries;
  - it is lifted by the reviewer's APPROVE or DISMISS, a later RESUME/MERGE comment by the same
    login, a lead MERGE verdict row, or a change to the PR's own diff.
- `bin/merge-conductor.sh` rc 3 (Mergify acknowledged nothing) HOLDS:
  - no direct merge and no strike, and the row stays READY with the label on;
  - one alert per repo per day, under a lock;
  - a re-ask every `MC_MERGIFY_REASK_TICKS` held ticks (a new registry knob, default 6).
- `bin/poll-commands.sh` merge_pr (Mission Control's Merge button) on a `queue_rules` repo:
  - asks the Mergify queue (`mc_enqueue_mergify`) on the live head, bound to the reviewed sha, and
    never sends PUT /merge;
  - a silent queue acks a terminal `refused: … NOT merged directly`.
