# DB-driven coordination — spec (approved by the operator 2026-08-27, voice)

Goal: coordination state (jobs, stages, budgets, spend) lives in ONE database
on Cloudflare, not in scattered per-box files. Hub and every builder box (incl.
ephemeral fly builders) read/write it over HTTPS. This kills by construction:
the double-build class (in-flight work invisible across boxes), the
budget-config class (catalog file not landing on a machine), and split-brain
flag rollouts. Bin/prompts/rules/repos stay repo-managed — only *state* moves.

## Phase 1 (this build)

**New dedicated worker `harness-jobs`** at `worker/jobs/` (same pattern as
locks-worker and watchdog: a bad deploy can't take down the console or the
Telegram relay). Cloudflare D1 database `harness-jobs`. Auth: `Bearer
$HARNESS_SECRET` (already on every box). Same CF account as watchdog
(account_id 00000000000000000000000000000000).

### Schema (additive-only forever)

```sql
CREATE TABLE jobs (
  id TEXT PRIMARY KEY,            -- e.g. build-project-3-TK-109-<ts>
  project TEXT NOT NULL,          -- fleet.conf project name
  ticket_id TEXT,
  kind TEXT NOT NULL,             -- triage | build | fix | qa | migration
  box TEXT NOT NULL,              -- owning box / fly machine id (see below)
  stage TEXT NOT NULL,            -- plan | execute | review | merge | apply | done
  status TEXT NOT NULL,           -- running | done | failed | budget_stopped | parked
  budget_usd REAL,                -- cap handed to the claimant
  spent_usd REAL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  meta TEXT                       -- JSON: pr url, branch, runner, notes
);
CREATE INDEX idx_jobs_project_status ON jobs(project, status);

CREATE TABLE stage_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id TEXT NOT NULL,
  stage TEXT NOT NULL,
  verdict TEXT,                   -- APPROVE | REJECT | BUDGET_STOP | ...
  actor TEXT NOT NULL,            -- box name / lane / "orchestrator"
  detail TEXT,                    -- JSON or free text
  created_at TEXT NOT NULL
);
CREATE INDEX idx_events_job ON stage_events(job_id);

CREATE TABLE budget_catalog (     -- mirror of catalog/context-budgets.json
  lane TEXT PRIMARY KEY,          -- e.g. execute/project-3/claude
  budget_usd REAL NOT NULL,
  updated_at TEXT NOT NULL
);
```

### API (all Bearer-authed, JSON)

- `POST /api/jobs` — register/claim. Body: project, ticket_id, kind, box,
  stage, lane. Returns the job row INCLUDING resolved `budget_usd` (from
  budget_catalog, fallback to stage-tier default). **409 + the existing row if
  an open job for the same project+ticket+kind exists on another box** — this
  is the double-build guard; caller decides (default: stop and log).
- `PATCH /api/jobs/:id` — stage transition / status / spent_usd update.
- `GET /api/jobs?project=&status=&box=&ticket_id=&kind=` — in-flight query (`ticket_id` and `kind` since BH-2406: `job_ticket_abandoned` asks for a ticket's newest `kind=build` row).
- `POST /api/jobs/:id/events` — append stage_event.
- `PUT /api/catalog` — bulk upsert budget_catalog (deploy-time sync from
  catalog/context-budgets.json; a bin script does this on hot-deploy).
- `GET /api/catalog/:lane` — cap lookup. Answers the FLOORED number in
  `budget_usd` with the stored derivation alongside in `derived_usd`; an
  `explicit=1` row is returned verbatim, unfloored (see below).

### Clients (phase 1 wiring, fail-open)

- `bin/jobs-client.sh` — curl helpers: `job_open`, `job_update`, `job_event`,
  `job_cap <lane>`. Reads HARNESS_SECRET + JOBS_URL from env. **Every call
  fail-open**: API unreachable → return nonzero quietly, callers keep today's
  file behavior. One log line, never a blocked build.
- `agent-call.sh` — before a stage: try `job_cap` for the lane; on success use
  it, else current CB_DEFAULT/catalog-file chain unchanged. After a stage:
  `job_update` spend + BUDGET_STOP event (best-effort).
- `run-build.sh` / `run-triage.sh` — `job_open` at start (respect the 409
  double-build guard for builds), `job_update` to done/failed at exit.

### Iron constraints

- Additive-only schema; no DROP, no destructive migration ever.
- No secrets in any row (meta included). Tokens never leave env files.
- Boxes authenticate with HARNESS_SECRET only — no CF credentials on boxes.
- **`box` is the fleet name, never `hostname`.** Every Orgo box boots the image
  default `orgo-desktop`, so a hostname cannot tell one machine from another —
  and the worker keys real behaviour on this column (`paused-box-<box>` flags,
  `scope=box` concurrency rules, the claim-resume comparison). `bin/box-name.sh`
  resolves the `box-*` name from the box's own repo-managed crontab
  (the `bin/watchdog-ping.sh` argument, which `tests/watchdog-boxes-test.sh`
  holds identical to the watchdog worker's `worker/watchdog/src/boxes.json`) and `bin/update-runners.sh`
  leaves it in `state/box-name`, which `bin/jobs-client.sh` reads. Order:
  `$JOBS_BOX` (fly lanes export it) > `$BOX_NAME` > `state/box-name` > hostname.
- The DB is coordination truth, not build truth: PRs, board comments, and
  ALERTS remain the client-facing record.

## Phase 2 (SHIPPED)

- A `ledgers` table, keyed `(kind, key)`, with `GET/PUT /api/ledger` and
  `job_ledger_get`/`job_ledger_put` client helpers. This deliberately deviates
  from the original "read APPROVE from jobs+stage_events" sketch: the merge
  evidence (review.md verdict, judge provenance, rebase notes) stays the LOCAL
  build record — what the sweep actually needs from the DB is an idempotent
  done-ledger a rebuilt hub or second writer can consult, not a re-derivation
  of the verdict from an event stream.
- merge-sweep: `state/merge-sweep-done.txt` becomes write-through fallback;
  reads check file first, then the DB (a DB hit back-fills the file). Reads
  fail CLOSED — a worker outage falls back to the file, never to "not merged".
- migration-autopilot: same ledger pattern (`kind=migration`,
  `key="<project> <file>"`), plus a `kind=migration` job row + stage_events
  (APPLIED/FAILED/FLAGGED/SKIPPED) at each terminal decision. Rows open only
  at terminal decisions or right before a real apply — never for a file merely
  waiting on its deploy.
- plan gate (SDLC item 5): same ledger pattern (`kind=plan_malformed`,
  `key="<project> <key>"`, status `requeued` → `held` → `skipped`, plus
  `released` as the operator's way out), with
  `state/plan-malformed.txt` as the write-through fallback (append-only, last row
  wins; rows carry `<project> <key> <status> <stamp> <artifact>` since BH-657).
  This is the one
  place a ledger row has to outlive a build DIR rather than a box: a
  `PLAN_MALFORMED` build is requeued as a NEW build in a new directory, so
  "have we already given this ticket its one re-plan" cannot be answered from
  anything the refusing build wrote about itself. Reads are file-first then DB,
  like merge-sweep; a total outage means the ticket gets another requeue rather
  than a wrongful hold, which is the safe way for this one to be wrong. `held` is
  written by the terminal on the second malformed plan and is READ before the next
  plan launch (BH-657): that launch is skipped with no model spend and upserts
  `skipped`, which is what makes the "one ALERTS line per held ticket" a
  consequence of the row rather than of a process's memory. A `released` row (in
  both the file and the ledger) hands the ticket back to the planner.
- Catalog sync wired into `bin/harness-sync.sh` deploy: sha-gated PUT of
  `catalog/context-budgets.json`, fail-open, retried next deploy on failure.
- Console UI reads /api/jobs for a live in-flight view — still open.

## Phase 2 client rc contract (`job_ledger_get`)

- rc 0 — row exists (prints its status)
- rc 2 — worker reachable, row absent: a REAL answer, caller may merge/apply
  (and a 404 never burns the daily outage alert)
- rc 1 — outage: fall back to the file ledger, never treat as "not done"

## Phase 3 (SHIPPED)

**Heartbeats + orphan detection — the headline.** A claimant beats its row every
~150s (`job_heartbeat`, `job_beat_start` in bin/jobs-client.sh; wired into
run-build.sh, run-triage.sh, agent-call.sh's stage boundaries and the new
bin/orc-job.sh). `bin/jobs-watchdog.sh` (hub cron */5) reads
`GET /api/jobs?status=running&stale_min=10` and classifies:

- beating, then stopped -> `orphaned` in the DB (which releases the double-build
  guard, because the claim is gone) + ONE ALERTS line naming project, lane, key
  and elapsed, with the matching `logs/kills.log` forensics row when this box
  has it.
- never beat -> reported at 90 minutes, status untouched. Its age is a lower
  bound on inactivity, not proof of death, and releasing a live claim is the
  expensive half of this whole class.

DETECTION, NOT PREVENTION. rc=137 is the OS ending a process; nothing inside it
gets a turn, so no retry is written here and none is driven. What phase 3 fixes
is the silence: on 2026-08-27 17:48Z a kill wave took two detached sessions (a
phase-2 build and the project-2 #400 fix) and both died blank — the only
evidence was work that never arrived. `bin/orc-job.sh` exists so a hand-launched
`claude -p` gets a row and a beat too, and it honours the same 409 guard.

**Console.** `console-ui` gets a JOBS screen (live/recent rows, state, lane,
project, ticket, spend vs cap, started/last-beat ages, orphan flags; every
column sorts, every identity cell links, drill-down at `/jobs/:id` shows the
job's stage events and ledger rows) plus the burn rollup and the pause-flag
controls. It reads this worker through `functions/api/coord/[[path]].js`, which
holds the bearer server-side and delegates the session check to the console
worker.

**Pause flags as rows.** `pause_flags` + `GET/PUT /api/flags`, and the ROW is
the flag (BH-5004): `flag_active` decides from the row it read (cached per
process for `FLAG_ROW_TTL_S`, default 10 s) and reconciles `flags/<name>` as its
mirror. A row that says inactive is still overridden by a file strictly newer
than it. With no row (404), or a row it cannot read, the file decides, so a
worker outage leaves a box behaving exactly as it did before; an unreadable row
from a configured worker leaves one `jobs-client.log` line. Reconciliation is
last-writer-wins on the row's `updated_at` against the file's mtime, and the row
wins ties: an active row creates a missing file stamped with the row's time (and
never re-touches a present one), an inactive row removes the file only when the
row is at least as new as it. `flag_set` PUTs the row first, then writes the
file stamped with the PUT response's `updated_at` (a failed PUT still writes the
file and returns 1), so a file and its row are equal and a later console write
wins, while a later local `touch` — the autohalt, an operator — survives until a
row written after it. An outage, a 404, a row with no readable `active` and an
`updated_at` not in the worker's shape all leave the file alone.

**Burn rollup.** `GET /api/burn?days=` sums `spent_usd` per day / project / kind
from the job rows. It is the COORDINATED SHARE of spend, not the fleet's bill: a
stage that ran without a claim writes cost.csv and never reaches this table, and
the console says so on the section rather than implying the two must agree.

## Phase 3 constraints kept

- Additive only: two NEW tables (`job_heartbeats`, `pause_flags`), no column
  added to `jobs` — D1 has no `ADD COLUMN IF NOT EXISTS`, and schema.sql must
  stay re-runnable because it is applied on every deploy.
- `orphaned` is a new STATUS VALUE, not a schema change; an older client that
  has never heard of it keeps working.
- Everything still fail-open: no heartbeat, no watchdog verdict and no flag
  reconcile can block a build.

## Phase 4 (SHIPPED 2026-08-28)

**Every remaining lane is enrolled.** Phases 1-3 gave rows to the pipelines
(run-build, run-triage, agent-call's stage boundaries, `bin/orc-job.sh` for a
hand-launched `claude -p`). Everything else the fleet runs still had none. Four
things close that:

- **`bin/jobs-client.sh` grows the lifecycle itself** — `job_lane_open <lane>
  [key] [kind] [meta]` and `job_lane_close [rc] [detail]`. Through phase 3 each
  caller spelled claim/beat/spend/close out for itself and the copies had
  already drifted by the third: one exported `JOB_ID`, one did not; one beat
  immediately, one waited a full 150s for its first beat — which is the
  difference between a run killed in its first two minutes being judgeable and
  being a row that never beat at all. Phase 4 adds six more callers, so the
  lifecycle is ONE pair of functions.
  **`job_lane_open` sets variables and must never be called in a command
  substitution.** `CLAIM=$(job_lane_open …)` runs it in a subshell, where
  `JOB_ID` and `JOB_BEAT` are set and then discarded with the subshell: the
  claim opens, the beater is orphaned and the row is never closed. That is why
  the 409 detail lands in `JOB_INFLIGHT` rather than on stdout — there is no
  reason left to capture its output. (Found by driving the first draft of
  `bin/with-job.sh` under a stubbed curl; it is a silent failure, not a loud one.)

- **`bin/with-job.sh <lane> <command…>`** — the generic wrapper, so an
  orchestrator's detached one-off (`setsid … &`) enrolls with no per-script
  work. The LANE is the first argument on purpose: `<stage>/<project>/<runner>`
  is already the key `budget_catalog` is indexed by, so "this lane has a
  declared ceiling" and "this lane can claim a row" are one fact with one
  spelling. `--key` opts into the 409 double-build guard (only keyed claims can
  see it; the worker does not guard ticketless rows). The wrapper's rc is always
  the command's rc; the only case it refuses is the 409, and it refuses BEFORE
  spending anything. `bin/orc-job.sh` keeps its `--project/--kind` flags because
  it wraps a ticket's build session, where the ticket — not the lane — is what
  is being claimed.

- **`review-prs.sh`, `merge-sweep.sh` and `rule-miner.sh` claim LAZILY.** These
  crons do nothing on most ticks: merge-sweep every ten minutes on the hub,
  review-prs twice an hour per project. A row per tick would be several hundred
  empty rows a day for the console to list and the orphan watchdog to age, so
  the row opens the first time a run commits to real work — the first PR that
  needs reviewing, the first merge attempt, the first incident week — and closes
  with the run's real rc. Spend is not wired by hand in any of them:
  `job_lane_open` EXPORTS `JOB_ID`, and `bin/agent-call.sh` already posts each
  stage's dollars onto whatever row `JOB_ID` names. Two spellings of one figure
  is how they come to disagree. merge-sweep spends $0 and says so — it makes no
  model call at all.

- **The pause flags reach these lanes.** `automerge-disabled` and `rule-miner-
  disabled` now resolve through `flag_active`, so a console pause lands on them.
  A 404 is "no row for this flag", never "unpause", and an outage leaves the box
  deciding from the file, as it always has. With no client on the box at all,
  each falls back to the bare `[ -f flags/… ]` test it has always done.

### The lane the manifest could not see

`catalog/context-budgets.json` gains `product-revise` (stage `revise`), and the
row matters less than how it was missing. Every completeness check in
`tests/context-budget-manifest-test.sh` read OBSERVED lanes — the fleet's
`(runner, stage, project)` keys from cost.csv — so a stage only became visible
to them after it had run and billed inside a captured window. `bin/product-cmd.sh`
had called `agent-call.sh revise` for weeks; it simply had not run inside the
snapshot, so it fell through to the $10.50 tier with no declared ceiling and no
UNBUDGETED LANE alert, because agent-call only alerts on a lane it can see run.
A guard keyed on observation cannot see a lane before its first bill. The test
now also resolves every LITERAL stage argument at an `agent-call.sh` call site
in `bin/`, which fires on the day the call site is written. Literal only, and
the limit is stated rather than hidden: `run-build.sh` dispatches through
`"$stage"`, so execute/qa/takeover/probe stay covered by the observed-lane
checks. The two directions overlap deliberately; neither is complete alone.

Coordination lanes are NOT in that manifest and that is deliberate: merge-sweep
claims `merge/fleet/none` and makes no model call, so it has no context to
compose and no ceiling to declare. A row there would be four invented fields
wearing a budget's clothes. The manifest budgets context; the jobs table records
claims. A lane can honestly be in one and not the other.

### Phase 4 constraints kept

- **FAIL OPEN, driven not asserted.** `tests/with-job-test.sh` and
  `tests/cron-job-enrollment-test.sh` run the real scripts against a stubbed
  curl and check the work still happens with the worker down, with a 500, with
  `HARNESS_SECRET` unset, and with `bin/jobs-client.sh` absent from the box.
- **Watchdog stays DETECTION-ONLY.** Nothing here retries, releases or kills.
- **No secrets.** Both new tests assert `HARNESS_SECRET` never reaches a log.
- **No schema change.** Phase 4 is entirely client-side; the worker is untouched.
- `bin/review-prs.sh` and `bin/merge-sweep.sh` now read
  `${HARNESS:-/root/harness}` so they can be driven against a scratch tree.
  Cron never sets it, so production resolves to exactly the path it always has.
  The CI step that used to `sed "s|^H=/root/harness|…|"` into merge-sweep was
  switched to the env var and given a did-this-actually-run assertion — the sed
  would have silently stopped matching and left that step passing vacuously.

## Phase 5 (BUILT 2026-08-28)

**Phases become rows.** Through phase 4 coordination was per JOB: one claim
covered plan → execute → review, and the only per-stage trace was a heartbeat
note plus a spend delta, both of which land on the job row and overwrite each
other. So a build that died left `status=failed` and nothing that said WHICH
stage died, on which runner, at what exit code, having spent what — the first
question every recovery asks, answerable only by finding the build dir on
whichever box still had it.

### What a phase IS, and what it is not

A phase is a **child record of a claim**, never a second claim. The job stays
the unit of coordination: one job, one claim, one double-build guard. Opening a
phase cannot 409, cannot block and cannot wait — a stage that has already been
granted permission must never have to re-ask for it, and a network blip between
plan and execute must never strand a build that is already paid for. That is the
design, not an omission, and `tests/job-phases-test.sh` pins it: even a 409 on
the phase route leaves the stage running.

### Schema (additive, re-runnable, applied on every deploy)

`job_phases` — `id` (autoincrement), `job_id`, `phase`, `runner`, `model`,
`status` (`running|done|failed|orphaned|budget_stopped`), `started_at`,
`finished_at`, `rc`, `spend_usd`, `note`. One row per **attempt**, not per phase
name: review runs twice around a fix round and fix can run three times, so a
table keyed `(job_id, phase)` would overwrite the first attempt's rc with the
second's and lose the failure being attributed. The autoincrement id is both the
attempt's identity and its order, which is why "current phase" is simply the
highest id. No new RLS step: this is Cloudflare D1, reached only through the
bearer-authed worker — the Supabase RLS law does not apply to it, and saying so
is better than silently skipping it.

### Wiring

- **`bin/agent-call.sh` is the one call site.** Every stage in the fleet already
  passes through it, so it opens the phase at stage start and closes it on exit
  with the stage's real rc and its whole bill across the failover ladder. The
  close is an EXIT trap rather than a final line, because four survival lanes
  and a `set -u` slip would otherwise leave a phase reading `running` forever.
  `KILL_STOP` / `BUDGET_STOP` markers ride in the note.
- **`bin/run-build.sh`** closes any phase still open BEFORE it closes the job —
  rc=137 runs no trap, so a stage whose own process was killed never got to
  close its row — and names it on the job's closing event.
- **`bin/jobs-watchdog.sh`** marks the open phase `orphaned` alongside the job
  and names it in the alert. Detection only; nothing is retried.
- **The console** gains a PHASE column on the JOBS table (a failed job shows the
  phase that failed) and a PHASES table on the job's own page — one row per
  attempt with runner, model, rc, spend and duration. A phase that never closed
  shows no duration rather than "now minus started", which would make an
  abandoned row look like it is still working.

### Phase 5 constraints kept

- **Additive only.** `job_phases` is a new table appended to the re-runnable
  `worker/jobs/schema.sql`; nothing existing changed shape. An old `bin/` on a
  box simply never opens a phase, and every screen reads that as "no phase row",
  never as a failure.
- **Fail-open, driven not asserted.** `tests/job-phases-test.sh` runs the real
  `agent-call.sh` against a stubbed curl with the worker down, 500ing, and
  409ing, and checks the stage still runs and still exits on the runner's rc.
- **Watchdog stays detection-only.** Marking a phase orphaned is the same
  judgement applied to the child record; nothing is relaunched.
- **No secrets.** The note carries a runner and a model id, never a credential.
- **No hardcoded model strings.** The `model` column records whatever the stage
  resolved; nothing here chooses a model.

## Phase 6 (BUILT 2026-08-29) — from visibility to CONTROL

Phases 1–5 made every job and every phase a row you could READ. The decisions
were still made off to the side: cron fired blindly, lockfiles and discipline
kept two boxes off one ticket, and the watchdog could see a death but was
forbidden to do anything about it. Phase 6 moves both decisions into the
database. **What may run, and what happens when a run dies, are now DB rows.**

### 1. Atomic, rule-checked claims

Through phase 5 exactly one thing could refuse a claim, and it lived in
JavaScript: same project + ticket + kind, open, on another box. Everything else
was files on one machine, which is precisely where the TK-66/67 double build
slipped through — a rule that lives on a box cannot see the fleet, and a rule
that lives in code cannot be changed without a deploy.

`concurrency_rules` is a table. Each row is `(scope, selector, kind) →
max_concurrent`:

| scope | what the peers of a claim are | what `selector` matches |
|---|---|---|
| `ticket` | the same project + `ticket_id`, fleet-wide | the project |
| `repo` | every open row on the project | the project |
| `box` | every open row on that box / fly machine | the box name |
| `lane` | every open row in that `<stage>/<project>/<runner>` | the lane |

`selector` and `kind` each accept `*`. Most specific wins, **selector
outranking kind** — the same specificity ladder `budget_catalog` resolves on,
because two ladders that disagree is how a rule binds somewhere nobody meant.

**A scope with no matching row is UNLIMITED.** Emptying the table returns the
fleet to phase-5 behaviour exactly. That is the fail-open property the whole
layer rests on, and it is checked by driving it, not asserted.

The check runs INSIDE `POST /api/jobs`, before anything is written, against
state every box shares. **How atomic, exactly:** the check and the write are one
request, not one D1 transaction, so two first-claims landing in the same
millisecond can still both pass — a window of milliseconds against the
minutes-to-hours the file guards left open. The one race that would actually
cost money, two boxes taking over the SAME queued retry row, is closed properly
with a compare-and-swap on the row's status. A refusal comes back as
`409 {refused:true, scope, rule, reason, job}` and the reason is the rule's own
words.

Seeded (`INSERT OR IGNORE`, so a hand-raised cap is never reset by a re-apply):

- `ticket / * / *` → 1 — one ticket, one claim, fleet-wide. This is the
  double-build class, and it is now stricter than the phase-1 guard it sits
  next to: that one only caught the same KIND on another BOX.
- `repo / * / build` → 1 — one build per repo at a time.
- `box / * / build` → 1 — one build per box. This matched the old default of
  `flags/build-slots` = 1; since 2026-09-13 the box itself is uncapped by default
  (`BUILD_SLOTS=0`), so this ROW is the per-box ceiling and raising it is one
  `PUT /api/rules` — see docs/BUILD-CONCURRENCY.md.

**A refusal is a CLEAN SKIP everywhere, never an error.** `bin/run-triage.sh`
logs `claim refused: <reason>` and exits 0 — surfacing a decision the system
made on purpose as a cron failure is how a human learns to ignore the channel.
`bin/run-build.sh` writes `BUILD_DEFERRED` and exits 3, its existing word for
"not now, not a failure", with the rule's words in the ALERTS line so the
deferral names the row an operator would edit. Neither ever bypasses the claim.

**An unreachable worker is not a refusal.** `bin/jobs-client.sh` still returns
rc 1 and prints nothing on an outage, and every caller runs exactly as it does
today. Rules bind only when the DB is answerable; availability never gates work.

### 2. Retry policy, and a watchdog with hands (within policy ONLY)

`retry_policies` is per lane — `max_attempts`, `backoff_seconds`,
`escalate_allowed` — resolved on the same lane ladder as the budget catalog.
**The table ships EMPTY.** No row for a lane means today's behaviour: detection
only, zero retries. Phase 6's retry half lands dark and is switched on one lane
at a time with one `PUT /api/retry-policies`.

`bin/jobs-watchdog.sh` no longer writes `status=orphaned` itself. It makes ONE
call — `POST /api/jobs/:id/retry` — and writes back what the DB decided. Every
dead claim lands in exactly one terminal state:

- **`queued_for_retry`** — within the lane's policy. `next_attempt_at` is set to
  the backoff. The LANE'S OWN NEXT CRON TICK picks the row up through the normal
  claim path (`POST /api/jobs` takes over a due queued row: same job id, same
  ticket, `attempts+1`). A claim arriving while a retry of the same work is
  scheduled but not yet due is REFUSED — starting fresh work then is how a
  backoff becomes an early second attempt.
- **`parked`** — the policy ran out of attempts, with the count that made it a
  human's problem.
- **`orphaned`** — the lane has no policy (unchanged from phase 5), or the death
  was a `KILL_STOP` / `BUDGET_STOP`, which is **terminal whatever the policy
  says**: `bin/agent-call.sh` already serves its own single same-lane retry, and
  a second one is the second attempt paying for the third.

**The watchdog still executes nothing.** Its hands go as far as asking for a
verdict and writing it down. `tests/jobs-watchdog-test.sh` pins that two ways:
no work script on PATH is ever invoked, and no claim (`POST /api/jobs`) is ever
opened from it. The alert memory moved from one-per-JOB to one-per-ATTEMPT,
because a retried row dies again under the same id and the old key would have
suppressed the page for the death that exhausted the policy.

### 2b. The `pr-*` row reaper (2026-09-15)

A row that NEVER beat is reported and left `running` on purpose (above): its age
is a lower bound on inactivity, not proof of death, and releasing a claim that
might still be working is how one ticket gets built twice. That rule has one
population it strands. `bin/triage-shard.sh` claims a row per triage UNIT —
a ticket key on a board lane, `pr-<n>` when the unit is a pull request — and
closes it when the session returns; a shard killed before its first beat never
reaches that line. On 2026-09-15 eight project-5 rows (`pr-913`, `pr-943`,
`pr-968`, `pr-970`, `pr-972`, `pr-974`, `pr-975`, `pr-976`), all claimed at
00:59:22Z and none of which ever beat, still read `running` twelve hours later,
with the same *"Status left as running on purpose"* line re-printed every tick.

`bin/jobs-watchdog.sh` closes those, and ONLY those:

- the row's key is literally `pr-<number>`, and its `kind` is **not** `build`.
  A build row's claim IS the fleet's double-build guard, and a wrongly released
  one rebuilds finished work — so a build row is refused outright rather than
  trusted to a threshold. A pr-`*` unit costs a re-read of one PR.
- it has **never** beaten (`last_beat_at` null). A row that beat and stopped is
  the heartbeat path above, with its retry verdict.
- it is older than `JOBS_PR_ROW_TTL_MIN` (default **360**, six hours) — twice a
  triage shard's own three-hour ceiling (`triage_shard_timeout`), so the row
  outlives the longest run that could still legitimately own it.
- and, for a row claimed on THIS box, the shard's own per-key lock
  (`locks/triage-key-<project>-<key>.lock`) is not currently held. A row claimed
  on another box cannot be checked from the hub, so it leans on the TTL alone,
  which is what the TTL is for.

The close goes through the same `job_phase_close_open` + `job_update
status=orphaned` + `job_event ORPHANED` path a heartbeat-dead job takes — one
`pr-row-reaped` line per row in `logs/jobs-watchdog.log`, and **one**
`bin/lane-alert.sh` summary per run naming every id it closed. Per-row ALERTS
lines would page eight times for one box reboot. A row the reaper takes is
checked BEFORE the alerted-once dedupe, because every row it exists for has
already been paged as SILENT. Nothing is retried and nothing is launched.

### Schema (additive, re-runnable, applied on every deploy)

`concurrency_rules`, `retry_policies` and `job_claims` — three new tables, no
existing table changed shape. `job_claims` (`lane`, `attempts`, `max_attempts`,
`next_attempt_at`, `escalate_allowed`, `reason`) is a side table for the same two
reasons `job_heartbeats` is one: D1 has no `ADD COLUMN IF NOT EXISTS`, so a
counter cannot live in a re-runnable file, and a retry counter must not contend
with the spend deltas `agent-call.sh` writes onto the job row. The API folds
those columns onto the job it returns, so a reader sees `attempts` as a fact
about the job. No RLS step: this is Cloudflare D1 behind a bearer-authed worker,
not Supabase — saying so beats silently skipping it.

### Assumptions taken, stated rather than guessed at

- **A no-policy lane stays `orphaned`, not `parked`.** The brief said "exhausted
  or no policy → parked"; it also said "no row for a lane = current behaviour".
  Those pull apart, and the conservative reading wins: a lane nobody wrote a
  policy for behaves exactly as it did yesterday, which also keeps the console's
  ORPHANED tile and the burn rollup's orphan column alive. `parked` is reserved
  for the genuinely new event — we tried N times and gave up.
- **`escalate_allowed` is recorded, not acted on.** It rides onto the retry row,
  the API and the console so a lane can say "a retry may use a different
  runner"; choosing that runner belongs to whoever picks the row up. A flag this
  layer both wrote and obeyed would be two decisions wearing one name.
- **`repo / * / build → 1` serializes same-project builds that worktrees
  currently allow.** That is what the brief asked for, and it is a ROW: raising
  it is one `PUT /api/rules`, not a deploy. Flagged because it is a real
  throughput change, not a no-op.

### Out of scope (phase 7)

Outcome contracts, enforced state transitions, DB-authoritative pause flags, the
explicit-cap flag, and a sweeper for a `queued_for_retry` row whose lane's cron
never fires again. None of them are built here.

## Phase 7 (BUILT 2026-08-29) — from control to ACCOUNTABILITY

Phase 6 made the database decide what may run. It still could not say whether
anything came of it. A phase row said `done` and the ledger had no idea whether
a plan file existed; a status was whatever the last writer said it was, so a
finished job could be walked back to `running`; a console pause was a row that
only bound on boxes which happened to reconcile a file from it; and a lane cap a
human set on purpose was silently raised to the family maximum by the same floor
that protects derived caps. Phase 7 closes those four.

### 1. Outcome contracts — a phase declares what it must PRODUCE

`phase_contracts` is a table: `(phase) -> (artifact_kind, pattern, note)`.
`job_artifacts` is where the artifacts land, keyed `(job_id, artifact_kind)`
with `artifact_ref` carrying the artifact itself and `phase_id` recording which
attempt produced it.

**The contract binds on the close.** A phase with a contract row cannot land in
`done` without a non-empty artifact of the declared kind (and containing
`pattern`, when one is set). It does NOT refuse the write — the phase closes as
**`contract_unmet`**, with the reason on the row, and the caller gets a 409 it
logs. Refusing outright would leave the phase reading `running` forever, which is
exactly the silence `job_phases` was built to remove. `contract_unmet` is not
terminal: record the artifact, close again, and the check re-runs.

**Keyed on the JOB, not the phase.** Not every artifact comes out of a stage —
the PR is created by `bin/run-build.sh` after the review phase has closed, and
the merge sha is written by `bin/merge-sweep.sh` on another box on another day.
Keying on the job gives all three a home, and `phase_id` keeps the attribution.

**`pattern` is a SUBSTRING, never a regex.** A regex in an operator-edited config
row is a way to put a catastrophic backtrack inside a worker that then times out
every phase close in the fleet.

**THE TABLE SHIPS EMPTY**, exactly like `retry_policies`. No row is no contract
is phase-6 behaviour, so this lands dark and is switched on one phase at a time
with a `PUT /api/contracts`.

Wiring: `bin/run-build.sh` declares a stage's artifact through `CC` and
`bin/agent-call.sh` records it in its phase-close trap, BEFORE the close, if the
file actually materialized and is non-empty. That "if" is the whole point — a
plan stage that exits 0 having written nothing records nothing, and the contract
then refuses to call it done. run-build also records `pr_url` (the moment the URL
exists, so a build that dies later is still findable), `verdict` (after every
tier demotion has run, so the tier recorded is the settled one) and — since SDLC
item 2 — `evidence`: the deterministic render of what the build's checks said
(`bin/evidence-summary.sh` via `job_evidence_put`), ref = the one-line digest,
detail = the same facts as JSON. It is written from the SAME render that goes
into the PR body and `<record>/evidence.md`, so the page a human merges from, the
file fallback and the row can never disagree. No model call is involved.

Since SDLC item 3 the `verdict` detail also carries `repairs` — how many times a
lens or preview QA sent this build's code back before it settled
(`bin/repair-count.sh`). It is ALWAYS written, including as `0`: unlike a
reviewed sha, zero is a measurement, and the correlation this exists for needs
the clean builds as much as the repaired ones. `GET /api/verdict` surfaces it,
and `bin/outcome-metrics.sh` copies it onto the `outcome_metrics` row it writes
for a reverted / reopened / merged-then-red PR, so "do builds that had to be
fixed twice get reverted more often" is one query rather than a join across a
ledger and a box's disk. A row with no field at all means NOT MEASURED, which
every reader keeps distinct from zero.

Since SDLC item 5 the plan stage also records a `plan_gate` artifact: ref = the
verdict word (`ok` / `untraced` / `unavailable`), detail = the task count, the
untraced count and up to four offending task labels. It is written on EVERY
build with a job row, clean ones included, for the same reason `repairs` is: a
row written only on failure makes "no row" mean both "clean" and "box that
predates the gate". It is also the ONLY row a refused build produces — a
`PLAN_MALFORMED` build stops before EXECUTE, so it never reaches the `verdict`
artifact. The file fallback is `$BUILD/plan-gate.txt`.

### 2. merge-sweep reads verdicts from the ledger

Through phase 6 the three inputs to a merge decision were three files on the box
that ran the build: `review.md`'s last line, the `.runner` sidecars, and the tier
`run-build.sh` computed and threw away. That works exactly as long as the record
and the sweep sit on one disk.

`GET /api/verdict?pr=<url>` joins a PR to its job and returns verdict, tier,
provenance and merge sha in ONE round trip — the sweep runs every ten minutes
over a directory of records and must not pay three calls per PR. The sweep uses
it when it answers and scrapes its own record when it does not.

- **rc 2 (no job recorded this PR) and rc 1 (worker unreachable) both fall
  through to the scraping, unchanged.** With an empty ledger this sweep is
  byte-identical to phase 6, which is the whole safety argument for filling the
  ledger one build at a time.
- **A ledger verdict that CONTRADICTS the record parks the PR and pages.** They
  are two copies of one judgement written by one script from one file; if they
  differ, something was edited or a record is in the wrong directory. Merging on
  either half of a contradiction is the expensive guess.
- Provenance now comes from the row rather than a `grep` of one box's
  `pipeline.log`. Same rule — a cheap-lane APPROVE gates the build and never
  auto-merges — sourced from state every box shares.
- On a successful merge the sweep records `merge_sha` on the BUILD's job, not on
  its own sweep row, which is a coordination claim that knows nothing about the
  build.

The sweep still enumerates local build records. Merging a PR whose record never
reached this hub would be a different feature and is not built here.

### 3. Enforced state transitions

Status was previously whatever the last writer said. The graph below is data in
`worker/jobs/src/lib/core.js` (`JOB_TRANSITIONS` / `PHASE_TRANSITIONS`) and it is
the same one printed here, so the doc and the worker cannot drift.

**Jobs**

| from | may become |
|---|---|
| `running` | running, done, failed, parked, budget_stopped, orphaned, queued_for_retry, abandoned |
| `queued_for_retry` | queued_for_retry, running, parked, orphaned, failed, done, abandoned |
| `parked` | parked, running, queued_for_retry, orphaned, abandoned |
| `orphaned` | orphaned, running, queued_for_retry, parked, done, failed, abandoned |
| `failed` | failed, running, queued_for_retry, parked, abandoned |
| `done` | done — **terminal** |
| `budget_stopped` | budget_stopped — **terminal** |
| `abandoned` | abandoned — **terminal**; reached only through the audited `POST /api/jobs/:id/abandon` |

**Phases**

| from | may become |
|---|---|
| `running` | running, done, failed, orphaned, budget_stopped, contract_unmet |
| `failed` | failed, running, orphaned, contract_unmet |
| `orphaned` | orphaned, running, failed |
| `contract_unmet` | contract_unmet, running, done, failed |
| `done` | done — **terminal** |
| `budget_stopped` | budget_stopped — **terminal** |

Two properties fall out of the tables rather than out of a special case:
`budget_stopped` stays terminal (the standing KILL_STOP/BUDGET_STOP iron rule),
and `parked -> done` is illegal — a parked job re-enters work through `running`
and finishes from there, so a row can never claim an outcome no attempt produced.

`orphaned -> done` and `queued_for_retry -> done` ARE legal, and that is not an
inconsistency with the line above. Both statuses are inferences the watchdog drew
from silence; a build whose own process then reports completion is strictly
better evidence than the absence that convicted it, and refusing the write would
leave a finished build under an orphan verdict with its PR invisible. `parked` is
the opposite: a deliberate decision taken after the attempts ran out.

**The asymmetry is deliberate.** An unknown TARGET status is refused with 409:
these strings drive every screen and every gate, and a typo that lands as a
permanent "unknown" is worse than a 409 the fail-open caller drops. An unknown
SOURCE status is ALLOWED to move: it means a row was written by something the
worker does not model yet, and refusing would strand it forever. The graph is a
guard, not a trap.

Enforced in `PATCH /api/jobs/:id`, `PATCH /api/phases/:id`, and — the one that
was actually reachable by accident — `POST /api/jobs` when the caller supplies
an `id`, because that route upserts `ON CONFLICT(id) DO UPDATE SET
status='running'` and would otherwise resurrect a finished claim.

### 4. Pause flags are authoritative at claim time

Phase 3 made pause flags rows and had each box reconcile a FILE from them. That
reaches only boxes which run `flag_sync`, and only the readers that test that
particular file; a fly builder boots, claims and builds without reconciling
anything. Phase 7 checks the rows INSIDE `POST /api/jobs`, first — before the
double-build guard, before the concurrency rules, and before a due retry can be
picked up, because a pause is "none of this runs here right now" and a backoff
must not fire on a paused lane.

Names checked, broadest first (broadest wins the reported reason, because "the
whole fleet is paused" is the headline a human needs):

    paused-all
    paused-<project>
    paused-box-<box>
    paused-lane-<lane with / replaced by ->

A refusal is `409 {refused:true, scope:"pause", flag, reason}`, which every
caller already handles — `bin/run-build.sh` writes `BUILD_DEFERRED` and exits 3,
`bin/run-triage.sh` logs and exits 0. No client change was needed for that.

**THE FILE STAYS THE FALLBACK.** `flag_active` is untouched: it reconciles, then
answers from the file, so a worker outage leaves every box deciding exactly as it
does today. An empty `pause_flags`, or every row at `active=0`, refuses nothing.

**Flagged as a real behaviour change on deploy:** a `paused-<project>` row
already sitting at `active=1` from an earlier console pause will begin refusing
claims for that project the moment this worker deploys. That is the correct
reading of the row — the project IS paused — but it is a change, not a no-op.

### 5. The explicit-cap flag

`bin/agent-call.sh` floors every resolved lane cap at its stage family's maximum
(150/50/25) on purpose: MAX COST, NOT TARGET COST — a tightly-derived cap must
never kill good work mid-stage. Until now only an env override could bind
verbatim, because that is an operator saying "this exact number, on purpose".

`budget_cap_flags` gives a DB row the same standing: `explicit=1` binds VERBATIM,
unfloored. Default rows keep today's floor exactly.

**The worker floors too, since 2026-08-30** (the operator: "lets change our max cost per
PR it's too low"). `stageFloor()` in `worker/jobs/src/lib/core.js` is the one
definition of the LEDGER's fuse and of the tier a lane falls to when no catalog
row matches — build family (`plan` `execute` `review` `fix` `revise`
`takeover`) **$50**, product family (`ideate` `prd` `mockup` `signals` `synth`
`preplan` `map`) **$20**, misc (incl. `probe`) **$10**, raised from
10.50/6.00/3.00. That is the number a job row carries, so it is the number every
"spent $X of $Y" readout — the watchdog line, the console's SPENT / CAP column —
is judged against, and it is why project-2 TK-206 read as over budget at $16.46 of
entirely honest spend. Honest builds run ~$15-25; $50 is ~2x the top of that, so
meeting it is evidence of a runaway rather than of a big ticket. The floor is
applied at BOTH the `PUT /api/catalog` derivation and the `resolveLane` read, so
a row left by an older sync obeys today's policy. `bin/agent-call.sh`'s own
per-stage fuse (150/50/25) is unchanged and floors whatever it reads from the
DB, so these numbers can never lower that bound. Real spend control stays the
daily burn ceiling and the token ceilings.

- **Its own table, and the reason is not just re-runnability.** `PUT /api/catalog`
  is the deploy-time sync of `catalog/context-budgets.json` and rewrites every
  lane it carries; a flag on that row would be reset by the next hot-deploy — a
  config change nobody made. Nothing but `PUT /api/cap-flags` writes here.
- **`explicit` does not travel down the lane ladder.** It resolves for the EXACT
  key that answered. "On purpose" is a statement about one row, and inheriting it
  would bind lanes nobody looked at.
- `job_cap` is unchanged and still prints a bare number; the flag arrives through
  a NEW `job_cap_row`. `bin/` syncs per box, not atomically across the fleet, and
  a cap that reached an older `agent-call.sh` as `12.50<TAB>1` and was compared
  numerically would be a budget bug wearing a feature's clothes.

### Schema (additive, re-runnable, applied on every deploy)

Three new tables — `phase_contracts`, `job_artifacts`, `budget_cap_flags` — and
one new phase STATUS VALUE, `contract_unmet`. No existing table changed shape:
D1 has no `ADD COLUMN IF NOT EXISTS` and `schema.sql` is applied on every deploy,
so `artifact_ref` lives in its own table and the API folds it onto the rows it
returns, the same way `job_claims`' columns arrive folded onto a job. No RLS
step: this is Cloudflare D1 behind a bearer-authed worker, not Supabase — saying
so beats silently skipping it.

### Phase 7 constraints kept

- **Every new table ships EMPTY.** Contracts, cap flags: no row is phase-6
  behaviour. The one exception is `pause_flags`, which already has rows — see
  the flagged behaviour change above.
- **KILL_STOP / BUDGET_STOP stay terminal**, now by a row of the transition graph
  rather than by everyone remembering.
- **The watchdog still executes nothing.** Phase 7 adds it no hands.
- **Fail-open everywhere the ledger is down**, driven and not asserted:
  `tests/outcome-contracts-test.sh` runs the real `merge-sweep.sh` and the real
  `_budget_for` against a stubbed curl with the worker unreachable, and checks
  the merge still happens and the lane is still funded.
- **No hardcoded model strings.** Nothing here chooses a model; the artifacts
  record what a stage produced.
- **No secrets.** An artifact ref is a path, a URL or a verdict word; both new
  test suites assert `HARNESS_SECRET` never reaches a log.

### Not built, and named rather than implied

- The console has no CONTRACTS or ARTIFACTS screen yet. The rows are readable
  through `GET /api/contracts`, `GET /api/jobs/:id` and `bin/jobs-client.sh`,
  and the JOBS drill-down returns `artifacts` in its payload, but nothing renders
  them.
- A contract on a phase whose artifact is only known AFTER the phase closes
  cannot be satisfied at close time. That is why `run-build.sh` records `verdict`
  and `pr_url` on the JOB rather than declaring them as review-phase artifacts,
  and why the phase-level declarations are `plan_file` and `review_file` — the
  two a stage genuinely leaves behind before it exits.
- The `queued_for_retry` sweeper phase 6 deferred is still not built.

## Lane liveness (BUILT 2026-08-30) — from what happened to what did NOT

Every phase above records work that HAPPENED. That is the blind spot this one
closes, and the incident named it exactly: on 2026-08-30 project `project-7` lost
every one of its crons on `box-project-6-1` at 05:17 and sat silent for
**ten hours**. The box kept pinging (it still ran its other lane). The hub kept
pushing fleet status. `bin/jobs-watchdog.sh` ages rows that exist — and a lane
that never ticks never claims a job, so there was no row to age. Nothing in this
database knew the lane was supposed to be ticking, so nothing could miss it.

**A lane is one `(project, box)` pair** — the unit `fleet.conf` declares and the
unit a crontab loses. Not the project alone (projects move between boxes, and
two share `box-project-6-1`), and not the box alone (that box lost ONE
of its two lanes while the other kept ticking, which is why a per-box ping was
right to stay quiet).

**The expectation and the heartbeat are written by different actors**, on
disjoint columns of one `lanes` row: the hub declares (`expected_since`,
`cadence_min`, `retired_at`) from `fleet.conf` on the push it already makes; the
box records ticks (`last_tick_at`, `last_tick_kind`) at the top of every
`bin/run-triage.sh` run. So a box cannot enrol itself, and a hub push cannot
fake a heartbeat.

**A gate SKIP is a heartbeat.** Most ticks on a quiet board skip: no claim, no
spend, no LLM call. If only the expensive ticks counted as life, every healthy
quiet lane would page — which is why this is a lane tick and deliberately not a
second job row (the lazy-claim rule from phase 4 still holds: an idle cron
claims nothing).

**Staleness is derived per lane** — three missed ticks, floored at 30 minutes —
and the threshold rides on the row, so the pager and Mission Control judge a
lane by one number. A lane that has never ticked since it was declared is aged
from `expected_since`: the incident's twin, a box whose crons never landed.

**One page, then one recovery.** `alerted_at` is the latch and it lives in the
DB, because a hub-local seen-file could do the dedupe and never the recovery,
and would forget the dedupe on every hub rebuild — exactly when a lane is most
likely to be missing its crons.

Schema, API, wiring and rollout: `worker/jobs/schema.sql` (`lanes`) and
`worker/jobs/README.md` § Lane liveness. Tests: `tests/lane-liveness-test.sh`,
`worker/jobs/test/index.test.js`, `console-ui/tests/jobs.test.js`.

### Constraints kept

- **Additive only.** One new table, no column added to an existing one, no
  behaviour changed on any route that already shipped.
- **Fail-open everywhere.** No client, no worker, no secret → no row, no noise,
  and `bin/run-triage.sh` behaves byte-for-byte as it did before.
- **No new cron.** Every piece rides a schedule that already exists.
- **No second heartbeat path and no second alert channel.** Lane ticks reuse
  `bin/jobs-client.sh`'s request layer; alerts are `ALERTS.log` lines written by
  the watchdog that already writes them.
- **An empty expected set retires nothing** — the same judgement
  `bin/fleet-status-push.sh` already makes about pushing an empty fleet.

## Queue rows (BUILT 2026-09-10) — the wait BEFORE the claim

Every phase above models a job from the moment a box CLAIMS it. The minutes or
hours before that were files on a box, moved between machines by ssh, and that
is the last structural reason the hub needs ssh into every box at all.

**The seam, precisely.** Three things were directories rather than rows:

1. the pre-claim build queue `state/build-queue/<project>/<KEY>.json`, written by
   `bin/run-build.sh`'s QUEUED_FLY branch and pulled to the hub by
   `bin/fly-dispatch.sh` over tailnet ssh;
2. the RESULT hand-back from a fly machine to the owning box
   (`state/remote-results/<project>/<KEY>.json` plus a `touch` on
   `state/merge-queue/<project>/<pr>`), pushed over scp;
3. the per-project merge queue and the sweep's done list.

Consequences: the hub needs ssh into every box for the pool to work, a queued
build is INVISIBLE to Mission Control until somebody claims it, and there are
two different things in this system called "waiting".

### What (1) becomes

`build_queue`, keyed `(project, ticket_key)` — exactly the identity a filename
gave it. Four routes (`POST /api/queue`, `GET /api/queue`,
`POST /api/queue/claim`, `PATCH /api/queue`) and five client helpers
(`queue_put` / `queue_list` / `queue_claim` / `queue_done` / `queue_release`).
Shape, statuses and rc contract: `worker/jobs/README.md` § The pre-claim build
queue.

Three properties are the whole point, and each is driven by a test rather than
asserted:

- **ONE CLAIMANT, fleet-wide.** The claim is a compare-and-swap inside the
  worker: the `UPDATE` lands only `WHERE ... AND status='queued'`, so two
  dispatchers ticking in the same second cannot both take one row. `mv` gave the
  file queue this guarantee on ONE box and never across two, which is why the
  hub had to hold the queue in the first place.
- **AN EMPTY QUEUE IS AN ANSWER, NOT AN OUTAGE.** The claim 404s, the client
  turns that into rc 2, and no daily unreachable-worker alert is burned. A
  dispatcher must be able to tell "nothing to build" — the normal shape of every
  tick on a quiet project — from "the DB is down", because only the second one
  should fall back to reading a directory.
- **IDEMPOTENT ON THE PAIR, INCLUDING WHILE CLAIMED.** `run-build.sh`, the fly
  requeue and a triage relaunch all enqueue the same key. Re-enqueueing one that
  is `queued` or `claimed` writes nothing — the TK-70 shape (2026-08-13), where a
  key re-enqueued mid-build spawned a second build after the reap. Re-queueing a
  FINISHED row is a real new attempt and continues the attempt counter.

**THE FILE STAYS THE FALLBACK**, the same way `pause_flags` and the merge ledger
do: producers write both and readers ask the DB first. An unreachable worker
leaves every box queueing and draining exactly as it does today. A queue that can
refuse work when a database blinks is worse than no queue in a database at all.

**This lands DARK.** The table ships empty, and nothing writes or reads it until
the producers move — a separate change, so the schema and the API can be reviewed
without a behaviour change riding along.

### Producers (BUILT 2026-09-10)

`bin/run-build.sh` is the fleet's one MECHANICAL enqueue point, so it is where
the row is written:

- **the QUEUED_FLY branch writes the ROW and the FILE.** The file is still the
  queue — `bin/fly-dispatch.sh` and `bin/fly-pool.sh` read the directory until
  they move — so a failed row changes nothing at all.
- **the local launch path CLAIMS its row** if one exists, so a queued build the
  dispatcher might otherwise hand to a machine reads as in flight. This is
  BOOKKEEPING, NOT AUTHORITY: whether the build may run was already decided by
  `job_open`, the fleet-wide ticket-keyed guard with the concurrency rules
  behind it, so losing this compare-and-swap logs and continues. A second
  refusal path here could only ever turn a legitimate build into a no-op.
  Gated on `JOB_ID` because the EXIT trap that CLOSES the row is installed only
  on that path — claiming without it would leave a row `claimed` forever.
- **the close carries the SAME verdict as the job**, derived from the status
  `_job_finish` already computed rather than re-parsed from the RESULT line, so
  the two ledgers cannot come to disagree. A DEFERRAL goes back to `queued`:
  exit 3 is this pipeline's word for "not now, not a failure" and the ticket is
  re-offered next tick, exactly as the queue FILE is left in place today.

`bin/run-triage.sh`'s queue-pending TICK SCOPE lists the ROWS, falling back to
the directory on an outage, an old client, or an empty table (the shape of the
transition). The rows carry two things a filename could not: the target the
build is queued for and its attempt count.

`bin/fleet-status-push.sh` counts queue depth from the rows. That number is
Mission Control's QUEUED column, and it used to count files in the HUB's copy of
each box's queue — a copy that exists only because `fly-dispatch.sh` ssh's into
every box and scp's the directory over, so the column was in effect a readout of
whether ssh had run recently.

`bin/run-build.sh` also gains `HARNESS` / `REPOS_ROOT` overrides so the pipeline
can be DRIVEN against a scratch tree — the same change `bin/review-prs.sh` and
`bin/merge-sweep.sh` took in phase 4, for the same reason. Cron and the fly
runner set neither, so production resolves to exactly the paths it always has.

**Still ssh after this change:** everything. `fly-dispatch.sh` still pulls the
queue directory over tailnet ssh, results still come back by scp, and the merge
queue is still a directory. This PR makes the rows TRUE; the readers move next.

### The console

`GET /api/queue` is reachable from the console with no proxy change —
`console-ui/functions/api/coord/[[path]].js` already allows any GET, so
`/api/coord/queue` works the moment the worker is deployed. **The UI change is a
follow-up**: nothing renders the rows yet, and the pipeline's QUEUED column
still reads `queue_depth` out of the fleet-status push (which now comes from the
rows). A QUEUED column that lists the actual builds, each linking to its ticket,
is the natural next screen and is not built here.

### Not done in the producers change, and named rather than implied

- ~~The queue-pending scope's header still reads `Queued launch requests in
  state/build-queue/<project>/:`.~~ **Done 2026-09-11**: the directory retired on
  the watcher side, so the header names the source it actually has — "Queued
  launch requests for `<project>` (from the coordination DB)" — in BOTH
  `bin/run-triage.sh` and `bin/prompt-eval.sh`'s replica, which
  `tests/prompt-eval-grade-test.sh` §12 keeps in step.
- Nothing reads the rows to DECIDE anything yet. The dispatcher, the pool and
  the merge queue are the next two changes, below.

## Planned: the dispatcher, the results, the merge queue

The remaining two thirds of the seam. Written down here so the shape is agreed
before the code, and so a reader of PR 2 knows exactly what is still ssh.

### A. The fly dispatcher and pool read the DB queue (PR 3) — BUILT, see below

`bin/fly-dispatch.sh` opens with a loop that, for every flagged project, ssh's
into the owning box, `ls`'s `state/build-queue/<p>/`, `scp`'s each file back and
`ssh rm`'s it. That loop — and the `declare -A OWNER` table of tailnet IPs it
needs — is what a DB queue deletes.

- The dispatcher's "is there work" question becomes `queue_list <p> queued fly`
  and its claim becomes `queue_claim <p> fly`, which returns the key, ticket id
  and attempt in one line. The pulled-file loop stays as the FALLBACK for one
  release: on rc 1 (outage) it runs exactly as today.
- `bin/fly-pool.sh` does the same for its SPAWN loop, and its requeue-on-death
  path becomes `queue_put` with `attempt+1` (giving up at 2 exactly as now,
  recorded as `failed` with the reason rather than a `.failed.json` file).
- The `.failed.json` convention keeps a home: `status='failed'` plus `reason`,
  which `bin/healthcheck.sh` can then count without a directory.
- **What stays ssh, and why:** the env bundle push and the RESULT pull travel
  over **Fly's own console/sftp channel** (`flyctl ssh sftp`, `flyctl ssh
  console -C`), which is not tailnet ssh and not a hub-into-box path — it is how
  Fly is administered at all. `bin/fly-envbundle.sh` also pulls each project's
  secrets from its OWNING box over tailnet ssh at dispatch time, deliberately,
  so the hub never persists another project's secrets; that one is a security
  property, not a coordination one, and it is not touched.

### B. Results come back as artifacts, not scp (PR 3) — BUILT, see below

Today a finished fly build's RESULT reaches its owning box by `ssh cat >` into
`state/remote-results/<p>/<KEY>.json`, plus a second hop that `touch`es
`state/merge-queue/<p>/<pr>`.

- The machine already has `HARNESS_SECRET` and the worker URL in its env bundle
  (`env/global.env` carries both; `JOBS_URL` defaults to the worker in
  `bin/jobs-client.sh`, so nothing new has to be shipped) — **confirm this on
  the box before writing the code**, because a credential the machine turns out
  not to have is a planning failure, not bad luck.
- `run-build.sh` on the machine already records `pr_url` and `verdict` as job
  ARTIFACTS. It gains one more, `result`, carrying the canonical RESULT text,
  and the tier rides in the verdict detail.
- The owning box's triage results-sweep reads `remote-results` from the
  artifacts **in addition to** the directory, keyed on the job's ticket — so a
  result that never made the scp trip is still swept.
- The relay in `fly-pool.sh` stays for one release as the fallback, because a
  result that reaches nobody is the most expensive failure in this system.

### C. The merge queue becomes rows (PR 4) — BUILT, see below

`state/merge-queue/<project>/<pr-number>` (and its `.blocked` sibling) is a file
per PR, written by `bin/tier2-merge-sweep.sh`, `bin/run-build.sh`,
`bin/review-prs.sh` and — over ssh — by `bin/fly-results-ingest.sh` and
`bin/fly-pool.sh`.

- A `merge_queue` table keyed `(project, pr)` with `status` (`queued` |
  `blocked` | `landed`), `reason` and `enqueued_by`. `.blocked` becomes
  `status='blocked'` with the reason the beat already carries, which is strictly
  more than the filename could say.
- `tier2-merge-sweep.sh` enqueues through the client; `merge-queue.sh` claims
  from the DB and falls back to the directory.
- `merge-sweep.sh`'s DONE list uses the EXISTING merge ledger only
  (`job_ledger_get merge <pr>`), retiring `state/merge-sweep-done.txt` as a
  second copy of the same fact. That read must stay **fail-CLOSED** — an outage
  falls back to the file, never to "not merged" — which is why the file is
  retired as a WRITE-THROUGH cache rather than deleted.
- Files remain the fail-open fallback throughout, exactly as above.

## The fly lane (BUILT 2026-09-10) — the hub stops reaching into boxes

Two ssh hops, in opposite directions, both removed by rows.

### The queue: pulled by the hub, not scraped off the box

`bin/fly-dispatch.sh` opened with a loop that, per flagged project, ssh'd into
the owning box, `ls`'d `state/build-queue/<p>/`, `scp`'d each file back and
`ssh rm`'d the original — every two minutes, forever. **That loop is why the hub
needs ssh into every box at all.**

It now reads `queue_list <p> queued fly` and MATERIALISES the same files. That
choice is deliberate and it is what keeps the change small: everything
downstream — the dispatcher's own claim, `bin/fly-pool.sh`'s spawn loop,
`bin/healthcheck.sh`'s queue-depth alerts — is untouched, because only the
SOURCE of the file changed, not its shape.

**THE CLAIM IS THE HAND-OFF.** The row is compare-and-swapped to `claimed`
BEFORE the file is written, and the file only appears if that won. Without it a
row would sit `queued` while the pool built it, be materialised again on the
next tick, and the pool would spawn a SECOND machine for a key it is already
running — the TK-70 shape (2026-08-13) reintroduced by the fix. `bin/fly-pool.sh`
therefore closes the row on every terminal outcome: `done` on a reaped RESULT,
`failed` when a machine dies twice or a malformed entry is quarantined, and
close-then-enqueue on a requeue (enqueueing over a `claimed` row is a duplicate
by design, so the dead attempt must be closed before the next one is queued).

**Fail-open and fall-through:** an outage, an old client, or a project with no
rows yet all drop to the ssh pull, unchanged. **The hop disappears for a project
the moment its producers are writing rows — not before**, and that is the honest
description of what this ships.

`bin/fly-dispatch.sh` also loses its `declare -A OWNER` in favour of the
`owner_ip()` case form `bin/fly-results-ingest.sh` and `bin/fly-envbundle.sh`
already use. That was the one bash-4 construct in the file, and under `set -u`
on bash 3.2 its subscript is read as an arithmetic expression and the script
dies on the first line of the queue loop — which is why nothing in this
dispatcher had ever been driven by a test.

### The results: pulled by the box, not pushed by the machine

A finished fly build handed its RESULT back the other way: `ssh cat >` into the
owning box's `state/remote-results/<p>/<KEY>.json`, plus a second hop that
`touch`ed `state/merge-queue/<p>/<pr>`. When that push fails the whole close-out
strands — TK-124 sat a day until a medic hand-delivered it.

- `bin/run-build.sh` records a **`result` artifact** (the RESULT's first line —
  the same summary the relay payload has always carried; `artifact_ref` is 1024
  chars and a close-out is one line) on **every box**, uniformly. Nothing about
  the row is fly-specific: `result` is simply what a build concluded.
- `GET /api/artifacts?kind=&project=&job_kind=&since=` is the reverse of the
  per-job read — "which builds of this project produced an artifact of this
  kind, anywhere in the fleet" — with the job's `box`, `project` and `ticket_id`
  folded on. `since` is an exclusive watermark, or a sweep re-reads the row it
  just handled on every tick.
- `bin/run-triage.sh` stages those rows into the same
  `builds/<project>-<KEY>-remote<ts>/RESULT` shape the file path produces, so the
  existing results-sweep SOP handles them with no change.

**THE BOX COLUMN IS THE WHOLE GUARD.** Because every box records `result`, a
sweep that did not filter would stage its OWN builds — whose records are already
in `builds/` waiting to be swept — and post a SECOND close-out on a client's
ticket. Staging is skipped when the artifact's box is this box, deduped per
`job_id` in the existing `.handled` directory, and skipped again when a
`-remote` dir for that key already exists from the file path.

The scp relay stays in place as the fallback for one release, because a result
that reaches nobody is the most expensive failure in this system.

### What is still ssh after this, and why

- **`flyctl ssh sftp` / `flyctl ssh console -C`** — the env-bundle push and the
  RESULT pull to and from a fly machine. This is **Fly's own administration
  channel**, not tailnet ssh and not a hub-into-box path; there is no other way
  to reach a fly machine. Untouched, deliberately.
- **`bin/fly-envbundle.sh`'s hub→box pull** of each project's build secrets at
  dispatch time. That hop exists so the hub never persists another project's
  secrets on disk — a SECURITY property, not a coordination one. Untouched.
- **The ssh queue pull and the scp result relay**, as the fail-open fallbacks
  described above. They stop being exercised as the rows fill; they are removed
  in a later change, once a fleet-week has gone by with the DB path serving.
- Everything outside the fly lane: `bin/rules-drift-check.sh`, `bin/cost-rows-push.sh`, `bin/box-chat.sh` and the
  rest of the hub's read-only fleet sweeps. None of them are coordination.

### Confirmed rather than assumed

A fly machine reaches the worker with the credential it already has:
`bin/fly-envbundle.sh`'s whitelist ships `HARNESS_SECRET` and `CONSOLE_URL` in
`global.env`, `fly/builder-runner.sh` sources that bundle with `set -a`, and
`bin/jobs-client.sh` defaults `JOBS_URL` to the worker — which is why fly builds
already carry job rows today. **`JOBS_URL` is NOT in the bundle**: if the worker
ever moves, a fly machine keeps the compiled-in default until that whitelist
gains the variable. Worth adding before any such move.

**This is a code-level confirmation, not a live probe.** Nothing here was
exercised against a real fly machine from this session; the evidence is the
existing job rows fly builds already produce through the same path.
### Review fixes (2026-09-10, adversarial review of #222)

Two of these were double-build or double-comment bugs, which is what the review
was for. All four are pinned by tests written red first.

- **The ssh drain runs EVERY tick.** It used to `continue` past the drain
  whenever any row was queued. But `bin/run-build.sh` on a watcher still writes
  the box file, and the drain is the ONLY thing that removes it: on a busy
  project the files accumulated, and the first quiet tick pulled them all at
  once — by which time their builds had been reaped, so neither the hub-file
  test nor the live-in-pool guard matched and the pool spawned a SECOND machine
  per key. The TK-70 shape arriving by a new road. **The hub→box hop cannot go
  away until the producer stops writing the box file**; until then this drain is
  load-bearing on every tick.
- **The drain drops what the ledger says is no longer queued.** `queue_status`
  (a new `?key=` on `GET /api/queue`) answers per file. A row that is `claimed`,
  `done` or `failed` means this hub already took custody: the box copy is
  removed and never pulled. Only "no row at all" (rc 2) and an outage (rc 1)
  fall through to the pull, and both mean the same thing here — nothing in the
  DB claims to own this file, so it is real work.
- **The relay loop got the guard the ledger loop already had.** The artifact row
  lands when the build ends and the scp'd relay json arrives a tick later, so a
  result staged from the ledger was staged AGAIN from the json — two build dirs
  for one build, and **two close-out comments on a client's ticket**. The json
  is now consumed and its own build dir marked COMMENTED.
- **The artifact feed has a watermark** (`state/remote-results/<p>/.since`). The
  feed is a WINDOW, not a queue, and the `.handled` markers that stop a re-stage
  live on the box: a rebuilt or restored box has none and would replay up to
  fifty close-outs. The watermark advances past rows deliberately SKIPPED too,
  and is written only after the loop — so a crash re-reads rather than skips,
  and the markers cover that case.

Also: a stale `claimed` row is released by `bin/jobs-watchdog.sh` (see below),
list limits are clamped with `Math.max(1, …)` because SQLite reads `LIMIT -1` as
unbounded, and an unkeyed claim that loses a race walks to the next row instead
of skipping the tick (a keyed claim still refuses — it wanted that row).

### The orphaned claim (2026-09-10)

A `build_queue` row is CLAIMED when the hub materialises it and CLOSED when the
pool reaps the result or `run-build.sh` exits. Both need something alive to do
the closing, so a machine lost between them leaves the row `claimed` FOREVER —
and because the enqueue guard treats `claimed` as accounted-for, that ticket can
never be queued again on the DB path. Silent, permanent, and invisible to every
other detector: no job row ages, because the job died in the same instant.

`bin/jobs-watchdog.sh` releases it after `JOBS_QUEUE_CLAIM_MIN` (default **6h**,
against an honest ~20-40m build). The default is deliberately generous because
the cost is asymmetric — releasing early re-queues work that is still running,
releasing late only delays a ticket nobody is building — and it is safe to be
generous for a reason worth stating: **the double-build guard is not this
release**, it is `job_open`'s fleet-wide ticket rule, so even a wrongly released
row cannot produce a second CONCURRENT build; it would be refused at the claim.

**Be precise about what that guard does not do.** It stops two builds of one
ticket running *at the same time*. It does NOT stop a ticket that already
finished from being built again — the earlier claim is closed, so a fresh claim
is legal and correct, which is how a retry, a fix round and a re-queue work at
all. An over-eager release therefore would not collide with a running build; it
would **rebuild finished work**. That is why the threshold is hours rather than
minutes, and why `bin/fly-pool.sh` closing the row on every terminal outcome
carries more weight than this sweep does.

This is the one place in that script that writes a state change rather than
recording a verdict, and it is bounded to exactly that. **Nothing is launched** —
the lane's own next tick picks the work up through the normal claim path, which
is what keeps ONE place where work can start. `tests/queue-claim-release-test.sh`
pins that by failing if any work script is ever invoked.

## The merge queue (BUILT 2026-09-10)

`state/merge-queue/<project>/<pr-number>` — an EMPTY FILE per PR plus a
`<pr>.blocked` sibling — becomes `merge_queue` rows keyed `(project, pr)`.

**The hop this removes** is the one a finished fly build takes: `bin/fly-pool.sh`
and `bin/fly-results-ingest.sh` `ssh` into the OWNING watcher box to `touch` a
filename, because the queue a tier-1 APPROVE must join lives on that box. When
the box is unreachable the approve is dropped with one log line. Both now write
the row FIRST and keep the touch for one release.

**`bin/merge-queue.sh` materialises queued rows into the same empty files**, in
`enqueued_at` order and one `touch` at a time — `ls -tr` orders this queue by
mtime, and creating a batch in the wrong order would reorder landings. Only the
SOURCE of the file changes: every gate, the merge train, the head-bound approval
check, the `.blocked` convention and the FIFO are untouched. A PR with a
`.blocked` sibling is never re-materialised: that file is this queue's own
record that a human was asked to look, and putting the PR back in front of the
merge machinery would undo the parking.

Every terminal decision is mirrored onto the row — landed on both landing paths,
blocked with the reason on each of the four block paths, dropped when a PR is
dequeued because it is no longer OPEN.

**A filename cannot say why.** `.blocked` records that a PR was stopped and
nothing about what stopped it; the reason lived only in a beat that scrolled
past. `reason` is strictly more than the convention it replaces.

**`dropped` is a fourth status beyond the three the brief named,** and it earns
its place: a PR dequeued because it closed without merging has not landed and
nothing is blocking it. Recording that as `landed` would put a lie in the one
ledger a merge decision reads.

**`blocked` is re-queueable, and that is fidelity rather than a choice.**
`bin/tier2-merge-sweep.sh` tests `[ -f <Q>/<num> ]` and never the `.blocked`
sibling, so a parked PR is re-enqueued on its next pass TODAY. The table
describes the existing policy instead of quietly changing it.

### THIS IS NOT A DONE-LIST

Whether a PR has already been merged is answered by the `ledgers` row
(`kind=merge`) `bin/merge-sweep.sh` has written since phase 2, and by nothing
else. `merge_queue.status='landed'` is a queue state, not a merge fact: a second
copy of "has this merged" would drift, and the copy that drifts is the one that
merges something twice.

`state/merge-sweep-done.txt` therefore stays exactly as phase 2 left it — a
WRITE-THROUGH cache in front of that ledger, read FIRST so a worker outage falls
back to the file and never to "not merged". That fail-CLOSED read is a safety
property, not duplication, and removing the file would delete it. Nothing in
this change touches `bin/merge-sweep.sh`.

### Still ssh after this

The `touch` hop itself, kept for one release as the fallback — a tier-1 APPROVE
that reaches no queue is invisible rather than loud, which is the failure worth
being conservative about. It is removed once a fleet-week has passed with
`bin/merge-queue.sh` materialising rows on every box.

### Review fixes (2026-09-10, adversarial review of #224)

- **The enqueue respects `MERGE_TRANSITIONS`** rather than forcing `queued`
  through the upsert. Every move it makes today is legal; the point is that the
  GRAPH decides, or the next status added here disagrees with PATCH silently.
- **FIFO has a tiebreak** — `ORDER BY enqueued_at ASC, pr ASC`. Two PRs enqueued
  in the same second otherwise come back in scan order, and `bin/merge-queue.sh`
  materialises them by touching files whose mtimes tie as well, so `ls -tr`
  would decide the landing order. A queue that reorders landings is a different
  queue.
- **`MQROW` on a 404 creates the row instead of dropping the outcome.** A PR can
  reach this queue as a FILE (run-build's tier-1 conflict path, review-prs.sh, a
  hand `touch`) with no row behind it. Silently discarding its outcome would
  leave the ledger incomplete in exactly the case a human goes looking for — a
  PR that blocked, on a box whose producer has not moved to rows yet.
- List limits clamp with `Math.max(1, …)`: SQLite reads `LIMIT -1` as unbounded.

## The ledger watermark, and what a staging failure costs (2026-09-11)

`bin/run-triage.sh` pulls finished builds from the artifact feed and stages each
into a build dir the results-sweep already knows how to close out. Two things
stop a row being staged twice: a per-`job_id` marker in
`state/remote-results/<p>/.handled`, and a watermark in
`state/remote-results/<p>/.since` that asks the feed only for rows newer than
the last one seen. The markers are box-local; the watermark is the durable half,
so a rebuilt box replays nothing rather than everything.

**A staging failure freezes the watermark for the WHOLE PASS.** Per-row is not
enough, and the reason is the feed's order: it returns the NEWEST 50 rows first,
so a newer row this box deliberately skips (its own builds) would carry the
watermark past an older row that failed to stage — burying that close-out
permanently. Freezing the pass is the only rule that cannot do that.

### What that costs, stated rather than implied

While a row keeps failing, the watermark does not move, so **every row in the
window is re-read on every tick**. That is cheap and it is not starvation:

- **Newer rows still stage.** They are re-read, they stage on their first pass,
  and their own `.handled` markers stop them staging twice. Nothing queues up
  behind the failing row.
- **The failing row self-heals out of the window.** The feed is the newest 50;
  as the fleet produces more results the stuck row falls off the end and stops
  being offered. At that point the watermark is free to advance again.
- **The cost of that self-heal is exactly one close-out** — the failing row's.
  Its ticket keeps its PR and its build record; what it loses is the automatic
  board comment, which a human or a re-run can still post.

That is the trade, and it is the right way round: a lost close-out is visible
(the ticket sits without its comment) while a wrongly-advanced watermark is
invisible (the comment simply never comes, and nothing says so).

**A staging failure alerts once per project per day** (`flags/alerted-ledger-
stage-<project>-<YYYYMMDD>`, the same shape `bin/jobs-client.sh` uses for its own
outage line). The retry is the point of the freeze, so the same row returns every
tick — at six ticks an hour that would be 144 identical pages a day, which is how
a channel stops being read. The per-row detail still goes to the project log on
every tick; only the paging is bounded.

## The pool result travels as a row (2026-09-11)

`bin/fly-pool.sh` reaped a finished machine and **pushed** the result into the
owning box: the json over ssh into `cat`, RESULT/review/plan into the box's
build dir, and a `touch` on its merge queue. The box has PULLED the same result
from the job row since #229 — with the one-dir guard that stops both landing —
so both paths ran and the guard deduped them.

**Row first, ssh only as a fallback.** The reap now READS THE LEDGER BACK before
deciding: the `result` artifact is written by `run-build.sh` on the MACHINE, not
by the reap, so "the row exists" is something only a query can answer. A write
nobody made and nobody verified is exactly the assumption that strands a
close-out. When the row is there, nothing is ssh'd; the tier-1 APPROVE hand-off
is a `merge_queue` row (#224) rather than a touch.

**Three failures, three messages, three actions** (review of #233). "The ledger
did not take it" was one sentence for three faults with different remedies:

| condition | action | alert |
|---|---|---|
| the feed could not be read | full ssh push | `LEDGER UNREADABLE` |
| the feed answered, no result row for this key | full ssh push | `NO RESULT ROW` |
| result row present, `merge_queue_put` failed | **merge-queue touch only** | `MERGE-QUEUE ROW FAILED` |

Unknown is not absent: reporting a dead worker as a missing row sends a human
hunting a row that may well exist. And a failed merge row is no reason to
re-push a result that is already travelling — only the enqueue is missing, so
only the touch is sent, and the hub json and custody stay exactly as on the row
path. The merge-queue touch rides either fallback **only when the row did not
take it**; a successful #224 row needs no filename.

**One alert per project per day, PER REASON.** The dated flag carries the reason
slug, so a merge-row failure cannot silence a dead ledger or the other way
round. Every affected key still appears in `fly-pool.log`.

**The hub json is kept on the row path.** Today's code deletes it after a
successful push because the box copy is live. On the row path nothing was
pushed, so nothing has provably arrived — deleting the only other copy on the
strength of a row the box has not read yet is the wrong way to be tidy.
`RELAYED` still marks custody for `bin/queued-fly-relayed.sh`.

## fleet.conf answers "where is this box" (2026-09-11)

Nine scripts carried their own copy of the fleet's tailnet addresses — some
keyed on a project, some on a short box label — so a box that moved had to be
found in nine places, and the registry genuinely could not answer the question.
That is why every one of them sat in
`tests/fleet-projects-allowlist.txt` rather than being fixed.

`fleet.conf` gains a 7th column, `tailnet_ip` (additive, nullable; every active
row migrated), read through `bin/fleet-conf.sh --tailnet-ip <project>` and
`--tailnet-ip-of-box <box>`.

**Both fail closed: empty output AND a nonzero rc.** An unknown address must
never become `root@`, which HANGS rather than erroring — and a hang is what
every timeout in this fleet is already fighting. Each caller skips, and the two
signals let a caller pick `|| continue` or `[ -n "$IP" ]`.

Five files stopped enumerating fleet projects entirely and left the allowlist:
`fly-dispatch.sh`, `fly-envbundle.sh`, `fly-pool.sh`, `fly-results-ingest.sh`,
`claude-auth-check.sh` — the guard reports **22 files, down from 27**. The ones
that remain are there for a DIFFERENT reason now, and their entries say so: a
label→project map whose LABELS are on-disk keys (`state/cost/` directory names
and `cron/*.cron` basenames a parity test asserts on). The addresses are gone
from those files too; only the labels stayed.

**`bin/alert-triage.sh`'s box list is now derived**, which changes behaviour in
one honest way: it used to probe five literal addresses, one of them the
project-10 box PARKED and commented out of the registry since 2026-08-25.
Deriving the list stops a parked box being probed for ever, and makes a new box
appear with no code change.

**`bin/fly-pool.sh` also takes `HARNESS="${HARNESS:-/root/harness}"`.** It was
hardcoded, so nothing in that file had ever been driven by a test — and a suite
that set `HARNESS` passed VACUOUSLY: the script used `/root/harness`, found no
flag, exited 0, and "no ssh happened" was true because nothing happened at all.

## Hub ledgers of record (BH-397)

Five per-project files are mirrored to D1 tables so the fleet can read them from
any box, but the **file is the ledger of record**. `bin/jobs-client.sh` carries
nine verbs across those five files; the worker half is `worker/jobs/src/routes/`
(`pr-owners.js`, `decisions.js`, `telegram-topics.js`, `ledger.js`) and `worker/jobs/schema.sql`.

| file | table | row | verbs |
|---|---|---|---|
| `state/pr-owners/<owner>_<repo>.json` (since BH-5003 the MIRROR: the `pr_owners` rows are the record, see below) | `pr_owners` | `{repo, number, project, state, since, reason, key, url, author, draft, dirty_since, closed_at, actor, updated_at}` | `pr_owners_put`, `pr_owners_list` |
| `logs/decisions.log` | `decisions` | `{stamp, project, gate, scope, ticket, line, created_at}` | `decisions_put`, `log_rehydrate` |
| `logs/findings.log` | `findings` | `{stamp, project, ticket, lens, line, created_at}` | `findings_put`, `log_rehydrate` |
| `state/telegram-topics.json` | `telegram_topics` | `{project, thread_id, actor, updated_at}` | `telegram_topics_get`, `telegram_topic_set`, `telegram_topics_sync` |
| read side of conductor `pr-state.tsv` | `ledgers(kind=pr_state)` | ledger key/status rows | already writes via `mc_ledger_put`; reads use `ledger_page` |

### Rows that are the record (BH-5003)

Three paths moved the other way: the D1 row decides and the file is its mirror,
still written exactly as before (wave 6, #5005, deletes the files).

| path | record | file (mirror) | rollback knob |
|---|---|---|---|
| PR owner clocks | `pr_owners` open rows (`closed_at IS NULL`). `bin/pr-owner-sweep.sh` keeps a file entry only when D1 holds an open row for that PR, unless D1 answered rc 2, an outage, the 500-row cap, or the file's `push_pending` says the last PUT did not land | `state/pr-owners/<owner>_<repo>.json` (+ `push_pending`) | `PR_OWNERS_ROWS_RECORD` (lane `pr-owner-sweep`) |
| build notes | `ledgers(kind=build_note, key="<project> <KEY>")`, `pending` -> `consumed` or `relayed`; consumed through `POST /api/ledger/claim` so one box uses a note once | `state/build-notes/<project>/<KEY>.md` on the hub | `BUILD_NOTE_DB` (`_lib.build-note-db`) |
| daily digest send-once | `ledgers(kind=daily_digest, key=<D>)`, claimed as `sending` before the send, then `sent` or `send-failed` | `state/daily-digest/sent-<D>` | `DAILY_DIGEST_CLAIM`, `DAILY_DIGEST_CLAIM_STALE_S` (lane `daily-digest`) |

`POST /api/ledger/claim {kind, key, status, actor?, detail?, terminal[<=8], stale_s 30..86400}`
is the ledger's compare-and-set: one upsert whose UPDATE arm runs only when the
row's status is not terminal and (differs from `status`, or is `status` older
than `stale_s` on the worker's clock). It answers `{claimed, ledger, as_of}`.
The client verb is `job_ledger_claim` (rc 0 won, 3 held, 2 route absent or
off-contract, 1 outage).

The two append logs have their **own tables**, not `ledgers` rows. That is what
makes `log_rehydrate` work at all: `GET /api/decisions` and `GET /api/findings`
are the only routes that take a `since` cursor and answer
`{rows, truncated, as_of}`, and `ledgers` is reserved for `pr_state` and the
other key/status kinds.

### Write-through ordering

**File first, row second.** The ordering belongs to the CALLER: it appends its
local file and only then calls the matching verb, so a 5xx or an unreachable
worker leaves the box with exactly the data it had. The write-path verbs write
no file at all. Only the two read-path verbs own a file (`log_rehydrate`,
`telegram_topics_sync`), and both write it atomically from D1.

### Read rules

- `pr_owners_list` returns the D1 rows shaped back into the file format, and
takes `generated_at` from the route's own `as_of` (the local clock is only the
fallback for a payload that carries none). A caller that also holds the file
overlays a row only when `row.updated_at >= file.generated_at` — both stamps are
the worker's, so the comparison is between one clock.
- `log_rehydrate` recreates `decisions.log` / `findings.log` from D1 only when
the file is absent or empty. A non-empty file wins, and costs no request.
- `telegram_topics_sync <file> [max_age_secs=600]` fetches D1 and atomically
writes `{"topics":{...}}` to `<file>` only when the local copy is older than
`max_age_secs` or missing. A file younger than the window is left untouched and
costs no request. Both the path and the window are the caller's to choose. When
D1 is empty and a local file exists, it seeds D1 from the file instead (reading
both the root-map and the `.topics` shape) and leaves the file alone.

### Outage behavior

Every verb returns nonzero and prints nothing on outage, exactly like the rest
of `bin/jobs-client.sh`: rc 1 for a transport failure, a 5xx, any other 4xx or an
unset `HARNESS_SECRET`, rc 2 for a real "no rows" answer, rc 0 only with a 2xx.
The existing daily `harness-jobs unreachable` line in `logs/ALERTS.log` is the
degraded-mode alert — one a day, not one per call. The local file path is
unchanged and every reader falls back to it.

A row the worker would REFUSE is not an outage. `telegram_topics_sync`'s seed
loop validates each entry against the route's own rules (project
`^[a-z0-9_.-]{1,64}$`, `thread_id` a positive integer) and skips the ones that
fail with a line in `logs/jobs-client.log`, so one unusable entry neither pages
nor stops the rest of the map. `thread_id` is an integer end to end: the file
stores one, the verb sends one, the table is `INTEGER`, the route answers one.

### Caps

- **200 rows per POST** for `decisions_put` / `findings_put` — the worker answers
413 above it. Callers keep batches at or below this; the verbs do not split.
- **5000 per rehydrate** GET for `log_rehydrate`. The worker measures
`truncated` by fetching one row past the limit, and the verb logs the flag it
was given: `rehydrated <n> <kind> rows (truncated=<bool>)`.
- **500 rows per `pr_owners_list`**, applied by the route (open rows only). The
client sends no `limit` of its own.
- 5 pages of 1000 rows for `pr_state` via `ledger_page` (`/api/ledger` caps
`limit` at 1000 and pages backwards on `before=`).

### Named gaps

- There is **no catch-up** for a row the file got and D1 missed. If a local log was
appended while the worker was down, that line is not backfilled to D1 by these
verbs.
- `bin/iron-law-guard.sh` and `bin/outcome-metrics.sh` still append to
`findings.log` file-only; they do not call `findings_put`.

## Two ways a close-out went missing (2026-09-11, project-3 TK-139)

Both defects are the row path meeting assumptions the scp path had quietly
satisfied. Neither fails loudly: the build succeeds, the PR opens, and the
client's ticket simply never hears about it.

### 1. "Already staged" was a question about the TICKET

Both staging loops in `bin/run-triage.sh` asked *"does any
`builds/<project>-<KEY>-remote*` dir exist"* and treated a hit as "this result
is already in hand". A ticket is built more than once as a matter of course — a
deferral, a fix round, a re-queue — so one older dir swallowed **every later
result for that ticket, permanently**. TK-139 had an earlier `BUILD_DEFERRED`
dir from the same day; when the real build finished, its `result` row was
marked `.handled` and skipped for good.

The identity is now the BUILD, and each loop tests its own path first:

| path | own identity | written into the staged RESULT |
|---|---|---|
| ledger row | `JOB_ID: <job>` | already did |
| relay json | `BUILD_DIR: <name>` | new line |

**The cross-path half is the MACHINE's build dir** (BH-1041, 2026-09-19). The
hub's own copy of a build is named `pool-<project>-<key>-<ts>`, which is a hub
path and means nothing to the row — but the name the MACHINE built under is one
both paths carry: the row's `detail.build_dir` (written by `bin/run-build.sh`'s
`_job_finish`) and the relay json's `machine_build_dir` (read off the RESULT's
`BUILD_DIR:` line by `bin/fly-results-ingest.sh` and `bin/fly-pool.sh`) are the
same string. Whichever path stages first writes it into the staged RESULT as
`BUILT_AS: <machine build dir>`, and the other path's guard greps for that line.
A json or row with no such identity (an older sender) falls back to its own
path's guard and is staged on its own.

The RESULT's first line is **not** that identity and the earlier `RR_SAMELINE`
text test is deleted: the pool truncates the line at 200 bytes, the pr-verify
gate rewrites it to `RESULT_UNVERIFIED`/`RESULT_MALFORMED`, and the
builder-direct marker is appended to it — so the two paths routinely hold
different text for one build, and two different builds that concluded the same
sentence held the same text.

The ledger guard deliberately does **not** consult the relay path's
`.handled/<key>.json` markers: those are keyed on the ticket, and reading them
there would put the ticket-keyed blocking straight back.

### 2. The gate stood in front of the staging, and could not see a row

The staging block sat AFTER the gate's `SKIP` exit, so a finished build could
only be brought onto the box on a tick the gate had already decided to pay for
on other grounds. On 2026-09-11 the pool result landed at 01:40Z and the 01:16 /
01:26 / 01:36 / 01:46 ticks each exited `rc=skip :: gate queue-unchanged`.

Two changes, because either alone leaves a hole:

- **Staging runs before the gate decision.** It is deterministic, costs nothing
  and makes no model call; a COST gate has no business in front of it. It also
  needs nothing the gate produces, and the per-project flock is already held.
- **The newest result row is published as a file the gate can hash.**
  `bin/triage-gate.sh`'s queue brake hashes FILES — `READY-QUEUE.log`, the queue
  dir, the build dirs — and holds a 45-minute skip window over them. While
  results arrived by scp, a finished build perturbed one of those files by
  accident; as a row it perturbs none. `state/<project>.result-rows` carries the
  newest `result` row's timestamp and joins that hash.

`result-rows` records the newest row **seen**, not the newest row this box is
**done with**. The watermark (`.since`) advances only for rows the box
accounted for, so a row whose staging failed would leave it frozen — and a
failed staging is exactly when the gate most needs to open.

## Pre-plans as rows (BH-658, 2026-09-17)

Shipped in slices: the client verbs are #773 and the worker table and routes are
#774 (this section); the publish hook, hub relay, adopt outcome, evidence row and
overlap-guard source land with #775, #776 and #777.

`bin/run-preplan.sh` pays Fable to plan a queued ticket before its build starts
and leaves the consumable record in `plans/<project>-<KEY>/` — `plan.md`,
`base-sha`, `planned-files.txt`, `ticket-fp`, `key`. `bin/fly-pool.sh:push_preplan`
relays that record to the Fly machine that will build the ticket, and read that
directory **on the hub**. The hub is forbidden to pre-plan (`bin/lib/hub-box.sh`,
docs/HUB-THINNING-PLAN.md), so on the hub it is always empty: every Fly build
re-planned from scratch — 7-10 minutes of a 60-75 minute ticket — and no line
anywhere said so. On box-project-4-1, 0 of 1052 build records carried a
`PREPLAN_` line while that box's own `plans/` held 58 plan dirs.

The missing hop is box → hub, and it is one row.

```
POST /api/preplans   { project, ticket_key, base_sha, plan_md,
                       planned_files?, ticket_fp?, box? }   -> { preplan } (no plan_md)
GET  /api/preplans?project=&key=                            -> { preplan }  | 404
GET  /api/preplans?project=                                 -> { preplans } (index, no bodies)
```

| decision | why |
|---|---|
| its own table, not the queue row's `meta` | `meta` is capped at 4000 chars and a plan is 10-40KB. A **truncated** plan is the one failure worse than no plan: the builder executes half a design. |
| `PRIMARY KEY (project, ticket_key)`, `base_sha` a column | the only plan anyone should adopt is the NEWEST one for that ticket; an older `(…, plan_sha)` row would be a stale plan waiting to be picked up, with its own reaper to write. |
| over-cap is **413**, never a tail | unlike a transcript, a plan is an instruction. The box logs `REFUSED (413)` and the build plans fresh. `planned_files` is refused over its own cap for a sharper reason: `preplan_check` and the overlap guard only judge files they can see, so a list cut short fails OPEN on everything past the cut. |
| `400` on an empty `plan_md` or a non-sha `base_sha` | with no base sha `preplan_check` can never judge freshness, and an unjudgeable pre-plan is discarded at adopt — so it is never stored. |
| retention inside the POST | one bounded `DELETE FROM preplans WHERE updated_at < now-14d`, no sweep, no cron. Older than that is older than any queued build it could serve. |
| only Fly-routed projects publish | `flags/builder-fly-<project>` — the same test `bin/free-slots.sh` and `bin/lib/build-caps.sh` use. A local project's builder reads `plans/` off its own disk, so a row would have no reader. That flag also covers **fly1** projects (`builder-fly` without `fly-pool`), and `bin/fly-dispatch.sh` has no relay at all, so a fly1 project's row is written and never fetched: a pre-existing gap, not a regression, and the reason a fly1 build's `PREPLAN_MISS` is not a relay defect. |
| no secrets, by construction | `plan_md` is planner prose, `planned_files` is repo paths, `ticket_fp` is timestamps and a comment count. Nothing in a plan can come from `env/`. |

**Client verbs** (`bin/jobs-client.sh`): `preplan_put <project> <key> <dir>`
(rc 0 published, **rc 3 refused** — the worker answered `4xx`, so the row is not
there and a retry would be refused the same way, **rc 1 unreachable** — no
answer, or a `5xx`: we do not know), `preplan_get <project> <key>`
(rc 2 = a real miss, like `queue_status`), `preplan_index <project>` (TSV, with
`planned_files` newlines flattened to `|`).

**Fail-open, at every hop.** A refused or unreachable worker never changes
`run-preplan.sh`'s exit code; `push_preplan` returns 0 on every path and writes
one `fly-pool.log` line either way; `bin/overlap-guard.sh` still answers `LAUNCH`
when it cannot ask. The cost of every failure is one PLAN stage, which is what
today costs anyway.

**Nothing is silent any more.** The builder's adopt block writes
`$BUILD/preplan-outcome` (`HIT|STALE|MISS|OFF <why>`) and the matching
`PREPLAN_*` line in `pipeline.log` on **every** branch, and
`bin/evidence-summary.sh` renders it as the `| pre-plan | … |` row of the PR
body's evidence block. The adopt also now compares the plan's `ticket-fp`
against this run's fingerprint BEFORE `preplan_check`: a plan written against an
older thread is discarded and the build **plans fresh in the same run**, where
copying that fingerprint into `$BUILD` used to trip the resume-stale gate and
end the build as `PLAN_STALE` — on a Fly machine, that is the machine wasted.

**The table lands with the deploy, because the route creates it.**
`bin/harness-sync.sh` runs `npx wrangler deploy` for a worker whose tree sha
moved, and that is ALL it does — there is no `wrangler d1 execute` anywhere in
`bin/`, `cron/`, `fly/` or `.github/`, so re-applying `worker/jobs/schema.sql`
against the live database is a HAND step (worker README, Deploy). A new table
that waits for that hand step ships **dead**: the code reaches every box in
minutes, every statement against the missing table throws, and the routes answer
`500` while the client reports an outage — the TK-64 shape, and what `hub_lease`
did. So `src/index.js:ensureTable` holds the same `CREATE TABLE IF NOT EXISTS` /
`CREATE INDEX IF NOT EXISTS` as literals and runs them, memoised per `env.DB`
handle, before the first `preplans` statement in either route — the whole-table
counterpart of `ensureColumns`. `schema.sql` carries the identical definition:
it is the readable one and what a fresh database is built from.

Scripts that land before the worker redeploys get a `404` from the POST, which
the client classifies as REFUSED and the box logs as such — today's behaviour
plus one line. A `5xx` is classified the other way, as **unreachable**: the
worker breaking is not the worker judging the plan, and "REFUSED" would send
whoever reads the log at the payload instead of at the server.

Suites: `worker/jobs/test/index.test.js` (`--test-name-pattern preplan`),
`tests/preplan-client-test.sh` (#773). The verification-map entry for the relay
lands with #775.

## Hotfix go-live (BH-370)

Normal migrations ride the slow path on purpose: PR, human merge, Vercel
deploy, and then the `*/15` tick in `bin/apply-migrations.sh` notices the file
is pending in the running bundle and asks the app to apply it. That is right for
ordinary work and too slow for a hotfix, where the schema change and the code
that needs it have to land together. The hotfix lane is the fast path for a
ticket labelled `hotfix`, and `bin/hotfix-migrate.sh` is the stage that runs it.

The rule the whole lane is built around: **a hotfix that cannot show its work is
not a hotfix, it is an unreviewed production write.** So every outcome, good or
bad, ends in a proof comment on the PR, and nothing downstream accepts a hotfix
without one.

### The two shapes

- **endpoint** (shipped here). `project-1`, `project-2`, `project-3`,
  `project-4`. The app applies its own deployed SQL through
  `/api/internal/migrations` (`docs/MIGRATION_ENDPOINT_SPEC.html`); the box
  holds no DB credential and never will.
- **workflow** (BH-370.3, `bin/lib/hotfix-migrate-workflow.sh`). Projects with
  no endpoint but a dispatchable migration workflow — project-5's shape. This
  slice leaves the seam and nothing else: mode `workflow` sources that lib if it
  is present and dispatches `hm_workflow`, and says `no-path` if it is not.

A project with neither answers `no-path` and names what is missing.

### The spec conflict, and how it is resolved

The endpoint takes a filename, never SQL, and a file is only *pending* once it
is in the RUNNING bundle — which by construction means the merge that carries it
is already deployed. A hotfix stage runs BEFORE the merge. So on the fast path
the honest answer is usually "not yet": every requested file comes back
`not-pending`, the decision is `deferred-to-deploy`, and nothing is applied.
That is not a failure and it is not a hold. BH-370.4 (`bin/hotfix-after-deploy.sh`,
not yet written) will read this stage's ledger and apply the same files as soon
as deploy-verify passes, which is as fast as the endpoint shape can physically
be. **Until that slice ships, a `deferred-to-deploy` hotfix is applied by the
ordinary `*/15` tick**, i.e. within 15 minutes of the deploy — later than the
lane intends, and never silently skipped.
When the files ARE already in the bundle (a re-run, a second build of the same
SQL) the decision is `applied` and the work is done in the stage.

### The proof comment

First line, exactly:

```
<!-- hotfix-migrate-proof fp=<FP> decision=<applied|deferred-to-deploy|hold|flagged|no-path> -->
```

then plain text: the file names, the per-file result (the endpoint's own status
JSON, or the workflow run URL and its last 60 log lines), the quiet-window
decision per file, and for every **data-edit** file — one carrying an `UPDATE`
or `INSERT` statement — the exact revert statement: the file's own `-- revert:`
line verbatim if it declared one, else

```
<file>: REVERT: none declared in file - write one before applying by hand
```

Files with no data edit print no revert line at all. Detection reads statements,
not text: comments are stripped first and the match is anchored at the start of
a statement, so a column named `updated_at` and a `-- INSERT later` note are not
data edits.

`FP` is the fingerprint: sha256 over the sorted `"<path> <git blob sha>"` lines
of the PR's ADDED migration files: `scripts/migrations/*.sql`,
`prisma/migrations/manual/*.sql` (or `$HOTFIX_MIGRATE_GLOB`), and the project's
`migrations_glob.<project>` row when it is set. Same bytes, same FP — so a rebase that leaves
the SQL alone keeps the proof, and any edit to the SQL invalidates it.

**Accepted by the conductor**: `applied` or `deferred-to-deploy` with a matching
FP. `hold`, `flagged`, `no-path`, a stale FP or no marker at all are not
accepted. (The conductor-side guard is BH-370.2, not this slice.)

### The ledger

`$BUILD/hotfix-migrate.json`, written atomically:

```json
{"fp":"…","mode":"endpoint|workflow|none","decision":"…",
 "files":[{"path":"…","status":"…","run_id":"…"}],
 "posted_comment_id":4242,"after_deploy":null}
```

Order is load-bearing: **side effect → result → ledger (id null) → comment →
ledger (with id) → exit code.** A ledger saying `applied` with
`posted_comment_id: null` is a real, honest state — the SQL ran and the proof
did not post — and the stage exits 3 for it, so "stamped done without delivery"
cannot happen. The next run of that fingerprint re-posts the proof from the
ledger and applies nothing.

### Exit codes of `bin/hotfix-migrate.sh`

| rc | meaning | what run-build does |
|---|---|---|
| 0 | `applied` or `deferred-to-deploy` | `QA_NOTE += " \| HOTFIX-MIGRATE: <decision>"` |
| 2 | `flagged` — the appliability gate refused the SQL, nothing applied | tier 2 + note |
| 3 | `hold` — checks not green, a failure word, a proof that would not post | tier 2 + note |
| 4 | this PR adds no migration files (nothing posted, no ledger) | nothing |
| 5 | `no-path` | tier 2 + note |
| 75 | busy — another run owns this fingerprint | tier 2 + note (`busy`) |

The stage never blocks the PR. Only the unattended merge is withheld, exactly
like the MIGRATION GATE.

### Where it runs

`bin/run-build.sh`, between `STAGE_END settle` and the tier-1 merge gate, inside
`# >>> hotfix migrate stage` … `# <<< hotfix migrate stage`. It fires when a PR
URL exists and this build is the emergency one. It does not decide that second
part itself: `HOTFIX` is already settled by the `# >>> hotfix detect` block and
the pr-open second opinion (#368), and the tier-1 merged announcement below
reads the same global, so this block only READS it and never assigns it.

The answer it reads, in order: `HOTFIX=1` from the build's own detect (a resumed
Fly build carries it in the job env with no usable `ticket-meta.json`);
`HOTFIX_ISSUE=1` as the hand-run override; otherwise `$BUILD/ticket-meta.json`
as the second opinion, asked through `hotfix_meta_is` in
`bin/lib/hotfix-lib.sh`, so the `HOTFIX_LABEL` knob and the exact whole-name,
case-insensitive match apply (`hotfix-candidate` is not a hotfix). A raw `jq`
read of the label stands in only when the lib is not loaded. Last, the lane kill
flag wins over every one of those: with `flags/hotfix-lane-off` present or
`HOTFIX_LANE=0`, the stage is inert even with the label and `HOTFIX_ISSUE=1` —
a kill switch a hand-run env var can step over is not a kill switch. Everything
else is inert.

### `bin/apply-migrations.sh --files`

The same driver, asked about specific files instead of "whatever is pending":

```
bin/apply-migrations.sh <project> --files <basename> [<basename>…]
```

One JSON line per requested basename, in the order given, and an exit code that
is 0 only when every one of them came back `applied` or `already-applied`. The
POST itself is the same `apply_one` the cron tick runs, so the refused-memory,
the `apply <F>: status=… ok=…` log line and the beat cannot drift between the
two modes. Other exit codes: 1 (a file was not pending / a request failed), 2
(usage), 5 (this project has no endpoint), 75 (the `*/15` tick owns the lock —
never a wait, the caller is re-offered).

A `GET /status` that answers 200 with something that is not JSON (a maintenance
page, a WAF interstitial) counts as a failed request, not as an empty pending
list: every file comes back `request failed`, rc 1, and the hotfix stage holds.
Reading "unparseable" as "nothing of yours is pending" would have recorded
`deferred-to-deploy` and exited 0.

The no-arg cron path is unchanged, including its silent `exit 0` on the six
boxes whose projects have no endpoint at all.

### Knobs (all in `env/<project>.env`)

| knob | default | what it does |
|---|---|---|
| `HOTFIX_MIGRATE_MODE` | `endpoint` for the four endpoint projects, else `workflow` when `HOTFIX_MIGRATE_WORKFLOW` is set, else `none` | forces a shape; anything outside `endpoint\|workflow\|none` is a usage error (exit 2) |
| `HOTFIX_CI_WAIT` | `1200` | seconds to wait for the PR's checks before holding; clamped to a minimum of 1 (`timeout 0` means *no limit* in coreutils) |
| `HOTFIX_MIGRATE_WORKFLOW` | unset | the dispatchable workflow for the workflow shape (BH-370.3 reads it) |
| `HOTFIX_MIGRATE_GLOB` | `prisma/migrations/manual/*.sql` | where the workflow shape's migration files live |
| `migrations_glob.<project>` (a settings row, not env; `bin/lib/migrations-glob.sh`) | `scripts/migrations/*.sql` | where the endpoint and `none` shapes look for the PR's added SQL, IN ADDITION to `scripts/migrations/*.sql`. The merge conductor's proof gate (`mc_hotfix_proof`) counts the same row, so both sides fingerprint the same files; an unreadable row makes the gate answer `missing` and the PR waits. Must be `<dir>/*.sql`, relative, no `..`; `*` does not cross `/`. An invalid value or an unreadable row uses the default and writes one stderr line. `bin/scope-gate.sh` protects the dir in addition to `scripts/migrations/`, and the reviewed-merge sweep's MIGRATION GATE alert names a file from it. Set: `bin/jobs-client.sh setting-set migrations_glob.<project> '<dir>/*.sql'` |
| `hotfix_migrate.conf.<project>` (a settings row, not env; `bin/lib/hotfix-migrate-knobs.sh`, BH-9403) | no row | one JSON object whose keys beat the env knobs of the same meaning: `workflow`, `files_input`, `max_files` (1..50), `dispatch_ref`, `branch_input`, `file_form` (`path`\|`basename`), `glob` (`<dir>/*.sql`, added to the workflow shape's globs), `per_file`, `approve_head`, `before_merge` (each `0`\|`1`), `needs_quiet` (`off`), `local_gate` (`strict`\|`advisory`), `gate_workflows`, `log_cap_kb` (default 2048). An invalid key is ignored with one stderr line; an unreadable row keeps the env values. `"before_merge":1` runs this stage for a NORMAL PR whose build verdict is APPROVE for the head it holds. Kill switch: `"before_merge":0`. Set: `bin/jobs-client.sh setting-set hotfix_migrate.conf.<project> '<json>'` |
| `HOTFIX_LABEL` (not this slice's; owned by `bin/lib/hotfix-lib.sh`, read from `env/global.env`) | `hotfix` | the label that makes a ticket the emergency one, here and in every other #368 lane |
| `HOTFIX_LANE` / `flags/hotfix-lane-off` (same owner) | lane on | `0` / the flag file makes the whole hotfix lane inert, this stage included |

### Reading the checks

The ticket's read is `gh pr checks "$PR_URL" --required --watch --fail-fast`,
and it is tried first. It answers nothing on this fleet today, for two separate
reasons and not just the one: the PATs here get `Resource not accessible by
integration` out of the checks GraphQL (same wall as the incident header in
`bin/lib/gh-ci-read.sh`), and `--required` reports nothing at all on a repo that
has no branch protection. `cromford` itself answers `no required checks
reported on the '<branch>' branch`, rc 1, even for a token that CAN read checks.
So on every repo we build in today the Actions-runs read is the real read, and
the stage falls back to it, through `gh_ci_api`, under the same `HOTFIX_CI_WAIT`
deadline. Green needs at least one run and every run completed with
`success`/`skipped`/`neutral`.

**The fallback is only for "nobody could read it."** `gh pr checks` exits 1 both
when the read failed and when a check is RED, and the stage must not conflate
them: a required check that is not an Actions run (Vercel, Mergify and
CodeRabbit all sit on this repo's PRs) can be red while every workflow run on
the sha is green, so a fallback that fires on any nonzero rc would let the
weaker read overrule an explicit failure. A `fail` row in `hotfix-checks.txt`,
or a primary read that hit the deadline (`timeout` rc 124), is a hold on the
spot and the Actions read is never consulted. Only an unreadable answer — empty
output, `Resource not accessible`, `no required checks reported`, an HTTP 4xx or
5xx — reaches the fallback.

**No readable answer by the deadline is a hold, never a pass** — "we could not
tell" and "it passed" are different answers and only one of them may reach a
production database.

### Running it by hand

```
bin/hotfix-migrate.sh <project> <build-dir>
```

It takes the branch from `<build-dir>/branch` (else `ticket/<key>`), the slug
from the worktree's `origin` remote, and the PR URL from `<build-dir>/RESULT`,
falling back to `gh pr list --head`. The WORKTREE is the one thing it guesses by
convention — `/root/worktrees/<project>-<key>` unless `WT` is exported — and a
path that is not a checkout is a fail-closed exit 3 naming the path it tried,
because there is nothing to fingerprint and therefore nothing to post. On a box
with slot worktrees, export `WT=` yourself:

```
WT=/root/worktrees/<project>-slot1 bin/hotfix-migrate.sh <project> <build-dir>
```

Read `<build-dir>/hotfix-migrate.json` and the PR's proof comment afterwards;
those two agreeing is the whole verification.

**Proved against stubs only.** The endpoint shape here was driven entirely
against stub `gh` and `curl` binaries in
`tests/hotfix-migrate-endpoint-test.sh` — no real `/api/internal/migrations`
call has been made from this code. The real proof is a human running the command
above on a hotfix build dir of one of the four endpoint projects and checking
that the ledger's decision matches the endpoint's own `MigrationApplied` row.
