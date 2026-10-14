# The two alert readers now stand still on the conductor's own lines while it is paused

Doc: ALERTS-STATE-MACHINE

## What changed

Five files, three of them product code.

**`bin/alert-triage.sh`** — a guarded source of `bin/lib/conductor-mode.sh`
next to the existing `lane_env_apply` line, and a `# >>> conductor hold
(BH-1201)` block between STEP 0's `[ -s "$WORK" ] || exit 0` and `COUNT=$(wc -l
< "$WORK")`. When `conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD`
returns 0 the block partitions the tick's lines in one `python3` pass: a line
whose beat `.line` matches `\[(?:orchestrator/)?merge-conductor\]` goes to the
held file, everything else stays. The held file is appended to
`state/alert-triage-deferred.tsv` under the spool's own `.lock` flock, and only
if that append returns 0 does `$WORK` lose the lines.

**`bin/alerts-medic.sh`** — the same guarded source, and the same marker block
straight after the unseen filter's empty-queue exit, before `CANDIDATES` is
written. A candidate row whose line (everything after the first tab, so an id
can never match) carries the conductor tag is dropped from `NEW`. Every stamp
site in this lane — `alert_claim`, the family `fams[f] = now`, the `SEEN`
append — runs over what survives that filter, so a held row is left exactly as
it was found and the console and the alerts table re-offer it next pass.

**`worker/jobs/src/routes/lanes.js`** — one `SELECT key, value FROM settings
WHERE key IN ('merge-conductor.mode','merge-conductor.held_pages')` inside a
try/catch, and `mode` / `held_pages` spread onto the `merge-conductor` lane
object and no other. `held_pages` is the conductor's own summary string,
unparsed. A read that throws degrades to two nulls and one log line naming the
table; the page still renders, because an operator is on that screen precisely
when something is wrong.

**`catalog/lanes.d/alert-triage.json`, `catalog/lanes.d/alerts-medic.json`** —
the knobs `TRIAGE_CONDUCTOR_HOLD` and `MEDIC_CONDUCTOR_HOLD`, int, default 1,
0..1, `zero_means: off`. `catalog/lanes.json` is generated and was not hand
edited.

## Why

`bin/merge-conductor.sh` raises `fleet_alert` beats about its own pull requests.
Those beats land in the quarantine, and the next alert-triage tick buys a Fable
session to investigate `example-org/x#11 STUCK — 95m in WAIT_CI` — a wait the
conductor is already watching, and, once the conductor is in `kill-switch` or
`observe`, a wait somebody has deliberately stopped. That is a session spent on
a question with a known answer, and worse, it is a second lane forming an
opinion about a pull request the conductor owns.

## The rule

The source of truth is the D1 settings row `merge-conductor.mode`, read through
`bin/lib/conductor-mode.sh`, and **nothing else** — no flag file, no box-local
state. A box-local file would let two boxes disagree about whether the conductor
is holding with nothing anywhere saying so.

`unknown` HOLDS. An unreachable worker and the cold-start state before the
conductor child publishes its first row both answer `unknown`, and both hold.
That is fail-closed on SPEND: the cost of holding is one tick, the cost of not
holding is a session and a second writer on someone else's PR.

A hold is never a drop. Triage re-spools under the deferral spool's flock, which
is drained first on the next tick and aged out by STEP 0 into
`state/alert-triage-expired-<date>.tsv` with a reason column. The medic writes
nothing at all: the row stays `new`, its 900 s lease untouched.

The knob is the opt-out and it wins even under `kill-switch`, but only when it
is explicitly `0`. Empty, unset, or a lane whose knob is not registered reads as
on — a knob nobody wrote must not silently disable a hold.

## Negatives that are NOT held

`[merge-conductor-x] …`, `[orchestrator/merge-sweep] …`, `[blocked-resolver] …`,
a `[pipeline-health]` line that merely names the conductor, a beat whose `line`
is empty or missing, and an unparseable payload. All of them pass through and
buy their session exactly as before.

## What this does not do

Nothing here turns a lane on. Both lanes are OFF on the hub and stay OFF; the
hold is only observable once somebody enables one. `bin/alert_family.py`,
`bin/watchdog-responder.sh` (verified: it reads `state/stale-owed.json` and
`state/build-queue/*`, never ALERTS.log or the alerts table), `bin/lib/mc/*`,
`bin/merge-conductor.sh` and `bin/agent-call.sh` are untouched. Writing the
`merge-conductor.mode` and `merge-conductor.held_pages` rows belongs to the
conductor child; this change only reads them.

## Driven by

- `HARNESS_TEST_SANDBOX=1 bash tests/conductor-readers.bh-1201-test.sh` — the
  real `bin/alert-triage.sh` and `bin/alerts-medic.sh` end to end against a fake
  worker and a fake `agent-call.sh`, asserting on the spool, the family files,
  the recorded requests, `state/medic-seen.txt` and the lane logs.
- `cd worker/jobs && node --test test/lanes-status-conductor.bh-1201.test.js` —
  the real `GET /api/lanes/status` handler over a `node:sqlite` D1.
