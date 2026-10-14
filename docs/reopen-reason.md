# Reopen reason (BH-6159)

A reopen is a ticket that the client moved back from `review` or `done`.
`bin/reopen-metrics.sh` (hub cron `15 4 * * *`) writes each reopen to
`logs/reopens.csv`. That row says that the ticket came back. It does not say why.

The same lane now reads the comments posted around the status change and
saves them as the ticket's reopen reason. The code is `bin/lib/reopen-reason.sh`.

## Where the reason is saved

- Ledger row: kind `reopen_reason`, key `"<project> <key>"`. The key is the
  same as in `reopens.csv` (`TK-83` on an app board, `#11` on a GitHub-Issues
  project). Status is `saved`, `no-comment` or `unreadable`. A build on any box
  reads this row.
- Hub mirror: `state/reopen-reasons/<project>/<key>.json`. A `#` in the key
  becomes `_`. The mirror holds the same JSON plus `status` and `ledger`
  (`true` when the ledger took the row).

The detail is JSON v1: `project`, `key`, `day`, `at` (capture time), `from`,
`to`, `move_at`, `window`, `source` (`app` or `gh`), `read`, `attempts` and
`comments` (`at`, `author`, `text`).

## Which comments are saved

1. App board: the window is 24 h before and after the newest `status_change`
   activity to the current status. A board with no activity feed, and every
   GitHub-Issues project, uses the reopen day plus and minus one day.
2. Dropped: an empty body, a GitHub `Bot` user, an app author marked system,
   a body that starts with `[AI Triage]`.
3. Kept: the newest 5 comments in the window, each cut to 500 characters. The
   row is cut to 3800 bytes by dropping the oldest comment first.

## Who reads it

- The build plan prompt (`bin/lib/rb/plan.sh`, block `# >>> reopen reason`).
  A row less than 30 days old adds a `THIS TICKET WAS REOPENED` instruction
  with the comments. `pipeline.log` gets one `REOPEN REASON:` line.
- The triage prompt (`bin/run-triage.sh`). It adds a `REOPENED TICKETS` block
  for the project's rows from the last 14 days.
- The weekly lookback summary (`bin/lookback.sh`). It adds one line:
  `reopens 7d: <project> <n>, ... (<s> of <total> with a saved reason)`.

Client text reaches both prompts inside `=== UNTRUSTED INPUT <id> ===` markers.

## Retries and alerts

- A board read that fails saves `unreadable` and is tried again on the next
  run. After 3 tries the lane writes one ALERTS line
  (`reopen reason not saved after 3 tries for: ...`) and stops trying.
- A failed ledger write keeps the mirror with `ledger:false`. The next run
  sends the row again without a new board read. One ALERTS line per run names
  those keys.
- Each run prints one lane-log line:
  `reopen reasons: <a> saved, <b> no-comment, <c> unreadable, <d> left for the next run (cap <n>)`.

## Knobs

Registry: `catalog/lanes.d/_lib.reopen-reason.json`.

| knob | default | meaning |
|---|---|---|
| `REOPEN_REASON` | 1 | 0 = no board read, no row, no prompt text |
| `REOPEN_REASON_WINDOW_H` | 24 | hours around the status change |
| `REOPEN_REASON_MAX_COMMENTS` | 5 | newest comments saved |
| `REOPEN_REASON_MAX_PER_RUN` | 20 | board reads per lane run, fleet-wide |
| `REOPEN_REASON_MAX_AGE_D` | 30 | older rows are not put in the plan prompt |
| `REOPEN_REASON_TRIAGE_CACHE_S` | 3600 | triage note cache, seconds |

## Read one row by hand

```bash
bin/jobs-client.sh ledger-list reopen_reason 20
cat /root/harness/state/reopen-reasons/project-3/TK-83.json | jq .
grep 'reopen reasons:' /root/harness/logs/reopen-metrics.log | tail -1
```
