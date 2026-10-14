# Revert reason (BH-6160)

A revert is a commit on a project's default branch that takes a merged PR back
out. The revert says that the merge failed. It does not say how. Before this
change, no lane read why a revert happened, and the ticket's rebuild did not
see it.

`bin/reopen-metrics.sh` (hub cron `15 4 * * *`) now also reads each revert and
saves its failure signal for the ticket. The code is `bin/lib/revert-reason.sh`.
It only reads GitHub and the ledger. It writes no board comment and changes no
status.

## Which commits are reverts

The lane lists the default branch's commits from the last
`REVERT_REASON_LOOKBACK_D` days (up to `REVERT_REASON_PAGES` pages of 100). A
commit is a revert when its subject is one of:

| subject | kind | reverted PR |
|---|---|---|
| `Revert "<title> (#N)" (#M)` | revert | N (M is the revert PR) |
| `Revert "<title> (#N)"` | revert | N |
| `Revert "Merge pull request #N from ..."` | revert | N |
| `Rollback: revert failed deploy batch (...) (#M)` | rollback | each sha on the `Reverted:` line of PR #M |

`(#N)` must close the title, so `#12` in the middle of a title is not read as
the PR. A revert of a revert names the inner revert PR. That PR has no ticket
key, so it gets a key-less row.

## Which signals are saved

For each reverted merge:

1. `build`: the failed commit statuses (`failure`, `error`) and check runs
   (`failure`, `timed_out`, `cancelled`) on the merge commit. Saved: the name,
   the description or check title, and the link.
2. `probe`: the `deploy_rollback` ledger row `"<project> <KEY>@<sha8>"` that
   `bin/deploy-rollback-board.sh` (BH-4915) writes, with its `reason`. A
   deploy-train rollback member with no such row gets the rollback PR's first
   line.
3. `stated`: the revert PR's body and comments, newest
   `REVERT_REASON_MAX_COMMENTS`, each cut to 500 characters. Dropped: bot
   authors, the attribution footer, `Co-Authored-By:` lines and GitHub's
   default `Reverts owner/repo#N` line.

## Ticket key

1. The reverted PR's head branch `ticket/<key>` or `ticket/<key>-r<n>`
   (`ticket/TK-271` gives `TK-271`).
2. Else the last word of the PR title, when it is `<letters>-<digits>`
   (`... TK-271` gives `TK-271`).
3. Else the row is key-less: `"<project> #<N>"`. A deploy-train member with no
   PR uses its sha8.

## Where the reason is saved

- Ledger row: kind `revert_reason`, key `"<project> <KEY>"`. Status `saved`
  (at least one revert with a signal), `unreadable` (a GitHub or ledger read
  failed) or `no-signal` (every read worked and found nothing).
- Hub mirror: `state/revert-reasons/<project>/<key>.json`. A `#` in the key
  becomes `_`. The same JSON plus `status` and `ledger`.
- Hub index: `state/revert-reasons/<project>/index.tsv`, one line per revert
  commit: `revert_sha`, `at`, `status`, `attempts`, `keys`, `classes`. It is the
  dedup and retry record and the source of the weekly line.

The detail is JSON v1: `project`, `key`, `at` (capture time) and `reverts`
(newest 3, newest first). Each revert has `revert_sha`, `revert_pr`,
`merged_pr`, `merge_sha`, `kind`, `at`, `status`, `attempts`, `classes` and
`signals` (`class`, `source`, `text`, `url`). The detail is cut to 3800 bytes by
dropping the oldest signal first.

## Who reads it

- The build plan prompt (`bin/lib/rb/plan.sh`, block `# >>> revert reason`).
  A `saved` row less than `REVERT_REASON_MAX_AGE_D` days old adds a
  `THIS TICKET'S LAST MERGE WAS REVERTED` instruction with each signal inside
  `=== UNTRUSTED INPUT revert-<sha8> ===` markers. A `BH-<n>` key on a
  GitHub-Issues project also finds a `#<n>` row. `pipeline.log` gets one line:
  `REVERT REASON: saved <n> revert(s) <classes>`, `none`, `none (no signal)`,
  `none (unreadable row)`, `old (<n> d)`, `off` or `unreadable`.
- The weekly lookback summary (`bin/lookback.sh`). It adds one line:
  `reverts 7d: <project> <n> (build <b>, probe <p>, stated <s>, none <z>), ...`.
  Each revert counts once, under its first class in the order build, probe,
  stated. An unreadable revert adds `, unreadable <u>`. It prints
  `reverts 7d: none` when the indexes hold no revert in the window,
  `reverts 7d: no data (no capture has run)` when there is no state, and
  `reverts 7d: mirror unreadable` when an index cannot be read.

The weekly classes tell an operator which pre-merge check is missing. `build`
means the merge commit already failed a check. `probe` means the deploy probe
caught it. `stated` means only a person wrote down the error.

## Retries and alerts

- A revert that is `saved` or `no-signal` is not read again.
- A failed read saves `unreadable` and is tried again on the next run. After 3
  tries the lane writes one ALERTS line
  (`revert reason not saved after 3 tries for: ...`) and stops trying.
- A commit list that fails 3 runs in a row writes one ALERTS line
  (`revert reason: commit list unreadable 3 runs in a row for: ...`). This is
  the line you see when the hub token cannot read a repo.
- A failed ledger write keeps the mirror with `ledger:false` and writes one
  ALERTS line for that run. The next run sends the row again with no GitHub read.
- At most `REVERT_REASON_MAX_PER_RUN` reverts are read per run, fleet-wide,
  oldest first. The rest are counted as left and read on the next run.
- Each run prints one lane-log line:
  `revert reasons: <a> saved, <b> no-signal, <c> unreadable, <d> left for the next run (cap <n>)`.

## Knobs

Registry: `catalog/lanes.d/_lib.revert-reason.json`.

| knob | default | meaning |
|---|---|---|
| `REVERT_REASON` | 1 | 0 = no GitHub read, no row, no prompt text |
| `REVERT_REASON_LOOKBACK_D` | 7 | days of commits listed per run |
| `REVERT_REASON_PAGES` | 3 | pages of 100 commits per project |
| `REVERT_REASON_MAX_COMMENTS` | 3 | revert-PR texts saved per revert |
| `REVERT_REASON_MAX_PER_RUN` | 20 | reverts read per lane run, fleet-wide |
| `REVERT_REASON_MAX_AGE_D` | 30 | older rows are not put in the plan prompt |

## Read one row by hand

```bash
bin/jobs-client.sh ledger-list revert_reason 20
jq . /root/harness/state/revert-reasons/project-3/TK-271.json
cat /root/harness/state/revert-reasons/project-3/index.tsv
grep 'revert reasons:' /root/harness/logs/reopen-metrics.log | tail -1
```
