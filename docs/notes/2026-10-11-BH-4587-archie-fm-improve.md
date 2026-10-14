# Archie, self-improvement loop: one ai-build issue per recurring cause (BH-4587, wave 5 of #4574)

Doc: OPERATING

## What changed

A new hub lane, `archie-fm-improve` (`bin/archie-fm-improve.sh`, libraries in
`bin/lib/archie-fm-improve/{common,tickets}.sh`, registry
`catalog/lanes.d/archie-fm-improve.json`, cron
`cron/lanes/729-archie-fm-improve.cron`, hourly at `:43` behind `hub-lease.sh
check`). It only READS the rows waves 1-4 write to `archie_actions`. It writes
rows of its own playbook, `improve`. No wave 1-4 lane changed.

1. READ. A tick reads `GET /api/archie/actions?day=<d>&limit=500` (and the same
   with `&playbook=improve`) for `window_days + verify_days + 1` UTC days. A day
   that fails or answers `truncated:true` makes the tick `incomplete=1`.
2. FINGERPRINT. `afi_cause` derives the cause of a row at read time:
   - `watch-<class>`: `watch|<class>|<project>|<lever>` (`would_` removed)
   - `stacked-parent-merged`: `stacked-parent-merged|<repo>`
   - `rebase-repair`: `rebase-repair|<repo>|<park_reason>`, lowercased, with
     `#<digits>` as `#N`, a 7-40 char hex run that holds a digit as `<sha>`,
     other digits as `N`, spaces collapsed, the first 80 chars
   - `queue-culprit`: `queue-culprit|<repo>|<suites, sorted, comma joined>`
   - `queue-enqueue`: `queue-enqueue|<repo>`
   - any other playbook: `<playbook>|<repo>|<action>`
   The fingerprint is the first 12 hex of `sha1(cause)`. One occurrence is one
   dedupe_key with its trailing `:on` / `:observe` removed. Not occurrences:
   playbooks `improve`, `watch-ticket`, `watch-session` and `queue-solo`, any
   row with outcome `skipped`, and a `data-lane` row with outcome `done`.
3. FILE. A fingerprint with `archie.improve.recur_n` (3) or more occurrences in
   the last `archie.improve.window_days` (7) days, and no earlier filing, gets
   ONE issue on `$HARNESS_REPO` with labels `ai-build` and `archie-fm-improve`.
   "No earlier filing": no Archie issue in the `archie-fm-improve` label list
   (state=all) carries the marker `<!-- archie-fm-improve:fp=<fp> -->`, and no
   improve `file_ticket` row closed done for the fingerprint in the rows read.
   An open issue of anyone's that carries the marker is a dedupe hit: the row
   closes done `already filed: <url>` and nothing is posted. The body has the
   cause, the fingerprint, up to 10 occurrences (time, playbook, key, PR link
   when pr > 0, alert id or issue url, and the hand fix: action, outcome, why),
   a fixed `## Acceptance tests` section and the marker. No model call.
4. COMMENT. The open Archie issue gets at most ONE comment per UTC day. It lists
   the occurrences after the filing or after the last comment or reopen row.
5. TRACK. An Archie issue closed as `completed` gets ONE `track_merged` row per
   close: the latest merged PR of the same repo that cross-references it (the
   issue timeline), `closed_at`, and `before` = the occurrences in the
   `window_days` before the close. No merged PR found = `pr: null`.
6. REOPEN. One occurrence later than `closed_at + archie.improve.verify_grace_s`
   (3600) reopens it: the evidence comment first, then `PATCH state=open`. After
   a `verified` row, or for a close older than the days read, a reopen needs
   `recur_n` occurrences in the window again.
7. VERIFY. `archie.improve.verify_days` (7) after the close, with 0 occurrences
   after the grace and every day read in full, the tick writes one `verified`
   row `{before, after: 0}` and posts one comment with both counts. A tick with
   a failed or truncated day in that range does not verify.
8. WEEKLY. `bin/archie-fm-improve.sh section <from-iso> <to-iso>` prints
   `Factory fixes shipped: <n>` and one line per `track_merged` row of the week:
   cause, issue link, PR link (or `closed, no merged PR found`), `before N`,
   `after M` (`(partial)` when a day was not read in full), and `verified`,
   `reopened` or `watching`. It prints `none this week` for zero rows and
   `not measured (<why>)` when it cannot read. `bin/archie-learn.sh`
   `compose_report` calls it once, under `timeout 120`, after the Skills line.

A `closed` issue with any other `state_reason` (`not_planned`: a person chose
it) gets nothing: no reopen, no comment and no new issue.

## Limits

- `archie.improve.tickets_per_day` (3) new issues per UTC day and
  `archie.cap.improve` (10) GitHub writes per UTC day (issues, comments,
  verify comments; a reopen is two writes, the evidence comment and the PATCH). Over a cap the work waits for the next tick or
  day; nothing is dropped. Today's improve rows not read in full = no write.
- At most 30 timeline reads per tick, 5 pages of the label list and 10 pages of
  open issues. A list over its cap, or unreadable, means no claim this tick.
  A list over its page cap also writes ONE ALERTS line per UTC day.
- A tick has a 780 s deadline inside an outer `timeout 900`.

## Rows and keys (`archie_actions`, playbook `improve`, pr 0, project `hub`)

`improve:ticket:<fp>:<day>:<mode>`, `improve:comment:<fp>:<n>:<day>:<mode>`,
`improve:track:<fp>:<n>:<closed_epoch>:<mode>`,
`improve:verified:<fp>:<n>:<closed_epoch>:<day>:<mode>`,
`improve:reopen:<fp>:<n>:<closed_epoch>:<day>:<mode>`. Actions `file_ticket`,
`comment`, `reopen`, `track_merged`, `verified` and their `would_*` forms. The
worker route accepts playbook `improve` with pr 0. Observe mode writes the
`would_*` row and makes no GitHub write. A `started` row older than
`ARCHIE_FMI_RETRY_S` (1800) is closed failed with one ALERTS line. Every
GitHub-write key carries `<day>`, so a failed write is retried the next UTC day
under a new key.

## Settings rows (seeded by `worker/jobs/schema.d/0020-bh-4587-archie-improve.sql`)

`archie.cap.improve` 10, `archie.improve.recur_n` 3,
`archie.improve.window_days` 7 (1..30), `archie.improve.tickets_per_day` 3,
`archie.improve.verify_days` 7 (1..14), `archie.improve.verify_grace_s` 3600.
A junk value is one log line and no action. The mode is `archie.manage.hub` >
`archie.manage` > on.

## Status

One line per tick that did anything, in `logs/archie-fm-improve.log`:
`fps=<n> recurring=<n> filed=<n> commented=<n> reopened=<n> tracked=<n> verified=<n> would=<n> capped=<n> skipped=<n> failed=<n> incomplete=<0|1>`.

## Never

A git command, a push, a PR, a merge, a model call or a state file. Archie
files the issue; the board watcher and the pool build the fix.

## Off

`ARCHIE_FMI_ENABLED=0`, `flags/lane-off-archie-fm-improve`,
`bin/harness-ctl.sh off archie-fm-improve`, or `archie.manage[.hub]=off`.

## Probe on the hub

1. `/root/harness/bin/archie-fm-improve.sh --dry-list` (fp, count, state, cause;
   writes nothing).
2. `tail -1 /root/harness/logs/archie-fm-improve.log` after a tick.
3. `GET /api/archie/actions?day=<today>&playbook=improve` on the jobs worker.
4. `https://github.com/example-org/cromford/issues?q=label%3Aarchie-fm-improve`.
5. `/root/harness/bin/archie-fm-improve.sh section <monday-iso> <sunday-iso>`.

Tests: `tests/archie-fm-tickets.bh-4587-test.sh`,
`worker/jobs/test/archie-actions.bh-4587.test.js`.
