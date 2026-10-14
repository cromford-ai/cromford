# The conductor's refusal holds on every box; a 406 diff is scanned from git (BH-5914)

Doc: OPERATING

## What happened

On 2026-10-10 the merge conductor refused example-org/project-6 PR #27 at 08:06:01Z. GitHub would not
serve the diff (HTTP 406: 837 files, +175,936 lines), so the iron-law scan did not run. At 08:06:21Z
`bin/merge-queue.sh` on box-project-6-os-1 merged the same head over REST, as
`cromford-board[bot]`. Its log says `[merge-queue #27] rung rest: merged`. The refusal lived only in
the hub's state dir and log, so the box queue could not see it.

## What changed

1. **The verdict leaves the hub.** For every READY head it scans, the conductor writes one jobs-ledger
   row: kind `mc-merge-verdict`, key `<slug>#<n>`, status `hold` or `clear`, and detail
   `<head> <reason>`. A hold means the diff could not be read, or the iron-law scan found hits.
   `mc_merge_verdict_put` (`bin/lib/mc/classify.sh`) sends one PUT per (head, status). A failed PUT is
   sent again on the next tick.
2. **Every merge lane asks it.** `bin/lib/conductor-verdict.sh` (`cv_hold`) holds the one rule, and
   three lanes call it before they merge: the box queue (`mq_land` in `bin/merge-queue.sh`, so the train
   and the serial loop both ask), the reviewer (`merge_step` in `bin/review-prs.sh`) and the run-build
   tier-1 merge (`bin/lib/rb/result.sh`). A `hold` on the head being merged logs
   `MERGE_REFUSED conductor-verdict` and nothing merges: the box entry stays queued, the reviewer hands
   its retry attempt back, and the tier-1 build exits through `PR_CREATED`. A hold binds to its head, so
   an old refusal does not hold a new head. A worker outage fails open with a log line, as these lanes do
   for every other worker read. A box with no ledger client merges as before. In the box queue only, a
   head the pass cannot read holds the entry for that pass.
3. **A 406 is scanned from git, every file.** `mc_pr_diff_or_local` reads the API diff first. On HTTP
   406 only, it runs `git diff <base>...<head>` in the conductor's clone, streamed to the scan file. The
   fetched `refs/pull/<n>/head` must be the head the tick read. Every text file is scanned whatever its
   size, because the scan reads line by line. A file with no text to scan (binary) is named in the log
   and HOLDS the head (`iron-law: N file(s) not scanned`), like an unread diff, and that partial count is
   never stored in the scan memo. A hold with hits names each one (`<file> (<match>)`). A 403, 429 or 5xx
   is still UNVERIFIABLE, as before.

## Operating

- Read a verdict: `bin/jobs-client.sh ledger-get mc-merge-verdict 'example-org/project-6#27'`.
- Release a hold by hand, after you check the head yourself:
  `bin/jobs-client.sh ledger-put mc-merge-verdict '<slug>#<n>' clear '<head> released by <who>: <why>'`.
- Unscanned files: `grep 'not scanned' /root/harness/logs/merge-conductor.log`.
- `flags/conductor-owns-merges` still stands every box queue down. This change covers a box queue that
  runs while that flag is off.

## Limits

- A lane honours a verdict the conductor already wrote. A head the conductor has not scanned yet has no
  row and merges as before.
- The Mission Control `merge_pr` command (`bin/poll-commands.sh`) is a person's explicit merge and does
  not read the row. To release a hold, clear the row (see Operating).
