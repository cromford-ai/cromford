# Ledger hygiene — heartbeat TTLs, silent auto-requeue, PR reconciliation

**Owner:** `bin/jobs-watchdog.sh` (hub cron, */5) · **Config:** `catalog/ledger-ttl.conf`
· **Output:** `state/ledger/hygiene.json` + one ALERTS line per tick per pass
· **Route:** `POST /api/jobs/:id/requeue` (worker/jobs) · **Tests:**
`tests/jobs-watchdog-ttl-test.sh`, `worker/jobs/test/requeue.test.js`

## The problem, measured

On the afternoon of 2026-09-15 the hub jobs ledger held **42 rows reading
`running`**. Nine had shown no sign of life for over an hour:

| rows | class | claimed | age when found |
|---|---|---|---|
| 8 | `triage` keyed `pr-968 … pr-976` (review/rescue) | 00:59Z | 916m |
| 1 | `triage` for project-3, ticketless | 2026-08-31 | 21,348m |

Not one of them was wrong under the rules the watchdog had. It carried exactly
two thresholds, and both look only at the **heartbeat**:

* `JOBS_ORPHAN_MIN` (10m) — a row that beat and then stopped is a corpse. Judge
  it against the retry policy, page once, release the claim.
* `JOBS_SILENT_MIN` (90m) — a row that **never** beat is *reported* and its
  status is deliberately **left alone**. Its age is a lower bound on inactivity,
  not proof of death, and releasing a claim on work that may still be running is
  how one ticket gets built twice.

The second rule is correct and stays. #358 landed the first exception to it: a
never-beating `pr-*` row past `PR_ROW_TTL_MIN` (360m) is closed as orphaned,
because a `pr-*` unit is one triage session and re-reading a PR costs ~$0.10.

What was still missing is everything else. **Every other class had no ceiling
at all** — the 21,348m project-3 row is `triage` with no ticket, so `jw_pr_row_reapable`
refuses it — and nothing re-offered any of these tickets: **a box only re-offers
a ticket on its own tick if the ticket is still visible on its board**, and a
claimed-then-abandoned key usually is not. Ten SILENT rows alerted in 24h and
every one of them just sat there.

### What this change adds, and what it leaves alone

**#358's `pr-*` reaper stays exactly as it is** and remains the backstop. This
change generalises its idea rather than replacing it:

* the single `PR_ROW_TTL_MIN` constant becomes one **row** of a per-class table
  (`ttl pr-*`, still 360m); the constant remains as the in-script fallback for a
  box whose checkout has no catalog file yet, so #358's behaviour is unchanged
  where the table is absent;
* its "age AND evidence" rule — `jw_pr_row_busy`, a row whose own per-key lock
  is still held on this box is never reaped — is applied to **every** class;
* rows the new passes settle are skipped by the main loop, so no row is ever
  judged twice in a tick.

Three passes close that, in this order, on one snapshot of the running rows.

---

## 1. PR reconciliation — a claim for work GitHub already finished

A `pr-*` row is a review or rescue claim keyed on the pull request itself. It
outlives its work in the one way nothing else in the watchdog can see: the PR
merges, the session that held the row is gone, **no beat stops and no queue row
ages**. The claim reads `running` forever.

The pass asks GitHub, with a minimal projection:

```
gh pr view <n> --repo <slug> --json state -q .state
```

| PR state | job status written | stage_event verdict |
|---|---|---|
| `MERGED` | `done` | `RECONCILED_MERGED` |
| `CLOSED` (unmerged) | `failed` | `RECONCILED_ABANDONED` |
| `OPEN`, or gh cannot answer | unchanged | — |

`CLOSED` is deliberately **not** `done`. A ledger that files an abandoned PR as a
finished one is the same lie as one that leaves a merged PR in flight, pointing
the other way.

### `pr_closed` — the vocabulary for a closed-unmerged PR (BH-866)

`pr_closed` is the word for a PR that was closed WITHOUT being merged, and it is
a terminal in its own right — not a flavour of `pr_merged`. The distinction is a
merge fact, never a state name: `state == CLOSED` is true of every merged PR as
well, so `mergedAt` (gh's `MERGED`) is the only thing that says a merge
happened. `bin/reconcile-prs.sh` classifies that way and reports a
closed-unmerged row to the console under `closed`, with no ship beat and no
deploy gate — nothing shipped.

In the **jobs ledger** it is kind `merge`, status `closed`, keyed on the PR url:
the same row `bin/merge-sweep.sh:655` already writes, deliberately, rather than a
new kind. Every existing reader already understands it —
`closeout_terminal` (`bin/lib/closeout-terminal.sh:57`) reads it as superseded,
`bin/pipeline-health.sh` checks 4/5 stop paging for it, `bin/pr-owner-sweep.sh`
never counts it as owned, and `bin/lib/ticket-identity.sh` reads it as "that
build's PR is over, the ticket is launchable again". A new kind would be
invisible to all four.

Full lane: [docs/verification-map/pr-reconcile-terminal.md](verification-map/pr-reconcile-terminal.md).

* The repo slug comes from `bin/fleet-conf.sh <project> repo`. Token selection
  goes through `bin/lib/gh-repo-token.sh`, so `project-5` and `project-7` — both
  invisible to the hub's default PAT — are read with `GH_ADMIN_TOKEN`, and a repo
  **no** token can see raises that library's one-per-day alert instead of
  answering an empty string nobody logs.
* This is the only part of the sweep that spends GitHub calls, so it runs
  **every Nth tick** (`set reconcile_every`, default 6 ≈ every 30 min) and is
  bounded per pass (`set reconcile_max`, default 40). Whatever it does not reach
  this pass, it reaches the next one.
* Only **PR-keyed** rows cost a call. A ticket key (`TK-1151`) is not a PR
  number and is never looked up.
* It reads **two** statuses: `running`, and `queued_for_retry` — rows pass 3 put
  back on the queue. A queued row is picked up by the lane's own next claim of
  that key, but if the key has gone (the PR merged, so the shard list no longer
  carries it) nothing ever claims it again and the row sits there for ever. The
  requeue would then have moved a stuck row from one status to another. The TTL
  pass deliberately does **not** see that feed: a queued row is not a claim on
  anything, so there is nothing to convict.

## 2. TTL reap — a row past the longest its class has honestly taken

A TTL convicts on a different fact from a heartbeat: *this row has outlived the
longest anything in its class has ever taken*, so it is dead whatever its
heartbeat never said. Past its TTL a row is marked `orphaned`, its open phase is
closed with it, and a `TTL_ORPHANED` stage event records the arithmetic.

**Class resolution, first hit wins** (`ttl_for` / `class_of`):

1. `pr-*` — when the row's ticket key starts with `pr-`
2. `<kind>/<stage>` — e.g. `build/execute`
3. `<stage>` — e.g. `execute`
4. `<kind>` — e.g. `triage`
5. `default`

**The numbers, and which evidence binds.** Two sources, and the smaller one
never decides. What a stage has been *observed* to take is a lower bound on what
it *may* take; what the harness will **let** it take is the real ceiling, and a
row is legitimately `running` right up to it. Setting a TTL from observation
alone is how a sweep reaps live work — the triage p90 is 4 minutes and a triage
shard is allowed 180.

Enforced ceilings (the `timeout` each lane hands `bin/agent-call.sh`):

| stage | seconds | minutes | where |
|---|---|---|---|
| triage | 10800 | 180 | `bin/lib/rt/launch.sh` (`bin/agent-call.sh" triage`), `triage_shard_timeout` |
| preplan | 1200 | 20 | `bin/run-preplan.sh:86` |
| plan | 1200 | 20 | `bin/run-build.sh:1039` |
| execute | 7200 | 120 | `bin/run-build.sh:1589` (`EXECUTE_TIMEOUT_SECS`) |
| review | 1200 | 20 | `bin/run-build.sh:2313`; 2400 standalone, 2100 rescue |
| fix | 4800 | 80 | `bin/run-build.sh:2407` |
| qa | 1800 | 30 | `bin/run-build.sh:2989` |
| prodqa | 1500 | 25 | `bin/postmerge-qa.sh:218` |

Observed durations, measured 2026-09-15 against the live hub ledger: 723
terminal rows (`done`/`failed`/`orphaned`/`parked`/`budget_stopped`),
`created_at` → `updated_at`. A job row spans its **whole** pipeline, so a build
row's honest life is the sum of its stages plus its fix rounds — which is why
the build classes sit far above any single ceiling above.

| class | n | p50 | p90 | max | TTL | reason |
|---|---|---|---|---|---|---|
| `triage` | 456 | 2m | 4m | 20m | **360m** | 2× the 180m ceiling |
| `pr-*` | 28 | 3m | 6m | 8m | **360m** | #358's number, kept |
| `preplan` | — | — | — | — | **120m** | 6× the 20m ceiling |
| `plan` | 53 | 3m | 15m | 284m | **180m** | the 284m is real |
| `execute` | 86 | 45m | 85m | 139m | **360m** | 3× max, 3× ceiling |
| `review` (stage) | 65 | 58m | 99m | 231m | **720m** | review + fix rounds |
| `fix` | — | — | — | — | **720m** | same pipeline |
| `decompose` | 26 | 14m | 21m | 46m | **180m** | |
| `qa` | 3 | 36m | 46m | 46m | **360m** | qa + a fix round |
| `review/review` (kind) | 10 | 3m | 25m | 25m | **120m** | one standalone PR read |
| `prodqa` | 7 | 0m | 4m | 4m | **120m** | |
| `migration/apply` | 10 | 0m | 0m | 0m | **60m** | |
| `merge` | 3 | 0m | 3m | 3m | **60m** | |
| `default` | — | — | — | — | **1440m** | a class nobody sized is reported, not convicted |

The cost is asymmetric in the direction the queue-claim release already
documents: convicting early releases a claim on work that is still running,
convicting late only delays a row nobody is working. **Widen a class rather than
shave it.**

**Age AND evidence.** Past its TTL a row is still kept when `jw_pr_row_busy`
says its per-key lock is held by a live process on **this** box — the only box
whose locks the hub can read. A row claimed elsewhere leans on the TTL alone,
which is what the TTL is for.

**What the TTL does not touch.** A row that *was* beating and is past
`JOBS_ORPHAN_MIN` belongs to the heartbeat pass, which asks the retry policy for
a verdict. Taking it here would spend a policy's attempts on a TTL's opinion.
The TTL reaches a beating row only when an operator sets a class TTL *shorter*
than `ORPHAN_MIN` — a deliberate choice, and honoured.

**One alert per tick, listing every row.** Eight rows died together at 00:59Z.
Eight identical alert lines is how a channel stops being read.

## 3. Silent auto-requeue — handing the ticket back

Marking a triage row orphaned frees nothing on its own; the ticket is still not
re-offered. So a reaped row in a requeue-eligible class is handed back to the
queue — and **the DB decides that, not the script**, the same split as
`job_retry_judge`. `POST /api/jobs/:id/requeue` answers exactly one of:

| decision | meaning |
|---|---|
| `queued_for_retry` | requeued; the **lane's own next tick** takes it over |
| `parked` | the requeue cap ran out; `bin/blocked-resolver.sh` owns it now |

The cap counts **deaths, not ticks**: a requeued row leaves the `running` feed,
so the TTL pass cannot see it again until a lane has actually claimed it and it
has died a second time. Three requeues therefore means three real failures, not
three sweeps.
| `held` | deliberately not requeued — see below |
| `already` | the row is no longer running; nothing was written |

Two things are `held`, and both are the double-build guard applied to this
sweep:

* **a ticketless lane tick** — `bin/run-triage.sh` opens a fresh row every ten
  minutes, so requeuing one puts a second claim on a lane that has one;
* **a ticket that already has another live row** — requeuing that is a second
  attempt on work with an owner, and the row being revived is the stale one.

**The attempt counter is the ledger's own history**: the number of `REQUEUED`
stage events already on the job, counted server-side. Not a column (schema.sql
is applied by hand and is never touched from a build lane), not a file on the
hub (a rebuild forgets it, and a rebuild is exactly when a lane is sickest). The
cap is `set requeue_max` (default 3): three requeues is no longer a flaky tick,
it is a ticket the lane cannot pick up, which is a human-shaped problem.

**Which classes are eligible** is `set requeue_classes` (default
`triage preplan pr-*`). A **build** row is not, on purpose: its queue row is
`bin/fly-pool.sh`'s to re-offer, and two things re-offering one build is a
double build.

---

### The NEEDS sweep applies by default (BH-9556)

`bin/needs-sweep.sh` closes the console build rows that ask for a person but
are over (BH-9117). Since BH-9556 it applies by default: the seed row
`console.needs.sweep_dry_run` moves from 1 to 0 on the jobs worker's first
settings read, and a missing row is 0. The row `1` is the kill flag (dry run).
A settings outage is exit 4 with one `needs-sweep-settings` alert, never a dry
run. See docs/CUSTODY.md "Lanes that act (BH-9556)".

## Config

`catalog/ledger-ttl.conf` is the fleet's answer, reviewed and committed, and
reaches every box on harness-sync — same reasoning as `catalog/size-thresholds.conf`
and `fly/pool-caps.conf`.

```
ttl <class> <minutes>     a class's time-to-live
set <knob>  <value>       requeue_max | requeue_classes | reconcile_every | reconcile_max
```

Resolution, first file wins **per key**:

1. `LEDGER_TTL_CONF` (env; tests point it at a fixture). When it is set, no
   settings row is read.
2. the settings rows `conf.ledger-ttl.ttl.<class>` / `conf.ledger-ttl.set.<knob>`
   (box row `….<box>` first; BH-2411). A class writes `/` as `.` and `*` as a
   trailing `_`: `review/review` is `ttl.review.review`, `pr-*` is `ttl.pr-_`.
3. `flags/ledger-ttl.conf` on the box — the emergency lever that needs no
   deploy. It overrides row by row; the rest of the shipped table still applies.
4. `catalog/ledger-ttl.conf` — the committed table
5. the in-script `1440` default, plus `JOBS_REQUEUE_MAX` / `JOBS_REQUEUE_CLASSES` /
   `JOBS_RECONCILE_EVERY` / `JOBS_RECONCILE_MAX` in `env/global.env`, which
   override the file for a single box

Unknown verbs are ignored, so a newer config file on an older box degrades
rather than breaking. A box with **no** table at all convicts nothing under
1440m — a full day, past anything in the 723-row sample (longest: 284m) — and
falls back to #358's own 360m for the `pr-*` class alone.

## Output: `state/ledger/hygiene.json`

Written **every** tick, quiet ones included — a file that only appears when
something is wrong cannot answer "is the ledger clean right now", which is the
question a console tile actually asks. Both this file and the tick's alert are
folded from the same per-row tally, so the two can never disagree.

```json
{
  "as_of": "2026-09-15 16:05:00Z",
  "tick": 12,
  "reconciled_this_tick": true,
  "scanned": 9,
  "thresholds": { "orphan_min": 10, "silent_min": 90, "requeue_max": 3, "reconcile_every": 6 },
  "by_class": {
    "pr-*":    { "ttl_min": 360, "ttl_orphaned": 2, "requeued": 2 },
    "execute": { "ttl_min": 360, "ttl_orphaned": 1 }
  },
  "totals": { "ttl_orphaned": 3, "requeued": 2 }
}
```

Outcome keys: `ttl_orphaned`, `requeued`, `requeue_parked`, `requeue_held`,
`reconciled_merged`, `reconciled_abandoned`.

## What this sweep never does

Everything the watchdog's own header says, unchanged: **it executes nothing.**
It writes statuses and records verdicts. A requeued row is picked up by the
lane's own cron tick through the same claim path as any other work, which is
what keeps ONE place where work can start. The tests assert both halves — no
work script on PATH is ever invoked, and no `POST /api/jobs` claim is ever
opened.
