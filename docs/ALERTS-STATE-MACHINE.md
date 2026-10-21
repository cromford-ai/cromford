# The alert state machine — fire once, resolve once, route by severity

> Implementation: `bin/lib/alert-state.sh` (the rule), `bin/lane-alert.sh` (the
> writer side), `bin/beat.sh` (the chokepoint every other emitter already goes
> through), `bin/alert-digest.sh --warn-batch` (the delivery half of `warn`).
> Config template: `env-templates/alerts.conf.example`. Tests:
> `tests/alert-state-machine-test.sh`.

## The problem this exists for

the operator reads the alerts Telegram topic on his phone. One 24-hour window
(2026-09-15) delivered:

| lines | what they were | why the emitter's own dedupe failed |
|---|---|---|
| 68 | `EXTRA-USAGE … account entered overage` | the marker was keyed `overage:$RESETS`, and `resets_at` comes back with **microseconds** that move on every poll — `04:00:00.049571`, then `04:00:00.322755`. The grep never matched the marker it had just written, so "once per weekly window" fired every 15 minutes. |
| ~35 | `[pipeline-health] RESOLVED <key> — condition no longer holds` | the retraction epilogue emits whether or not anything was ever announced as open, so a flapping condition retracts over and over. |
| 10 | `[jobs-watchdog] SILENT job: …` | ten rows naming ten tickets, one dead lane. Each row is its own alert. |
| 5 | `RUNNER LANE DOWN: … on project-10 box` | that box has been parked since 2026-08-25. Its four canaries fail on purpose, every 6h, forever. |

Four emitters, four hand-rolled dedupe schemes, four different bugs. The lesson
is not "fix the four markers" — it is that **dedupe is not the emitter's job**.
An alert is a CONDITION with a lifecycle (it starts, it persists, it ends), and
until now the fleet had nowhere to keep that.

## The model

One id per condition, one state file, five decisions.

```
                 ┌── first sighting ──────────────────► FIRE     (sent)
  alert ─ id ────┤
                 ├── open, < ALERT_REMINDER_S ────────► SUPPRESS (counted, logged)
                 ├── open, ≥ ALERT_REMINDER_S ────────► REMIND   (sent, "still firing, n=…")
                 └── --resolve on an open id ─────────► RESOLVE  (sent, once)
                     --resolve on closed/unknown ─────► SILENT   (nothing)
```

State lives in `state/alerts/<id>.json`:

```json
{"first_seen":1789489384,"last_seen":1789491120,"last_notified":1789489384,
 "count":7,"severity":"critical","resolved_at":null,"line":"…"}
```

With `flags/alerts-db` on, the `alerts` row in the jobs worker is the store the
decision is made on, and this file is a write-through cache and the outage
fallback (BH-1070 for the writer, BH-7802 for the readers):

| Reader | Reads | When the worker does not answer |
|---|---|---|
| `alert_state_note` | `POST /api/alerts/note` decides fire/remind/suppress | the file |
| `alert_state_resolve` | `alert_resolve_rows`: `POST /api/alerts/resolve` answers `rows` (id, count, severity, first_seen) of the rows it closed | the file; an older worker with no `rows` key (`#norows`) reads count and severity from the file |
| `alert_state_age` | `alert_row`: `GET /api/alerts?id=<id>`, column `first_seen` | the file |
| `alert_state_open` (tz-check, disk-guard) | `alert_row`: open is any state but `resolved`; no row is closed | the file (`--file-exists`: any file is open, disk-guard's rule) |

The console's `/alerts` FLEET ROWS shows the same rows. With the flag off, no
reader makes a request.

`ALERTS.log` stays **append-only and byte-compatible**: the line shape is
unchanged, and every grep-based reader (`poll-commands.sh`'s cursor,
`heartbeat-reaper.sh`, the console) keeps working. This layer only ever writes
*fewer* lines to it, never different ones. Suppressed repeats are journaled to
`logs/alerts-state.log` instead — 68 suppressed repeats in the alert record
would be the same wall of text one file over.

### Where the id comes from

1. **`--id <key>`** (or `alertid` on a beat payload) — the emitter naming the
   thing it is watching. Always preferred.
2. **a `collapse <ERE> <id-template>` rule** from `flags/alerts.conf` — for an
   emitter whose text is finer-grained than the problem, and which this lane may
   not edit.
3. **`row_key(line)`** from `bin/alert_family.py` — the fleet's one
   normalisation rule, shared with the triage lane and `poll-commands.sh`. This
   is what collapses a repeat from a script nobody has retrofitted.

`row_key`, not `family`: `family()` folds every digit run, so `TK-1` and `TK-99`
share a signature. That is right for magnitudes and catastrophic for identities,
and this key decides whether a condition gets its own page.

A UTC timestamp at the head of the line is stripped **before** hashing. Two
paths carry the same condition to the console — the emitter's own `fleet_alert`
beat, and `poll-commands.sh` re-beating the new `ALERTS.log` line as
`kind:"alert"` with the log stamp on the front — and without the strip they hash
apart and every alert pages twice. For the same reason `lane-alert.sh` records a
text→id **alias** when it fires with an explicit `--id`, so the second arrival
lands on the same condition.

### Severity routing

| level | where it goes |
|---|---|
| `critical` | Telegram/console immediately, and the `--critical` DM path when the orchestrator monitor is off |
| `warn` | spooled to `state/alert-warn-batch.jsonl`, delivered folded into one message by `bin/alert-digest.sh --warn-batch` |
| `info` | `ALERTS.log` and `logs/alerts-state.log` only — never leaves the box |

The two self-heal notices, `context-gate` BUILD RESTARTED and `review-rescue` rescued APPROVE, emit `info` through `bin/lib/self-heal.sh`, and the daily digest's `Self-healed:` line counts them from the `self_heal` ledger.

The default for a caller that declares none is **`critical`**, on purpose:
routing is opt-in, so an emitter nobody has retrofitted keeps paging exactly as
it does today and only gains the dedupe. Move a class down deliberately, with a
`severity <ERE> <level>` rule.

`warn` is drained on a cadence: EVERY box runs `bin/alert-warn-flush.sh` (which
runs `bin/alert-digest.sh --warn-batch`) every 30 minutes (lane `alert-warn-flush`, `cron/lanes/665-alert-warn-flush.cron`,
not lease-gated), because a warn spools on the box that raised it and each box
drains only its own spool. An empty spool sends nothing. Each batch's akey is
`warnbatch:<box>:<YYYYmmddHHMMSS>:<pid>` and its message names the box: every
box's flush fires in the same second, so the box is what keeps two boxes'
batches from sharing a console dedup key (the second would be swallowed
silently), and seconds + pid keep two batches on one box apart.

**The off-switch stops BOTH drains.** `flags/lane-off-alert-warn-flush` (or
`flags/all-off`) gates `--warn-batch` itself, and the inline dead-man below runs
that same command, so while it is set the box delivers no `warn` at all: the
spool keeps growing and silently trims oldest-first at `ALERT_WARN_BATCH_MAX`
(60). Nothing is sent and nothing past the cap survives until the switch is
cleared; the next tick then delivers what is left
(`tests/alert-warn-batch-cron-test.sh` W9). The spool also carries its own dead-man: once the spool's oldest entry is
older than `ALERT_WARN_BATCH_MAX_AGE_S` the next `warn` flushes the batch
inline. Both paths drain under the spool's one flock, so they never send the
same warn twice (`tests/alert-warn-batch-cron-test.sh`). Nothing waits silently.

### Parked boxes

A box under `flags/paused-<box>`, or named by a `parked <box>` line in
`flags/alerts.conf`, is deliberately not running. Any line matching
`ALERT_PARK_DOWNGRADE_RE` (`LANE DOWN|AUTH DOWN|LANE SILENT|watcher
stale|UNREACHABLE|CANARY FAILED`) that names such a box is downgraded to `info`.

This is a **downgrade only**. It can never raise a severity, it never touches a
box that is in service, and the `ALERT_PARK_DOWNGRADE_RE` guard is what stops a
parked box's name appearing inside an unrelated alert (a cost rollup, say) from
muting it.

## Using it

```bash
# fire — same id while open counts instead of paging
bin/lane-alert.sh --id extra-usage-overage-project-6 --severity critical \
  extra-usage "account is in overage, meter \$26144.47"

# resolve — exactly one send, silent if nothing was open
bin/lane-alert.sh --resolve --id extra-usage-overage-project-6 \
  extra-usage "out of overage, back on subscription credits"
```

Because a resolve for a condition that was never firing is silent, **call it on
the healthy path unconditionally**. That is the point: no emitter needs an "am I
currently alerting?" flag of its own, and that class of bookkeeping is what put
68 lines in the log.

From a beat, the same two fields do the same job:

```bash
bin/beat.sh "$(jq -nc --arg akey "lanedown:$ID:$(date -u +%Y%m%d)" --arg id "lanedown-$ID" \
  --arg l "RUNNER LANE DOWN: …" \
  '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,severity:"warn",line:$l}')"
```

A beat carrying `alertstate` has already been through the machine (`lane-alert.sh`
put it there) and is not counted twice — only the severity routing still applies.
`"triaged":true` beats are exempt entirely: those are conclusions addressed to a
human (the medic's escalation, whose akey is its permanent address; alert-triage's;
the digest's own), already deduped by the console on that key, and a second dedupe
here could only swallow them.

## Config

`flags/alerts.conf` is machine-local (`flags/` is gitignored and is not one of
the directories `bin/harness-sync.sh` rsyncs, same as `flags/cost-caps.conf`).
`env-templates/alerts.conf.example` is the documented copy:

```bash
cp env-templates/alerts.conf.example /root/harness/flags/alerts.conf
```

The file is **parsed, not sourced** — it carries rule tables as well as scalars,
and a config file that can execute is a config file that can be an exploit. Five
directives, precedence `environment > conf > code default`. Since BH-2411 a `set`
scalar also reads the settings row `conf.alerts.<name lowercased>[.<box>]` between
the environment and the conf (never when `ALERTS_CONF` is set); the rule tables
and `parked` lists are file-only. A row `_as_cfg_ok` refuses (a `*_ENABLED` or
`ALERT_BUILTIN_RULES` that is not `0`/`1`, a `*_S`/`*_MAX` that is not a whole number, a
severity that is not `info`/`warn`/`critical`, a `*_RE` that does not compile) falls through to
the conf, not the code default, and `logs/lane-gate.log` names it once an hour (BH-2478).
A row may tune alerting but never gut it (V1, the #2291 allow-list, `_as_row_ok`):
`ALERT_BUILTIN_RULES`, `ALERTS_PR_SUBJECT_RE` and `ALERTS_SWEEP_AUTH_PROSE_RE` (the
regexes that decide what the groomer and the sweep close) are never read from a
row at any value, and an
`ALERT_DEFAULT_SEVERITY` row of `info` is refused; both stay settable from the
environment and the conf. The kill switch and `*_RE` rows keep BH-2411's contract:

| directive | meaning |
|---|---|
| `set <NAME> <value>` | a scalar |
| `collapse <ERE> <id>` | lines matching `<ERE>` share `<id>`; `\1..\9` are its capture groups |
| `severity <ERE> <level>` | lines matching `<ERE>` are `info` / `warn` / `critical` |
| `parked <box-token>` | a box deliberately not running |
| `logonly <ERE> log` | lines matching `<ERE>` are notices: ALERTS.log only, never noted or sent (BH-2337) |

| scalar | default | what it does |
|---|---|---|
| `ALERT_STATE_ENABLED` | `1` | `0` restores the pre-2026-09-15 behaviour exactly |
| `ALERT_DEFAULT_SEVERITY` | `critical` | severity for a caller that declares none |
| `ALERT_REMINDER_S` | `21600` | one "still firing" send per open condition per this |
| `ALERT_AUTO_CLOSE_S` | `21600` | a condition nobody resolved is treated as ended after this quiet |
| `ALERT_STATE_RETENTION_S` | `604800` | how long closed/idle state files are kept |
| `ALERT_WARN_BATCH_MAX` | `60` | warn spool ceiling, oldest dropped first |
| `ALERT_WARN_BATCH_MAX_AGE_S` | `5400` | dead-man: flush the spool inline past this age |
| `ALERT_PARK_DOWNGRADE_RE` | see above | which lines the parked downgrade may look at |
| `ALERT_BUILTIN_RULES` | `1` | `0` drops the `collapse`/`severity`/`logonly` rules that ship in the library |

The shipped `collapse`, `severity` and `logonly` rules **live in code**, in
`bin/lib/alert-state.sh`. They cover `bin/jobs-watchdog.sh`,
`bin/pipeline-health.sh`, the canaries' own ALERTS.log lines and the notices
below —
and they are defaults rather than conf lines on purpose: `flags/` is not one of
the directories `harness-sync.sh` rsyncs, so a rule that lives only in the
template takes effect on exactly the boxes where somebody remembered to copy a
file. A conf rule is matched first and wins.

## Notices are not alerts (BH-2337)

On 2026-09-25, 180 of 377 open fleet alerts were success or recovery notices.
A notice keeps its ALERTS.log line (the audit record) and opens no row, on both
paths a line can take to the table:

- the producer's own call: `bin/lane-alert.sh --log-only` writes the line and
  beats nothing (`--resolve --log-only` closes an open id as usual, and writes the
  plain line when nothing was open);
- `bin/poll-commands.sh`'s re-beat of the line: `bin/beat.sh` drops any
  non-retraction whose line matches a `logonly` rule, before it is noted.

The shipped `logonly` rules: fleet-propagate `N/N boxes synced` and its drain
line only when it says `N/N rebaked`, `HOTFIX seen`, `HOTFIX pr_open` and
`HOTFIX merged` (`hotfix_announce` beats none of the three; a hotfix failure
line such as `POST-DEPLOY APPLY FAILED` still pages), main-red `GREEN again`
(and its `RESOLVED:` line), the visibility canary's admin-covered line, and
`ghdefault-<slug> RECOVERED` as its full sentence only. main-red's RED, STILL
RED and GREEN all collapse onto `main-red-<slug>`, so the GREEN resolves
whichever of them opened the row, and a STILL RED while the RED is open is a
counted repeat of it (BH-2381). The GH-token visibility canary writes a
`gh_visibility` ledger row per repo and pages only a repo no token can see, once.

## V1 alert hygiene (2026-09-25)

The console held ~459 open alerts and the triage backlog 1,036 lines over 533
families, mostly noise. The measured causes, and where each one is fixed:

| cause | fix |
|---|---|
| `poll-commands.sh` keyed the console row `alert:<row_key>:<YYYYMMDD>`, so one unchanged condition opened a new row, and a new page, every UTC day | the akey is `alert:<condition id>` from `alert_state_key` (collapse rules, aliases, then `row_key`), no date. Repeats are this machine's job: `bin/beat.sh` puts its decision on the beat as `alertstate` (`fire` / `remind`; a suppressed repeat is never sent), and the console pings a still-open row on `fire`/`remind` (cromford-console `src/alert-ping.js`, **which must be deployed first**), so a persistent condition re-pages every `ALERT_REMINDER_S` **on the paths that deliver the beat itself** (see the limit below). The console also re-opens a resolved row when its akey fires again |
| the auth canary's ALERTS.log lines carry the probe's own words, so each probe hashed to a new condition | `collapse` rules map `AUTH PROBE INCONCLUSIVE`, `CLAUDE AUTH DOWN` and `MODEL POOL EXHAUSTED` onto the ids their beats declare (`authprobe-<box>`, `authdown-<box>`, `pooldry-<box>`); `DEFAULT GH TOKEN CANNOT SEE` already keys on `ghdefault-<owner>_<repo>` through main's BH-2337 rule |
| status events paged as critical alerts | `severity ... info` rules: `account <x> ran out ... no project hold ... requeued`, `pool build DEFERRED ... requeued attempt N`. `HOTFIX seen` / `pr_open` / `merged` are not V1's to route: they are main's `logonly` notices (BH-2337, BH-2381, above) and V1 does not change them. What still pages: the DEFERRED that FAILED the queue row, `POOL_DEFER_TO_HUMAN`, and every hotfix FAILURE line (`POST-DEPLOY APPLY FAILED`, `CLOSE-OUT OWED`) |
| `DEFAULT GH TOKEN CANNOT SEE` paged daily per repo while the admin token kept every lane working | main's BH-2337 `logonly` rule makes the admin-covered line a notice and its `collapse` rule keys the line on `ghdefault-<owner>_<repo>`; V1 adds nothing here. Still `critical` when nothing sees the repo |
| a retired project (project-10, parked 2026-08-25) had to be muted by a flag or a conf line on each box | `# @retired <project> [box]` in `fleet.conf`, read by `bin/fleet-conf.sh --retired`; its names downgrade DOWN/SILENT lines like the parked set above, but match WHOLE WORDS only (`gone` never matches `gonebox-staging`), and a directive naming a project or box that is still live in `fleet.conf` is ignored and logged `retired-conflict` |

**Limit: where the remind re-page holds, and where it does not.** The
`alertstate` stamp rides the beat that `bin/beat.sh` sends or queues, so a
persistent condition re-pages at `ALERT_REMINDER_S` when that beat reaches the
console itself: an `ALERTS.log` line re-beaten by `poll-commands.sh`
(`kind:"alert"`, never quarantined), a box with `flags/alert-quarantine-disabled`,
and a quarantined `fleet_alert` that `bin/alert-flush.sh` force-escalates from
the file after 45 minutes (the queued payload keeps its `alertstate`;
`tests/alert-hygiene.v1-test.sh` R14). It does **not** hold for a quarantined
`fleet_alert` that the alert-triage lane handles: triage drops a repeat it has
already judged, or escalates under its own `triage:<key>` akey without
`alertstate`, and the alerts-db claim path (`alert_flush_claim`) re-keys to
`orclane:<id>` without it. On those paths a still-open row does not re-page on
remind; it re-pages only when the row resolves (48h auto-stale or a resolve) and
the condition fires again. Carrying `alertstate` through alert-triage is a
follow-up, not part of V1.

**Status events are not deleted, only demoted.** Each line is still in
`ALERTS.log` and `logs/alerts-state.log` (`info-only id=...`). A box that wants
one back raises it with a `severity <ERE> critical` line in `flags/alerts.conf`,
which is matched before the shipped rules.

**The one-shot sweep.** `bin/alerts-hygiene-sweep.sh` resolves the rows that
were already open when this shipped. Dry run by default:

```bash
bin/alerts-hygiene-sweep.sh                 # counts, samples, "open after (projected)"
bin/alerts-hygiene-sweep.sh --check-prs     # also PR-subject rows whose PR is merged/closed (1 gh call per PR)
bin/alerts-hygiene-sweep.sh --apply         # resolve them (reason v1-<class>), then re-count
```

It resolves only rows it can classify: `retired`, `logonly` (a line `alert_state_logonly` now calls a notice, e.g. HOTFIX seen/pr_open/merged or the admin-covered GH-token line: `bin/beat.sh` drops those before they are noted, so an open row is a leftover; a hotfix failure line is never one), `auth-probe-prose` (a CLAUDE
AUTH DOWN / AUTH PROBE INCONCLUSIVE whose only evidence was the model's
MCP-plugin note, the 2026-09-23..25 false pages; `docs/AUTH-PROBE.md`; never for
a box still listed in `state/claude-auth-down.txt`, nor a row whose box it
cannot name),
`reclassified-info|warn`
(the line now routes below critical), `dup-dated` (a date-stamped akey that is
not the newest row of its condition; the newest stays open), and with
`--check-prs`, `pr-closed` (`mq-headbound` / `mq-tc` only on a close WITHOUT merge: a merge means unreviewed or failing code reached main). Everything else is left for a human. It is not on
cron; run it once on the hub.

**Known limit.** The console's `boards` table still holds a row for a project the
hub stopped pushing (project-10's is dated 2026-08-04), and the MCP
`fleet_status` lists every `boards` row. Dropping it is a console change
(filter `boards` by the snapshot's `projects`), outside this repo.

## One console row per condition (BH-4053)

One console row per condition. What the alert names (a PR set, a count) is
payload, never key: the console upserts on `akey` and refreshes the row's
line, so a row keyed on the condition shows the latest list in place.

- `bin/alert-line.sh --id <id>` beats `akey` = `alert:<sid>`, where `<sid>` is
  `<id>` folded the way `as_sanitize_id` folds it (`tr -c 'A-Za-z0-9_.-' '_'`,
  first 120 chars). `alertid` stays the raw `<id>`, so the state machine's id
  for an existing caller does not move. Without `--id` (or with `--id ""`) the
  akey is the derived `alert:auto-<row_key>` it always was.
- The fold exists because the alias reader keeps only `[A-Za-z0-9_.-]`. Before
  the beat, `alert-line.sh` writes `alert_state_alias <line> <sid>`, so when
  the `# >>> alerts re-beat` block of `bin/poll-commands.sh` re-notes that
  exact line (no marker: a failed beat, a tick-cap overflow) it mints the same
  `alert:<sid>`.
- `bin/pipeline-health.sh` `alert()` declares `ph-<key>` with the colon already
  folded (`stalepr:ts` → `ph-stalepr_ts`), so its `alertid`, its akey and the
  alias the `health:<key>` beat resolves through are one string. Past
  `ALERT_LINE_TICK_MAX` the plain append writes the same alias. Two projects
  are two keys and two rows.
- Rows opened before this under `alert:auto-*` are retired by
  `bin/alerts-supersede.py` (run by `bin/alerts-groom.sh`): an open
  `alert:auto-*` row is resolved, reason `superseded by <akey> (legacy auto
  key, BH-4053)`, when an open row with an explicit `alert:` akey has the same
  `shape()` (`bin/alert_family.py`: `family()` after dropping the stamp, a
  ` (still firing, n=N)` / ` [remediator tried: …]` tail, and folding a PR
  list `#N,#N…` to one `#N`). The explicit row is never resolved by that pass,
  and a legacy row never counts as its subject's newest row.

## Fail open

The noise filter is allowed to cost a duplicate page. It is never allowed to
cost a page. No library, no `jq`, no `python3`, no state directory, a lock we
could not take, an unparseable conf — every one of those paths answers `fire`.
Two kill switches restore the old behaviour exactly: `flags/alert-state-off`,
and `set ALERT_STATE_ENABLED 0`. Both are asserted in the test suite.

## What is retrofitted, and what is not

| emitter | id | severity |
|---|---|---|
| `bin/extra-usage-track.sh` overage | `extra-usage-overage-<account>` + resolve when it clears | critical |
| `bin/extra-usage-track.sh` cap | `extra-usage-cap-<account>` + resolve | critical (reminder = `EXTRA_USAGE_CAP_ALERT_DEDUPE_S`) |
| `bin/extra-usage-track.sh` day delta | `extra-usage-delta-<account>-<day>` | warn |
| `bin/extra-usage-track.sh` meter down | `extra-usage-meter-<account>` + resolve on a good poll | critical |
| `bin/claude-auth-check.sh` LANE DOWN | `lanedown-<box>-<lane>` + resolve on recovery | warn (info on a parked box) |
| `bin/pipeline-health.sh` | `ph-<key>` (the check's own dedupe key, folded to `[A-Za-z0-9_.-]`: `stalepr:ts` → `ph-stalepr_ts`), BH-4053 | a `severity` rule where the conf has one |
| `bin/jobs-watchdog.sh` SILENT | `collapse` rule per project/lane | owned by another lane — see the fold-ins on the PR |

An emitter that is not in this table is not worse off: it gets the derived id
and the default `critical` routing, which is today's behaviour plus fire-once.
