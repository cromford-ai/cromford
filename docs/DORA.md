# DORA + unit economics — the daily digest

`bin/dora-digest.sh` reads the records this fleet already writes and says, once a
day, how fast it ships and what that cost. It computes nothing new: every figure
below already existed in a log, a csv or the ledger, and the only thing missing
was a lane that reads them on a schedule.

**Why it exists.** On 2026-09-15 the operator asked three questions in one day — "how's
the project-5 drain", "cost per PR", "when do the max accounts hit caps" — and
each one was answered by hand, by grepping four logs and a csv. Any number that
has to be assembled by hand is a number nobody checks on the days nobody asks.

```
bin/dora-digest.sh                     # trailing 24h, writes the files, posts the beat
bin/dora-digest.sh --window 7d         # trailing 7 days
bin/dora-digest.sh --window 24h --no-send --print   # read-only: prints, posts nothing
```

Cron on the hub: daily 07:00Z.

## Output

| where | what |
| --- | --- |
| `state/dora/<date>.json` | the full payload. Every metric carries the file (or route) it came from and the line/row counts read, so any figure can be re-derived by hand. A non-default window writes `state/dora/<date>-<window>.json`, so the 7d run never clobbers the daily one. |
| `state/dora/latest.txt` | the plain-text message, complete and untruncated. |
| one fleet-topic beat | the same text, `{kind:fleet_alert, project:fleet, triaged:true}` — the pass-through `bin/alert-digest.sh` and `bin/cost-rollup.sh` already use to put a daily digest in the topic without going through alert quarantine. Truncated at `DORA_TEXT_MAX_CHARS`; `latest.txt` is always whole. |

## Where every number comes from

**Merges and lead time — `GET /api/metrics/dora?days=N` on the harness-jobs
worker** (`computeDora` in `worker/jobs/src/lib/core.js`, served by
`worker/jobs/src/routes/dora.js`; the DORA panel from #274).
This is the most reliable of the three candidates and the digest says so in the
payload: it is keyed per PR off the `ledgers` kind=merge rows, and it derives
lead time from `jobs.created_at` — the instant the ticket was claimed — rather
than from a build directory's mtime, which a rebuild rewrites, or from a log
line, which rotates. `logs/merge-conductor.log` is the fallback for the merge
count and is read either way for the conflict rate. When the ledger answers, its
count is the headline and the log's own count rides along as
`merged_conductor_log`; when it does not, `merged_source` names the fallback and
lead time reports `n/a (source /api/metrics/dora absent)` rather than a zero.

**Launch lead time — `jobs.issue_created_at` → `jobs.first_spawn_at`.** How long
a ticket waits between being written on the board and this fleet putting an
agent on it. Both stamps live on the `jobs` row, and they are recorded for
GitHub-Issues projects only: an in-app board hands us no issue `createdAt`, so
those rows keep a null and are counted as dropped rather than as a zero wait.
The shape the worker and the digest agree on is, per project,
`launch_lead_time: {p50_s, p90_s, n, basis, dropped_n}` — `n` is the number of
jobs both stamps were readable on, `dropped_n` the number that had only one or
neither, `basis` the string naming which rows were measured — and
`totals.launch_lead_time` with the same keys across every project. A payload
with no `launch_lead_time` key came from an older worker, and the digest prints
`n/a` for it rather than a zero. As of this change neither end exists yet: the
columns are here and nullable, the worker that stamps them and the digest that
reads them are separate tickets.

**Conflict rate — `logs/merge-conductor.log`.** DISTINCT PRs entering
`NEEDS_REBASE` (the state the conductor moves to on `mergeState DIRTY`) over that
same log's merge count. A PR that bounces in and out of `NEEDS_REBASE` three
times is one conflict, not three; the raw `merge=DIRTY` line count is reported
beside it as `dirty_log_lines` for anyone who wants the churn.

**Rebuild rate, lane deaths, abandonment — `logs/blocked-resolver.log`.**
`REBUILD FRESH n of m` and `FIX ROUND` are counted as EVENTS (three rebuilds of
one ticket is three rebuilds). Lane deaths, `red-twice` parks and `ABANDONED` are
counted as DISTINCT `<project>/<ticket>`. A lane death is a park whose reason
names a dead pool lane (`pool-died`, `pool-died-twice`) — that is the only place
this fleet writes a lane's death down in a form keyed to a ticket.

**Change-failure proxy — the ledger's `outcome_metrics` reverts/reopens PLUS the
resolver's `red-twice` parks**, over the merge count. It is a PROXY and named as
one: `main_red` (the ledger's "we merged green and main went red") rides beside
the rate without entering it, the same split `bin/outcome-metrics.sh` and the
OUTCOMES screen already make.

**Money — `state/cost/fleet-cost.csv`,** read BY COLUMN NAME (`ts`, `project`,
`cost_usd`, `billing_mode`, `auth_account`). Not by index: that file's column
order has moved before, and a digest that reads column 13 reports a token count
as dollars the day somebody inserts a column. `billing_mode=subscription` is
absorbed, `metered` is cash, anything else is `unknown_billing_usd` — a blank
mode is never quietly counted as free. An unpriced row costs $0 and still counts
in `rows`, with the count of them in
`sources.fleet_cost_csv.unpriced_rows_in_window`.

**`$/PR`, two ways, both named.** `per_pr_usd` divides a repo's whole window
spend (triage and preplan included — spend that opened no PR is still spend) by
its merge count. `fleet.cost.per_pr_usd_all_in` additionally carries the lanes
that own no repo — alert triage, the medic, fleet chores — itemised under
`fleet.cost.non_repo_usd`, because that is what the bill actually is.
`cost.attributed` is the independent cross-check: `state/cost/cost-per-pr.csv`,
which the rollup priced per PR, joined on the PR urls this window merged. That
csv has no timestamp column, so the window comes from the merge log; the payload
says so.

**Box test minutes — `builds/<dir>/pipeline.log` `STAGE-TIMING` lines.** How many
minutes this box spent running the repos' own suites, per project and per merged
PR (`box_test.minutes`, `box_test.per_pr_min`, read from `DORA_BUILDS_DIR`, with `denominator` and
`denominator_source` naming the merge count it divided by). The source line is
the one `STAGE_END` writes around every call of `HARNESS_SUITE_RUN` in
`bin/run-build.sh` — stages `suite` (before the lenses read the diff),
`suite-fix` and `suite-head`. Nothing else is counted: a `gates` line or a stamp
outside the window does not move the number. The project comes from the build
directory's name, after one optional `fly-`/`pool-` copy marker (the hub ingests
a relayed build as `fly-<project>-<KEY>-<stamp>`, and `bin/project-of.sh`
strips `pool-` for the same reason); the longest registered project name wins, so
`sib-nav` never rows under `sib`. A build directory that matches no registered
project is counted in `sources.builds_pipeline_logs.unattributed_builds` and its
minutes land in the fleet total only — a row would have to invent an owner.
**A full run and a selected run both count, on purpose:** the metric is minutes
spent, not suites run, so the win from per-diff test selection (#483) shows up as
this number falling rather than as a second metric to reconcile against it.

**Weekly caps — `state/quota/<account>.json`** (`bin/quota-poll.sh` writes them;
`bin/quota-status.sh` renders the same files interactively). Each account's
weekly `pct` and the instant it resets. An account whose poll errored reports
`null`, never 0, and the message names it under "caps unreadable" — an account
that cannot self-report is a blind spot, not an idle account.

**Cash overage — `logs/extra-usage-<account>.csv`.** The newest row for the
absolute figures, and `window_delta_usd` as a difference of two meter reads: the
last sample BEFORE the window opened against the newest one. With no earlier
sample the basis says `PARTIAL`. `last_sample_at` is how you spot a stale meter:
if it is hours behind the window, the absolute figures are as old as it says —
`bin/extra-usage-track.sh` is the lane that alerts on that, not this one.

## Two rules the whole thing is built on

**A missing source is `n/a (source X absent)`, never 0.** "Zero merges" and "we
cannot see the merges" are different facts about the fleet, and a digest that
renders them identically teaches its reader to distrust both. Every degradation
also appends a line to `notes[]`, naming the file.

**A rate divides by the denominator it names.** Conflict and rebuild rates are
counted off `logs/merge-conductor.log`, so they divide by THAT log's merge count
— which is usually a little below the ledger's headline, because the two cover
slightly different sets of PRs. Mixing them inside one ratio would be two
measurements wearing one name. Each rate carries `denominator` and
`denominator_source`.

## The one thing that pages

If the ledger route AND `logs/merge-conductor.log` are both unreadable, the
digest cannot measure the fleet's output at all. It still writes its files (all
`n/a`), and it appends ONE line to `logs/ALERTS.log`, once a day, naming what is
needed. Without that line, an unmeasurable fleet and a quiet day look the same
(`docs/LESSONS.md`, "stopping is an alert, not a whisper").

**GitHub REST budget — `bin/gh-budget-report.sh`** (BH-6974), which reads the
fleet's `gh_ledger` table through `GET /api/metrics/gh-ledger?group=` (this
box's `state/gh-rest-ledger/` files when the worker does not answer). The
digest runs it once with its own merge count (`--merged`), so the dora route is
still read once. One line before `sources:`: `github REST: <calls> calls,
<charged> charged, <n>/merged PR; top pollers: <lane> <class> <charged> | …`
(5 pollers). The payload key `gh_budget` carries the same numbers, and its
`status` is `ok`, `off` (knob) or `error` (the report failed: one
`dora-digest.log` line, the text says `github REST: n/a (error)`, no page).
The full report is `state/gh-budget/<date>.json`.

## Conflicts block (BH-6965)

`repos[].conflicts` and `fleet.conflicts` in `state/dora/<date>.json`, parsed by
`bin/dora_conflicts.py` from four files. Each figure is `null` with
`unavailable.<figure> = "n/a (source X absent)"` when its file is absent.
`fleet.conflicts.source` names the source of each figure.

| figure | source | how to re-derive it by hand |
| --- | --- | --- |
| `dirty_events` | `logs/merge-conductor.log` | count the in-window lines `<slug>#<n> <prev> -> NEEDS_REBASE`. These are EVENTS: a PR that goes DIRTY twice counts 2. `conflict.dirty_prs` stays the DISTINCT count. |
| `rebuilds`, `merges`, `rebuilds_per_100` | `logs/blocked-resolver.log`, `logs/merge-conductor.log` | `REBUILD FRESH` park lines x 100 / DISTINCT `MERGED <slug>#<n> by` PRs, 1 place. The same numerator and denominator as `rebuild.rate`. No merges in the window: `null`, text `n/a`. |
| `fix_round_conflict` `{ok, failed}` | `state/blocked-resolver/<project>/<key>.json` | `attempts[]` whose `at` is in the window and whose `detail` carries ` · fix-round-conflict ok` or ` · fix-round-conflict failed` (the BH-6964 writer). A record file older than the window start is skipped unread (`sources.resolver_records.files_skipped_stale`). |
| `dirty_to_clean_min` `{p50, p90, n, open}` | `logs/merge-conductor.log`, `logs/repair-on-push.log` | One episode per PR. It opens at a `-> NEEDS_REBASE` transition or a `REPAIR pr=<n> ... action=rebase reason=conflict` line. It closes at the first later transition whose new state is not `NEEDS_REBASE` and whose `merge=` is `CLEAN`, `UNSTABLE`, `BLOCKED`, `HAS_HOOKS` or `BEHIND`, at `MERGED <slug>#<n> by`, or at `REPAIR pr=<n> ... action=rebase reason=pushed`. Only episodes that open and close in the window are in `n`; one still open at the end counts in `open`. Nearest rank: `sorted[ceil(p*n)-1]`, minutes. |
| `repair_wakes` | `logs/repair-on-push.log` | DISTINCT `wake=<id>` on `REPAIR` and `wake=<id> repo=<slug> range=` lines, minus wakes whose last in-window line is `wake=<id> left for next tick`. A project gets a wake through its repo slug (lowercased) in fleet.conf; an unowned repo counts in the fleet total only. |

Text: one `conflicts (fleet): dirty <n>, rebuilds <r>/100 merges (<rebuilds> of
<merges>), fix-round-conflict ok <n> failed <n>, dirty->clean p50 <m>m p90 <m>m
(n=<n>, <n> open), repair wakes <n>` line, then one `conflicts <project>: ...`
line for each shown repo row with conflict activity.

**The alert.** When a project's rebuilds per 100 merges over the TRAILING 24 h
(always 24 h, whatever `--window` is) is strictly over the threshold, the digest
appends ONE `[dora-conflicts]` line to `logs/ALERTS.log` through
`bin/alert-line.sh --id dora-conflicts` (one console row, also on a
`--no-send` run). The line names every
project over the threshold. It is written at most once a UTC day
(`flags/alerted-dora-conflicts-<YYYYMMDD>`). Equal is not over, and a project
with no merges is never over. The threshold is the settings row
`conflicts.rebuild_alert_per_100`, then `DORA_CONFLICTS_REBUILD_ALERT_PER_100`,
then 40. The row is read only when a settings client is loaded (the ledger read
loads `bin/jobs-client.sh`). `fleet.conflicts.alert_threshold`,
`alert_threshold_source` (`row`, `env` or `default`) and `alert` (the trailing
24 h figures, the projects over and the exact line) record the decision.

## Config

Every threshold is a config value. Environment first, then
`flags/dora-digest.conf` as `KEY=VALUE` lines — env and the command line always
win, so `--window 7d` is never overridden by a file. The conf file is PARSED,
never sourced: only `DORA_*`/`QUOTA_DIR` keys with a plain value are honoured, so
config cannot become a second entry point into the lane.

| knob | default | what it does |
| --- | --- | --- |
| `DORA_WINDOW` | `24h` | trailing window, `<n>h` or `<n>d`. Anything else is refused, not guessed. |
| `DORA_SEND` | `1` | `0` writes the files and posts no beat (`--no-send`). |
| `DORA_LEDGER` | `1` | `0` skips the worker read and uses the conductor log. |
| `DORA_QUOTA_WARN_PCT` | `80` | weekly % at which an account is marked `HOT`. |
| `DORA_MAX_ROWS` | `12` | repo lines in the message. The json is never trimmed. |
| `DORA_TEXT_MAX_CHARS` | `3500` | beat truncation. `latest.txt` is always complete. |
| `DORA_OUT_DIR` | `$HARNESS/state/dora` | where both outputs land. |
| `DORA_BUILDS_DIR` | `$HARNESS/builds` | where `builds/<dir>/pipeline.log` is read for box test minutes. An absent directory is `n/a`, never 0. |
| `QUOTA_DIR` | `$HARNESS/state/quota` | the same variable `bin/quota-status.sh` reads. |
| `DORA_GH_BUDGET` | `1` | any other value skips `bin/gh-budget-report.sh` and the `github REST:` line. |
| `DORA_CONFLICTS_REBUILD_ALERT_PER_100` | `40` | the conflicts alert threshold, read after the settings row `conflicts.rebuild_alert_per_100` (BH-6965). |

Kill switch: `flags/dora-digest-off`.

## Tests

`tests/dora-digest-test.sh` — 191 assertions, no network and no secrets. Fixture
slices of all seven sources with hand-checkable expected values, plus the cases
whose failure would be silent: the window filter in both directions (a 5-day-old
row and a 10-day-old row, against 24h and 7d), distinct counting where it is
claimed, a rate keeping its own denominator while the ledger reports a higher
merge count, a cost csv whose columns are in a different order from production's,
suite minutes read from `builds/` with the window, the `fly-`/`pool-` copy marker
and the missing directory, a box with no sources at all, and the ledger down with
the logs up.

## Known gaps

* **Lead time needs the ledger.** Nothing else this fleet writes carries the
  instant a ticket was claimed in a form joinable to the PR that closed it, so
  with the worker unreachable lead time is `n/a` rather than approximated from a
  build directory's mtime. Approximating it would move the one number a reader
  would act on, so it is left absent.
* **Rows are keyed on the project, not the repo.** `fleet.conf` maps one repo to
  each project, and every source but the conductor log is project-keyed. A repo
  that merged something and is in no registry rows under its own slug rather
  than vanishing; a project that ever owns two repos would need the ledger to
  report per-repo lead time before this could split them.
* **Deployment frequency is not here.** `computeDora` already reports verified
  production departures (`bin/deploy-train.sh`'s `deploy` ledger rows) and the
  digest carries the lead-time basis that names them, but a deploy-frequency line
  belongs beside the deploy train's own reporting rather than in this message.
