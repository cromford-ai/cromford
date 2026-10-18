-- Its own statement, for the reason the comment above gives. BH-1484: the hub
-- and the pool boxes share ONE App installation, so a single 6,600/h primary
-- bucket carries every lane on every repo — measured at ~5,700/h on
-- 2026-09-22, draining in the last five minutes of each window. This is how
-- many calls bin/lib/gh-rest.sh keeps back for decision-critical reads: below
-- it, a read the CALLER marked optional (GH_REST_OPTIONAL=1) is refused BEFORE
-- the request instead of spending headroom a merge decision will need. The
-- code fallback in bin/lib/gh-rest-ledger.sh is the same 600; this row is what
-- lets an operator move it without a deploy.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('gh.quota.reserve','600','BH-1484: REST calls kept back from the shared GitHub App bucket; below it GH_REST_OPTIONAL reads answer rc 75 quota-reserve and decision-critical reads still go','seed','2026-09-22T00:00:00Z');

-- Its own statement, for the reason the comment above gives. BH-1526: WHO THE
-- LEAD IS. A lead-authored PR is exempt from the merge-time HOLD (the hold
-- reserves the ticket FOR it) and always wins the one-PR-per-ticket rule over a
-- pool PR (bin/lib/ticket-ownership.sh). Space- or comma-separated GitHub
-- logins; a row nobody can read means "nobody is the lead", which holds the
-- lead's own PR at merge and closes nothing — the safe side of both decisions.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lead_pr_authors','operator','BH-1526: GitHub logins whose PRs are lead builds: exempt from the merge-time HOLD, and they win one-PR-per-ticket over a pool PR','seed','2026-09-22T00:00:00Z');

-- Its own statement. BH-1526: ONE PR PER TICKET IS OPT-IN PER PROJECT (the
-- MC_TICKET_DEDUPE knob in catalog/lanes.d/merge-conductor.json, default 0 =
-- off). Seeded ON for cromford only, where the lead and the pool race the
-- same tickets; every other project opts in from the console or harness-ctl.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.merge-conductor.cromford.mc_ticket_dedupe','1','BH-1526: one open PR per ticket on cromford (per-project opt-in; the knob defaults off)','seed','2026-09-22T00:00:00Z');

-- ── BH-1054: Fly machine registry (2026-09-19) ───────────────────────────────
-- Dark table: the worker stores live Fly machine rows only when the operator
-- knob `fly_machines_rows` is flipped to `on`. The routes (BH-1055) are LIVE,
-- so the flag is the only thing between a writer and a row; the client verbs
-- fail open either way. The flag is seeded `off` so a fresh deploy starts dark
-- and an operator edit survives re-apply.
--
-- STATE VOCABULARY (`MACHINE_STATES` in worker/jobs/src/index.js): spawned,
-- created, starting, started, stopping, stopped, failed, suspended,
-- suspending, replacing, destroying, destroyed, gone, destroy_failed.
-- `destroyed` and `gone` are TERMINAL and stamp `ended_at`. `destroy_failed`
-- is NOT terminal -- the machine is still there and the sweep retries the
-- destroy (bin/fly-pool.sh) -- so it records the refusal and leaves `ended_at`
-- NULL. `suspending`/`replacing` are Fly's own mid-transition states: they are
-- in the set so one machine caught mid-flight cannot 400 a whole observe.
CREATE TABLE IF NOT EXISTS machines (
  machine_id TEXT PRIMARY KEY,    -- Fly machine id, e.g. 178m5jv0x7z467
  project TEXT NOT NULL,          -- fleet.conf project name
  app TEXT NOT NULL,              -- Fly app name
  role TEXT NOT NULL,             -- pool | builder | ...
  key TEXT,                       -- board ticket key (TK-109) when known
  ticket TEXT,                    -- board internal ticket id
  auth_account TEXT,              -- Fly org/account that owns the machine
  image TEXT,                     -- image ref the machine was spawned from
  state TEXT NOT NULL,            -- one of the MACHINE_STATES vocabulary
  detail TEXT,                    -- free-text note, never a secret
  spawned_at TEXT,                -- ISO, server clock
  last_seen TEXT,                 -- ISO, last listing that saw it
  ended_at TEXT,                  -- ISO, when it reached a terminal state
  actor TEXT,                     -- last box to touch the row
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_machines_project ON machines(project, state);
CREATE INDEX IF NOT EXISTS idx_machines_key ON machines(project, key);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('fly_machines_rows','off','Dark flag for the Fly machine registry: on keeps live rows, off leaves the table unused. BH-1054.','seed','2026-09-19T00:00:00Z');

-- BH-1369: the dark knob for the `routing` table (declared above, before
-- settings existed). Seeded `off` like fly_machines_rows so it shows in the
-- console's settings list; absent and `off` both mean off.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('routing_rows','off','Dark flag for builder routing rows (BH-1369): on lets routing rows drive flags/builder-fly-*, fly-pool-*, fly-pool-app-*, pool-halt-*. Read once per process: a flip applies on the next process start.','seed','2026-09-23T00:00:00Z');

-- BH-1068 (split child of BH-1030): alerts table contract. id is the alert-state
-- identity, never the family; family is a grouping key derived from the line.
CREATE TABLE IF NOT EXISTS alerts (
  id TEXT PRIMARY KEY,            -- alert-state id: explicit --id or row_key(line)
  family TEXT,                    -- bin/alert_family.py family <line>
  box TEXT,                       -- box that produced the latest sighting
  project TEXT,                   -- '' = fleet-wide
  line TEXT,                      -- latest line, stamp-stripped, <= 2000 chars
  severity TEXT,                  -- info | warn | critical
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL DEFAULT 'new', -- new | quarantined | triaged | parked | resolved
  claimed_by TEXT,                -- <lane>@<box>, NULL = unclaimed
  claimed_at TEXT,
  notified_at TEXT                -- last send anywhere, NULL = never
);
CREATE INDEX IF NOT EXISTS idx_alerts_state ON alerts(state, claimed_at, first_seen);
CREATE INDEX IF NOT EXISTS idx_alerts_family ON alerts(family, last_seen);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('alert_flush_ttl_s','2700','BH-1030: seconds before a flushed-but-unclaimed alert may be re-claimed','seed','2026-09-19T00:00:00Z'),
  ('alert_claim_lease_s','900','BH-1030: seconds a claimed alert is reserved to the claiming lane','seed','2026-09-19T00:00:00Z');

-- BH-2368 (contract child of BH-2324): alert_actions, one row per operator
-- action on an alerts row from the console (ack | snooze | resolve | note),
-- including the refused ones. APPEND-ONLY: nothing updates or deletes a row,
-- and nothing dedups against it. POST/GET /api/alerts/actions
-- (src/routes/alert-actions.js) are 501 stubs in this contract and read or
-- write no row yet.
--
-- The enum values sit in comments, not CHECK constraints: D1 cannot ALTER a
-- CHECK, so a later action would need a table rebuild.
--
-- NO RLS STEP. This is Cloudflare D1, reached only through the bearer-authed
-- worker (HARNESS_SECRET) — same as every other table in this file (see
-- docs/DB-COORDINATION-SPEC.md:320,502). The Supabase RLS doctrine this repo's
-- other rules import does not apply to a D1 binding; the worker's bearer check
-- (src/lib/http.js bearerOk) is the access boundary here.
CREATE TABLE IF NOT EXISTS alert_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  alert_id TEXT NOT NULL,
  action TEXT NOT NULL,        -- ack | snooze | resolve | note
  actor TEXT NOT NULL,         -- 'console' when it came through the proxy
  note TEXT,
  before_state TEXT,
  after_state TEXT,
  until TEXT,                  -- snooze: when the console's claim lease lapses
  outcome TEXT NOT NULL,       -- ok | refused:<why>
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_alert_actions_alert ON alert_actions(alert_id, at);

-- Phase 6: the per-claim facts the rules and the policy need, in their own
-- table for the same two reasons job_heartbeats is its own table — D1 has no
-- ADD COLUMN IF NOT EXISTS, so a column cannot live in a re-runnable file, and
-- a retry counter must not contend with the spend deltas agent-call.sh writes
-- onto the job row. The API folds these onto the job it returns, so a reader
-- sees `attempts` as a fact about the job and never has to know it is a join.
--
-- `lane` is stored here because the claim already carries it (POST /api/jobs
-- takes it for budget resolution) and both new tables key on it: a lane rule
-- cannot count peers it cannot see, and a retry policy cannot resolve for a job
-- whose lane was thrown away.
CREATE TABLE IF NOT EXISTS job_claims (
  job_id TEXT PRIMARY KEY,        -- jobs.id
  lane TEXT,                      -- <stage>/<project>/<runner> as claimed
  attempts INTEGER NOT NULL DEFAULT 1,   -- 1 on the first claim, +1 on each retry pickup
  max_attempts INTEGER,           -- the policy in force when it was judged, recorded not chosen
  next_attempt_at TEXT,           -- when a queued_for_retry row becomes claimable
  escalate_allowed INTEGER,       -- copied from the policy at judgement time
  reason TEXT,                    -- why it is queued / parked, in words
  -- BH-2524 fleet file claims (BH-2627); a live table gains these via ADDED_COLUMNS.
  planned_files TEXT,             -- newline list of the files this build plans to touch
  files_claimed_at TEXT,          -- when that list was claimed
  files_expires_at TEXT,          -- when the claim lapses (FILE_CLAIM_TTL_S after the claim)
  overlap_not_before TEXT,        -- an overlap-deferred build is not re-offered before this
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_claims_lane ON job_claims(lane);

-- Phase 7: OUTCOME CONTRACTS — a phase declares what it must PRODUCE.
-- Phases 5 and 6 recorded that a stage RAN and how it ended. Neither recorded
-- what it left behind, so a plan stage that exited 0 having written no plan
-- file, or a review that closed `done` with no verdict, was indistinguishable
-- from one that did the work. The ledger said done and the artifact was absent.
--
-- A contract is a row: "a phase named <phase> must record an artifact of kind
-- <artifact_kind>, optionally matching <pattern>, before it may close done".
--
-- THIS TABLE SHIPS EMPTY, exactly like retry_policies. No row for a phase =
-- no contract = today's behaviour, so phase 7's contract half lands dark and is
-- switched on one phase at a time with one PUT /api/contracts. Emptying the
-- table returns the fleet to phase-6 behaviour precisely.
CREATE TABLE IF NOT EXISTS phase_contracts (
  phase TEXT PRIMARY KEY,         -- plan | execute | review | merge | qa | ...
  artifact_kind TEXT NOT NULL,    -- plan_file | pr_url | verdict | merge_sha | ...
  pattern TEXT,                   -- optional: a substring the ref must contain,
                                  -- so an empty string cannot satisfy a contract
  note TEXT,                      -- why this contract exists, for whoever finds it
  updated_at TEXT NOT NULL
);

-- Phase 7: the artifacts themselves, keyed on the JOB rather than the phase.
--
-- WHY THE JOB AND NOT THE PHASE. The artifacts a build produces do not all come
-- out of a stage: the PR is created by bin/run-build.sh itself, after the review
-- phase has already closed, and the merge sha is written by bin/merge-sweep.sh
-- on a different box on a different day. Keying on the job means every one of
-- them has a home, and `phase_id` records WHICH attempt produced it when there
-- was one — attribution without forcing an artifact to invent a phase.
--
-- PRIMARY KEY (job_id, artifact_kind): one PR url per job, one standing verdict
-- per job. A second review round overwrites the first verdict on purpose — the
-- verdict a merge acts on is the CURRENT one, and job_phases already keeps the
-- per-attempt history that says how it got there.
--
-- No column was added to job_phases for this: D1 has no ADD COLUMN IF NOT
-- EXISTS and schema.sql is applied on EVERY deploy, so it must stay re-runnable.
-- The API folds `artifact_kind` / `artifact_ref` onto the rows it returns, the
-- same way job_claims' columns arrive folded onto a job.
CREATE TABLE IF NOT EXISTS job_artifacts (
  job_id TEXT NOT NULL,           -- jobs.id
  artifact_kind TEXT NOT NULL,    -- plan_file | pr_url | verdict | merge_sha | evidence | lane_fence | ...
  artifact_ref TEXT NOT NULL,     -- the artifact: a path, a URL, "APPROVE", a sha
  phase_id INTEGER,               -- job_phases.id that produced it, when there is one
  detail TEXT,                    -- JSON: tier, provenance, record dir. NEVER a secret.
  actor TEXT,                     -- box name / lane
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (job_id, artifact_kind)
);
-- The reverse lookup bin/merge-sweep.sh needs: given a PR url, which job made it.
CREATE INDEX IF NOT EXISTS idx_artifacts_ref ON job_artifacts(artifact_kind, artifact_ref);

-- BH-1024: EVERY ROUND, not just the standing one.
--
-- The table above keys on (job_id, artifact_kind) so that a merge acts on the
-- CURRENT verdict, and that rule is unchanged — the standing verdict still
-- lives in job_artifacts and nothing here competes with it. What it cost was
-- the history: a re-review, a head-bound rebind, a repair round all overwrote
-- the previous answer in place, so "what did the first round say, and about
-- which sha" was unanswerable minutes after it changed.
--
-- A TABLE AND NOT A COLUMN, for the reason spelled out above: D1 has no
-- ADD COLUMN IF NOT EXISTS and this file re-applies on every deploy.
-- NOT job_phases either: a phase is an attempt INSIDE a build, and the writers
-- of these rows are bin/review-prs.sh (a different lane entirely) and the
-- conductor's rebinds, which are not phases of anything.
--
-- APPEND-ONLY, and IDEMPOTENT BY CONTENT: the API appends a row only when the
-- (verdict, reviewed_sha, tier, provenance) tuple differs from the latest row
-- for that job, so a lane that re-puts the same verdict every tick writes one
-- row, and a rebind onto a new sha writes one more.
CREATE TABLE IF NOT EXISTS verdict_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id TEXT NOT NULL,           -- jobs.id, the same key as job_artifacts
  verdict TEXT NOT NULL,          -- APPROVE | BLOCK — the artifact_ref at the time
  reviewed_sha TEXT,              -- detail.reviewed_sha at the time (NULL = no claim)
  tier TEXT,
  provenance TEXT,
  served_by TEXT,
  source TEXT,                    -- run-build | review-prs | review-rescue-backfill | ...
  detail TEXT,                    -- the full detail JSON as written. NEVER a secret.
  actor TEXT,                     -- box name / lane
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_verdict_history_job ON verdict_history(job_id, id);

-- BH-1024's flag row. 1 = the ledger verdict is read FIRST by bin/review-prs.sh
-- (which starts WRITING one), bin/review-autopilot.sh (its already-reviewed
-- skip) and the merge conductor (its autopilot-verdict consume). The files stay
-- write-through caches and fallbacks either way, so 0 is today's behaviour byte
-- for byte and flipping it back is the whole rollback.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('verdict_single_home','0','BH-1024: 1 = the ledger verdict row is read FIRST by review-prs (write), review-autopilot (skip) and the conductor (autopilot-verdict consume); the files stay a write-through cache','seed','2026-09-19T00:00:00Z');

-- Phase 7: EXPLICIT CAPS.
-- bin/agent-call.sh floors every resolved lane cap at its stage family's max
-- (150/50/25) on purpose: "MAX COST, NOT TARGET COST" — a tightly-derived cap
-- must never kill good work mid-stage. The one thing that could bind verbatim
-- was an env override, because that is an operator saying "this exact number,
-- on purpose". Phase 7 gives a DB row the same standing.
--
-- Its own table rather than a column on budget_catalog for two reasons, and the
-- second matters more than the re-runnability one: PUT /api/catalog is the
-- DEPLOY-TIME sync of catalog/context-budgets.json, and it rewrites every lane
-- it carries. A flag living on that row would be reset by the next deploy — a
-- config change nobody made. Nothing but PUT /api/catalog/explicit ever writes
-- here, so an explicit cap is a HAND-SET fact that survives every re-sync.
--
-- SHIPS EMPTY. No row = default semantics = today's floor.
CREATE TABLE IF NOT EXISTS budget_cap_flags (
  lane TEXT PRIMARY KEY,          -- the EXACT budget_catalog key, never a ladder match
  explicit INTEGER NOT NULL DEFAULT 0,  -- 1 = bind verbatim, do not floor
  actor TEXT,                     -- who set it; this is a the operator-edited row
  reason TEXT,                    -- why this lane is capped on purpose
  updated_at TEXT NOT NULL
);

-- Job transcripts (2026-08-29): the CONVERSATION behind a row.
--
-- Every jobs row is one headless agent session. Until now the console could say
-- what a stage cost, which runner served it and what rc it died on, and could
-- say nothing at all about what the model was actually doing — that lived only
-- in a session jsonl on one box's disk, behind ssh, on a machine that may have
-- been recycled since. This table is where a box PUSHES the readable render of
-- that session so clicking a job in Mission Control answers "what happened".
--
-- WHY NOT job_artifacts. artifact_ref is capped at 1024 chars and the table is
-- keyed (job_id, artifact_kind) — one row per kind per job. A transcript is
-- ~150KB and there is one PER ATTEMPT: the failover ladder can hand a single
-- stage to three vendors, and collapsing those into one row would overwrite the
-- session that explains why the first two died. So: its own table, keyed by
-- attempt, additive, and job_artifacts is left exactly as phase 7 shipped it.
--
-- phase_id is NOT NULL DEFAULT 0 rather than nullable on purpose: it is part of
-- the primary key, and SQLite does not treat NULLs as equal in an upsert
-- conflict target — a nullable column here would make every push from a lane
-- with no phase row INSERT a duplicate instead of updating. 0 means "no phase
-- row existed", which the console renders as an unattributed attempt.
--
-- `body` is ALREADY RENDERED and ALREADY SCRUBBED when it arrives. The console
-- never parses raw jsonl, and bin/transcript-scrub.sh redacts every value found
-- in /root/harness/env/* plus the usual token shapes BEFORE the push. The
-- NO SECRETS IN ANY ROW rule at the top of this file binds here hardest.
--
-- SHIPS EMPTY. No row = "no transcript pushed", which the console says in those
-- words rather than implying the job did nothing.
CREATE TABLE IF NOT EXISTS job_transcripts (
  job_id TEXT NOT NULL,               -- jobs.id
  phase_id INTEGER NOT NULL DEFAULT 0,-- job_phases.id, or 0 when the lane opened none
  attempt INTEGER NOT NULL DEFAULT 1, -- 1-based within the phase; the failover ladder bumps it
  stage TEXT,                         -- plan | execute | review | triage | ...
  runner TEXT,                        -- which lane actually served this attempt
  model TEXT,                         -- the model that answered it
  source TEXT,                        -- session_jsonl | stage_output — provenance, never guessed
  bytes INTEGER,                      -- length of body as stored
  truncated INTEGER NOT NULL DEFAULT 0,-- 1 = this is a TAIL, the head was dropped
  redactions INTEGER NOT NULL DEFAULT 0,-- how many values the scrubber replaced
  body TEXT NOT NULL,                 -- rendered turn-by-turn text. NEVER a secret.
  actor TEXT,                         -- box name that pushed it
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (job_id, phase_id, attempt)
);
-- The console's read is always "every transcript on this job, newest first".
CREATE INDEX IF NOT EXISTS idx_transcripts_job ON job_transcripts(job_id, created_at);


-- ═══════════════════════════════════════════════════════════════════════════
-- PRE-PLANS (BH-658, 2026-09-17)
--
-- THE HOP THIS EXISTS FOR. bin/run-preplan.sh pays Fable to plan a ticket
-- BEFORE its build starts and leaves the result in plans/<project>-<KEY>/ on
-- the box that planned it. bin/fly-pool.sh:push_preplan then relays that
-- directory to the Fly machine that will build the ticket — except it reads the
-- directory on the HUB, and the hub is forbidden to pre-plan
-- (bin/lib/hub-box.sh), so on the hub it is always empty. Result: every Fly
-- build re-planned from scratch and nothing said so (0 of 1052 build records on
-- box-project-4-1 carried a PREPLAN_ line while that box's own plans/ held
-- 58 plan dirs). The row is the missing box -> hub hop.
--
-- WHY NOT THE QUEUE ROW'S meta COLUMN: it is capped at 4000 chars and a plan is
-- 10-40KB. A TRUNCATED plan is the one failure mode worse than no plan at all —
-- the builder would execute half a design — so the write REFUSES an over-size
-- body (413) rather than storing a prefix of it.
--
-- KEYED (project, ticket_key), NOT (project, ticket_key, base_sha). A newer
-- pre-plan for the same ticket REPLACES the older one, because the only plan
-- anyone should ever adopt is the newest one: an older row would be a stale
-- plan sitting in the table waiting to be picked up. The sha the plan was made
-- against rides as a COLUMN, which is what the freshness check actually needs.
--
-- IT CARRIES THE SAME STALENESS DATA THE LOCAL PATH USES, or adopting from it
-- would be weaker than adopting from disk: base_sha (has main moved in a file
-- this plan lists?) and ticket_fp (has the board thread moved since?). Both are
-- judged on the BUILDER, by bin/lib/preplan-lib.sh, exactly as they are today.
--
-- NO SECRETS: plan_md is planner prose, planned_files is a list of repo paths,
-- ticket_fp is timestamps and a comment count. The NO SECRETS IN ANY ROW rule
-- at the top of this file binds here as it does everywhere.
--
-- BOUNDED: the POST handler deletes rows older than 14 days on its way out —
-- one statement, inside the write path, never a sweep. A pre-plan older than
-- that is older than any queued build it could serve.
--
-- IT LANDS WITH THE DEPLOY, not with a hand-run file. Re-applying THIS file to
-- the live database is a hand step (see the Deploy section of README.md), and a
-- new table that waits for one ships dead — the code is on every box within
-- minutes and every statement against the missing table throws a 500 that reads
-- as a worker outage. So src/index.js:ensureTable holds the same CREATE as a
-- literal and runs it before the first `preplans` statement in either route,
-- exactly as ensureColumns does for an added column. This definition is the
-- readable one and the one a fresh database is built from; the two must be kept
-- identical.
CREATE TABLE IF NOT EXISTS preplans (
  project TEXT NOT NULL,              -- fleet.conf project name
  ticket_key TEXT NOT NULL,           -- the harness KEY (TK-493, TK-265, ...)
  base_sha TEXT NOT NULL,             -- origin/<base> the planner actually read
  ticket_fp TEXT,                     -- board thread fingerprint when it was written
  planned_files TEXT,                 -- bin/planned-files.sh output, newline-joined
  plan_md TEXT NOT NULL,              -- the plan. NEVER a secret.
  bytes INTEGER,                      -- length of plan_md as stored
  box TEXT,                           -- the box that published it
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key)
);
-- Two readers: the hub's relay asks for one (project, ticket_key) — that is the
-- primary key — and the overlap guard walks a project newest-first.
CREATE INDEX IF NOT EXISTS idx_preplans_project ON preplans(project, updated_at);


-- ═══════════════════════════════════════════════════════════════════════════
-- METRICS LEDGER (2026-08-29, the operator: "move things to the database instead of
-- files"). Four measurement series that lived only as CSVs on the hub's disk.
--
-- WHY FOUR TABLES AND NOT ONE GENERIC `metrics(series, key, payload_json)`.
-- The four series have genuinely different keys (a UTC day, a PR url, a poll
-- instant, a per-PR outcome), genuinely different cardinalities (365/yr vs
-- ~24/day vs one row per merged PR), and every consumer of them aggregates
-- numerically — SUM(usd_equiv), MAX(peak_cache_read), the cache-hit ratio over
-- cache_read/(cache_read+input_toks). A JSON blob column would push all of that
-- into the reader, which is precisely the cost that made the CSVs unusable from
-- anywhere but the hub. Typed columns keep the aggregation in D1 where the
-- console can ask for it in one query. It also matches every table above.
--
-- THE CSV STAYS. Each producer writes its file first and pushes second,
-- fail-open (bin/jobs-client.sh's contract): a worker outage must never break a
-- metrics script, and nothing that reads the CSVs today changes.
--
-- IDEMPOTENT BY KEY, not by insert order. Every one of these producers re-runs
-- over ground it has already covered — orchestrator-burn re-pushes the same day
-- 24 times, cost-rollup rewrites every PR row daily, outcome-metrics re-reads
-- merged PRs weekly — so each table's PRIMARY KEY is the natural identity of
-- the measurement and every write is an upsert. A re-run must never duplicate.

-- One row per UTC DAY. Mirrors logs/orchestrator-burn.csv exactly.
-- The day is the KEY, which is the same fix bin/orchestrator-burn.sh needed on
-- the file side: the row's own date decides what it replaces, so a producer
-- whose clock disagrees with the reader's cannot append a second row for a day
-- that already has one (it did, for five days, in local time vs UTC).
CREATE TABLE IF NOT EXISTS burn_days (
  day TEXT PRIMARY KEY,           -- YYYY-MM-DD, UTC
  api_calls INTEGER,
  fresh_in INTEGER,
  output INTEGER,
  cache_read INTEGER,
  cache_write INTEGER,
  usd_equiv REAL,
  peak_cache_read INTEGER,        -- the runaway-session signal, not the volume one
  avg_cache_read INTEGER,
  actor TEXT,                     -- which box pushed it
  updated_at TEXT NOT NULL
);

-- ── Non-Anthropic vendor spend (2026-09-14, cost fix 5) ─────────────────────
-- One row per POLL of a vendor's own API, written by bin/vendor-spend-pull.sh
-- (hub cron, hourly) through bin/jobs-client.sh metric_vendor_spend.
--
-- WHY IT IS ITS OWN TABLE and not more columns on cost_rows: cost_rows is one
-- row per CALL we made, priced by us. This is one row per BILL, as the vendor
-- states it. Anthropic spend is instrumented to the call; xAI, OpenRouter,
-- codex and Fly were four dashboards nobody opened, and the grok/openrouter
-- rows in cost.csv are model-priced ESTIMATES that had never once been compared
-- against an invoice. Putting an estimate and a bill in one table is how a
-- reader ends up quoting whichever they reached first.
--
-- (vendor, ts) rather than ts alone: two vendors polled in the same second are
-- two facts, and the upsert on that pair makes a re-push after a failed request
-- a no-op rather than a duplicate — the same rule as every other series here.
--
-- EVERY MEASUREMENT COLUMN IS NULLABLE, AND NULL IS LOAD-BEARING. A vendor with
-- no readable spend endpoint writes usd = NULL and a note saying so. It must
-- never write 0: "we could not measure it" and "it cost nothing" are different
-- facts that look identical once one of them is spelled 0.00, and the first one
-- is the one that hides a bill.
--
--   kind    'metered'  = the vendor told us a dollar figure (OpenRouter only,
--                        as of 2026-09-14)
--           'computed' = we derived it — from our own cost rows, or from Fly
--                        machine-seconds x catalog/fly-prices.json
--   status  'ok' | 'no-spend-endpoint' (PROBED, not assumed — see the per-vendor
--           block in bin/vendor-spend-pull.sh) | 'auth-failed' | 'error'
--
-- cumulative_usd is what makes the series differenceable: OpenRouter reports a
-- lifetime total, so the WINDOW's spend is this reading minus the last one, and
-- keeping the raw cumulative is what lets a reader re-derive any window later
-- (and what makes a re-based or reset meter visible rather than a negative).
CREATE TABLE IF NOT EXISTS vendor_spend (
  vendor TEXT NOT NULL,           -- openrouter | xai | fireworks | codex | fly
  ts TEXT NOT NULL,               -- ISO instant of the poll
  window_start TEXT,              -- the usd below covers (window_start, window_end]
  window_end TEXT,
  usd REAL,                       -- spend in the window; NULL = not measured, NEVER 0
  kind TEXT,                      -- metered | computed
  status TEXT,                    -- ok | no-spend-endpoint | auth-failed | error
  balance_usd REAL,               -- prepaid balance where the vendor exposes one
  cumulative_usd REAL,            -- lifetime total as the vendor reports it
  note TEXT,                      -- why this number is what it is, in one line
  raw TEXT,                       -- the vendor payload, redacted, <= 8KB
  actor TEXT,                     -- which box polled
  updated_at TEXT NOT NULL,
  PRIMARY KEY (vendor, ts)
);
CREATE INDEX IF NOT EXISTS idx_vendor_spend_ts ON vendor_spend(ts);

-- One row per PR, mirroring state/cost/cost-per-pr.csv (bin/cost-rollup.sh).
-- cost-rollup REWRITES that whole file on every run, so the push is a full
-- upsert sweep and the PK makes re-pushing 219 unchanged rows a no-op.
--
-- auth_account / account_breakdown (2026-09-02) are the FIRST columns ever
-- added to an existing table here. D1 has no ADD COLUMN IF NOT EXISTS, so a
-- bare ALTER cannot live in this re-runnable file: the CREATE below carries
-- them for a fresh database, and for a database that already has the table the
-- worker itself adds whichever is missing — src/index.js ensurePrCostsColumns
-- reads PRAGMA table_info(pr_costs) and ALTERs the gap before the first
-- pr-costs write after a deploy. Additive, idempotent, and it lands with the
-- deploy exactly as a new table would. Keep this CREATE and that list in sync.
CREATE TABLE IF NOT EXISTS pr_costs (
  pr_url TEXT PRIMARY KEY,
  cost_usd REAL,
  input_toks INTEGER,
  output_toks INTEGER,
  cache_read INTEGER,
  cache_write INTEGER,
  stage_breakdown TEXT,           -- "execute:110.77;review:10.72;..." as rolled up
  build_dirs TEXT,                -- ";"-joined build dir names, the attribution trail
  updated_at TEXT NOT NULL,
  auth_account TEXT,              -- the label that paid the LARGEST share (never "mixed"; "unknown" when unlabeled)
  account_breakdown TEXT          -- "label:usd;label:usd", the full split behind auth_account
);

-- Every per-call cost row, mirrored from each box's logs/cost.csv by
-- bin/cost-rows-push.sh (cron */10) through bin/jobs-client.sh metric_cost_rows.
-- The CSV stays the write-ahead source of truth; this is the copy that answers
-- fleet-wide questions ("what did account X spend this week") without ssh.
-- The first twenty-three data columns ARE bin/lib/cost-row.sh's COST_ROW_HDR,
-- in order; a 13/14/16-column row from before billing_mode / auth_* / the
-- session+tag columns lands with those trailing fields NULL.
-- row_hash is sha256 of the raw CSV line, so (box, row_hash) makes
-- a re-push — after a crash, a cursor reset, a rotated file — a no-op, the same
-- way `sort -u` dedupes fleet-cost.csv. line_no is the row's position in the
-- file at push time, the trail back to the source line.
CREATE TABLE IF NOT EXISTS cost_rows (
  box TEXT NOT NULL,              -- cron/<box>.cron's id, the same id the extra-usage tracker uses
  row_hash TEXT NOT NULL,
  line_no INTEGER NOT NULL,
  ts TEXT,
  host TEXT,
  project TEXT,
  stage TEXT,
  runner TEXT,
  model TEXT,
  rc INTEGER,
  duration_s REAL,
  input_toks INTEGER,
  output_toks INTEGER,
  cache_read INTEGER,
  cache_write INTEGER,
  cost_usd REAL,
  billing_mode TEXT,
  auth_fp TEXT,
  auth_account TEXT,
  -- Row provenance + attribution (2026-09-14, cost fixes 1/2/7). Appended to
  -- the CSV at the END and added here the additive way: this CREATE carries
  -- them for a fresh database, ensureColumns() in src/index.js ALTERs an
  -- existing one. A row pushed by a box that has not synced yet lands with all
  -- seven NULL, which reads as "written before the box could say", not as zero.
  session_id TEXT,                -- the claude --session-id this row was priced from
  row_source TEXT,                -- transcript | result | none
  result_usd REAL,                -- the CLI envelope's own .total_cost_usd, kept beside cost_usd
  ticket TEXT,                    -- COST_KEY / HARNESS_TICKET
  job_id TEXT,                    -- COST_JOB / JOB_ID, the jobs-ledger row
  pr TEXT,                        -- COST_PR
  run_id TEXT,                    -- COST_RUN_ID, else the build dir the stage wrote into
  -- 2026-09-20, BH-1032. `note` is the 24th CSV column (today it carries the
  -- cliff-route decision); the client's column list stopped at run_id, so every
  -- note written since BH-656 was dropped on the way into this table. `raw` is
  -- the VERBATIM csv line, kept beside the parsed columns the same way an
  -- integration keeps a rawJson snapshot: a reader that re-emits the line gets
  -- back exactly what the box wrote, where reconstructing from REAL columns
  -- turns a `4.00` into a `4` and makes every file built from this table differ
  -- from the file it mirrors (bin/lib/cost-rows-read.sh).
  note TEXT,
  raw TEXT,
  inserted_at TEXT NOT NULL,
  -- BH-2303: the 25th CSV column, the LANE the call was spent by
  -- ($AGENT_CALL_LANE, else the lane the pre-call gate resolved). Appended the
  -- additive way (ensureColumns ALTERs a live table); NULL on every row pushed
  -- before a box could say, which the llm-spend lane query reads by signature.
  lane_id TEXT,
  -- BH-2537: the 26th CSV column, the pre-call guard's input fingerprint
  -- ($COST_GUARD_FP). Added the same additive way as lane_id, and NOT indexed
  -- for the same reason (see the note below the indexes).
  guard_fp TEXT,
  -- BH-5349: the participant machine that spent the call (participant_machines.name).
  -- Added the same additive way as lane_id, not indexed; nothing writes it yet.
  participant TEXT,
  PRIMARY KEY (box, row_hash)
);
CREATE INDEX IF NOT EXISTS idx_cost_rows_project_ts ON cost_rows(project, ts);
CREATE INDEX IF NOT EXISTS idx_cost_rows_account ON cost_rows(auth_account);
-- "what did this ticket cost" and "what did this PR cost" without a time window
-- to guess with, which is the whole point of tagging the row at write time.
CREATE INDEX IF NOT EXISTS idx_cost_rows_ticket ON cost_rows(ticket);
CREATE INDEX IF NOT EXISTS idx_cost_rows_pr ON cost_rows(pr);
-- NO index on lane_id here (BH-2303 review): harness-sync applies this file to
-- the LIVE D1 before it deploys the worker, and on the live table lane_id only
-- exists once the new worker's ensureColumns has added it — an index on it here
-- would fail "no such column" and wedge every later worker deploy.

-- The per-token price table every cost figure in the fleet is multiplied by
-- (2026-09-20, BH-1032). bin/update-model-prices.sh rebuilds it daily from
-- OpenRouter and pushes it here; bin/model-prices-sync.sh pulls it down into
-- $HARNESS/state/model-prices.json on ANY box, which is what
-- bin/lib/cost-row.sh's reader chain already prefers.
--
-- WHY IT IS A TABLE. The live table was hub-only runtime state, so a Fly pool
-- machine — the fleet's largest execute lane — priced its rows from
-- catalog/model-prices.json, the committed fallback, which moves only when a
-- human lands a PR. Two prices for one call, and the cheaper one is whichever
-- machine happened to run it. The file does not stop being read: it becomes the
-- DERIVED CACHE of this table, written whole, so a worker outage prices from
-- yesterday's rates instead of from nothing.
--
-- One row per MODEL KEY, which is the string cost.csv's `model` column carries
-- — including the several keys that map to one slug, because pricing a row is a
-- lookup on what the runner reported, not on what we wish it had reported.
-- Rates are per TOKEN (the catalog's unit), nullable because a vendor that
-- publishes no cache-write rate is that component at 0, not an unpriced model.
CREATE TABLE IF NOT EXISTS model_prices (
  model TEXT PRIMARY KEY,         -- the cost.csv `model` value this rate prices
  slug TEXT,                      -- the vendor/OpenRouter slug it resolved from
  prompt REAL,
  completion REAL,
  cache_read REAL,
  cache_write REAL,
  cliff_tokens INTEGER,           -- per-request price cliff (BH-656); NULL = none
  source TEXT,                    -- who wrote it: openrouter | catalog | manual
  updated_at TEXT NOT NULL,
  price_source TEXT,              -- vendor-direct | NULL (= openrouter), BH-1613
  vendor_prompt REAL,             -- the vendor-direct rate (BH-1754); NULL = use the catalog row
  vendor_completion REAL,
  vendor_cache_read REAL,
  vendor_cache_write REAL,
  vendor_cliff_tokens INTEGER,
  -- BH-5652: the price version. A write that changes a rate (prompt,
  -- completion, cache_read, cache_write, cliff_tokens) bumps it and writes one
  -- price_audit row in the same batch; an unchanged re-post bumps nothing.
  -- A live table gets both through ensureColumns (core.js ADDED_COLUMNS).
  version INTEGER NOT NULL DEFAULT 1,
  effective_at TEXT               -- when this version's rates took effect; NULL = before BH-5652
);

-- Fly's list prices as rows (BH-5652). One row per number in
-- catalog/fly-prices.json, keyed by its dotted path (`seconds_per_month`,
-- `cpu_usd_per_core_month.shared`, ...). bin/price-seed.sh mirrors the file
-- here; the file stays the readers' source and the documented fallback this
-- wave. A changed value bumps `version` and writes a price_audit row (kind fly).
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS price_fly (
  key TEXT PRIMARY KEY,
  value REAL NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  effective_at TEXT NOT NULL,
  source TEXT,
  updated_at TEXT NOT NULL
);

-- The model-key -> OpenRouter slug map as rows (BH-5652), mirrored from
-- catalog/model-slugs.json by bin/price-seed.sh. Same version rule as above
-- (price_audit kind slug).
CREATE TABLE IF NOT EXISTS model_slugs (
  model TEXT PRIMARY KEY,
  slug TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  effective_at TEXT NOT NULL,
  source TEXT,
  updated_at TEXT NOT NULL
);

-- One row per price VERSION (BH-5652): why a cost changed. kind is model, fly
-- or slug; key is the model key, the dotted Fly key or the slug's model.
-- old_json is NULL for version 1. UNIQUE(kind, key, version) plus INSERT OR
-- IGNORE makes a replayed batch write nothing. Never pruned: one row per real
-- price change, tens a year.
CREATE TABLE IF NOT EXISTS price_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  key TEXT NOT NULL,
  version INTEGER NOT NULL,
  old_json TEXT,
  new_json TEXT NOT NULL,
  source TEXT,
  effective_at TEXT NOT NULL,
  UNIQUE(kind, key, version)
);

-- One row per POLL of the Anthropic usage endpoint, per ACCOUNT.
-- `box` is misnamed and kept: since 2026-09-14 it carries the ACCOUNT LABEL from
-- catalog/cost-accounts.json, not a machine. A box may hold two logins — the hub
-- polls hub-gmail AND project-6-account — because the unit of a meter is an
-- account, not a box. Rows written before that date carry a box id, which was
-- the same thing back when every box held exactly one login.
-- (account, ts) rather than ts alone: two accounts polled in the same second are
-- two facts, not a collision.
CREATE TABLE IF NOT EXISTS extra_usage_snapshots (
  box TEXT NOT NULL,
  ts TEXT NOT NULL,               -- ISO instant of the poll
  session_pct REAL,               -- 5h window utilization
  weekly_pct REAL,
  weekly_resets_at TEXT,
  extra_enabled INTEGER,
  extra_used_usd REAL,            -- the cash meter; the number a bill is made of
  spend_limit_reached INTEGER,
  in_overage INTEGER,
  -- Added 2026-09-14, the same two halves as pr_costs' pair: this CREATE carries
  -- them for a fresh database and src/index.js ensureColumns ALTERs an existing
  -- one before the first extra-usage write after a deploy. Keep the two in sync.
  extra_limit_usd REAL,           -- the account's extra-usage cap, so 98%-of-cap
                                  -- is answerable from the row instead of guessed
  extra_pct REAL,                 -- utilization of that cap, as the endpoint reports it
  status TEXT,                    -- ok | no-login | error. A poll that FAILED still
                                  -- writes a row: a login that cannot read its meter
                                  -- (setup-tokens get 429 forever) and a box whose
                                  -- cron is dead were the same absence here, and only
                                  -- one of them is fixed by provisioning a login.
                                  -- NULL = written before this column existed.
  error_body TEXT,                -- BH-3985: the vendor's answer on a failed poll,
                                  -- scrubbed of credentials by the poller. NULL on
                                  -- an ok poll. Same CREATE/ensureColumns pair.
  PRIMARY KEY (box, ts)
);
CREATE INDEX IF NOT EXISTS idx_extra_usage_ts ON extra_usage_snapshots(ts);

-- ── Cost reconciliation (2026-09-14, cost fix 4) ─────────────────────────────
-- One row per (account, window): what the ACCOUNT METER moved by, what our own
-- rows say we spent, and the gap between them. Two independent measurements of
-- the same money — the vendor's invoice meter and our per-call ledger — and the
-- only thing that makes either trustworthy is that they agree.
--
-- state is the honest half, and it is why this is not a single number:
--   metered         — past the weekly credits, so the meter moves in CASH and the
--                     comparison means something
--   credits-covered — weekly utilization was below 100% at window start: spend is
--                     subscription credits, the meter reads $0 and is RIGHT to.
--                     No $ comparison is possible, and inventing one would report
--                     a 100% gap every quiet week
--   no-login        — the account holds no credential that can read its meter
--   no-meter        — no snapshot in the window at all (the poller is down)
--   meter-reset     — the meter zeroed inside the window (weekly/monthly boundary),
--                     so last-minus-first is not a delta
--
-- rows_usd is summed from cost_rows for this account's auth_account labels and
-- Anthropic runners only; jobs_usd is the fallback for a machine with NO rows in
-- the window (a machine that has rows is never counted twice — the rows win, via
-- catalog/cost-accounts.json's box_aliases, since jobs say box-hub where
-- cost rows say hub);
-- unattributed_usd is Anthropic spend on this account's boxes that carries no
-- account label — counted nowhere, reported here, never silently folded in.
CREATE TABLE IF NOT EXISTS cost_reconciliation (
  account TEXT NOT NULL,          -- the meter label (catalog/cost-accounts.json)
  window_key TEXT NOT NULL,       -- 1h | 24h | day:YYYY-MM-DD
  window_start TEXT NOT NULL,
  window_end TEXT NOT NULL,
  state TEXT NOT NULL,
  meter_start_usd REAL,
  meter_end_usd REAL,
  meter_delta_usd REAL,
  rows_usd REAL,
  jobs_usd REAL,
  unattributed_usd REAL,
  rows_count INTEGER,
  jobs_count INTEGER,
  gap_usd REAL,                   -- meter_delta - (rows + jobs); + = the meter saw
                                  -- money our ledger never recorded
  gap_pct REAL,
  weekly_pct_start REAL,
  weekly_pct_end REAL,
  span_start TEXT,                -- the first/last meter SAMPLE in the window. The
  span_end TEXT,                  -- rows are summed over this, not over the window:
                                  -- comparing 40 minutes of meter against 24 hours
                                  -- of rows is how the first run reported -1146%.
  alerted INTEGER,
  note TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (account, window_key, window_end)
);
CREATE INDEX IF NOT EXISTS idx_reconcile_end ON cost_reconciliation(window_end);

-- One row per (repo, pr, outcome), mirroring logs/outcome-metrics.csv.
-- The PK is the same triple bin/outcome-metrics.sh already dedupes on in its
-- SEEN file, so the two ledgers cannot disagree about what is new. A PR can
-- carry more than one outcome (reverted AND merged_then_red), which is why the
-- outcome is part of the key rather than a column that would overwrite.
--
-- repairs (2026-09-06, SDLC item 3) is the SECOND column ever added to an
-- existing table here, on the same two halves as pr_costs' pair: the CREATE
-- below carries it for a fresh database, and src/index.js ensureColumns ALTERs
-- an existing one from PRAGMA table_info before the first outcomes write after
-- a deploy — D1 has no ADD COLUMN IF NOT EXISTS, so a bare ALTER cannot live in
-- this re-runnable file. Keep this CREATE and that map in sync.
CREATE TABLE IF NOT EXISTS outcome_metrics (
  repo TEXT NOT NULL,
  pr TEXT NOT NULL,
  outcome TEXT NOT NULL,          -- reverted | reopened | merged_then_red
  day TEXT,                       -- YYYY-MM-DD the finding was recorded
  evidence TEXT,                  -- the objectively checkable trail, never a secret
  repairs INTEGER,                -- repair rounds the BUILD recorded for this PR;
                                  -- NULL = never measured, which is not the same
                                  -- fact as 0 (measured, never sent back)
  created_at TEXT NOT NULL,
  PRIMARY KEY (repo, pr, outcome)
);
CREATE INDEX IF NOT EXISTS idx_outcome_day ON outcome_metrics(day);

-- ── Flaky CI (2026-09-12): tell "red because broken" from "red because flaky" ─
-- One row per (repo, workflow, test, head): a RED classified by what the run
-- history says about the head sha it ran on.
--
--   kind='flake'  the same workflow concluded BOTH failure and success on this
--                 head. Same tree, same lockfile, same workflow file, two
--                 answers — the code did not change, so the difference is the
--                 test, the runner or the network.
--   kind='red'    the workflow went red on this head and never went green on
--                 it. A real red.
--
-- THE TABLE HOLDS BOTH, and the name is a little wrong on purpose. A flakes-only
-- table can say a number went up; flaky reds OVER ALL reds is the measure anyone
-- acts on, and a denominator living in another table is a denominator that stops
-- matching its numerator the first time one of the two writers changes.
--
-- THE KEY IS THE HEAD, not the run id. A head that was re-run nine times is one
-- piece of evidence about one test; keying on runs would let a single bad
-- afternoon quarantine a healthy test, and would make re-running the detector
-- over the same window inflate every count it reports. Every count downstream
-- (bin/lib/flaky.sh's known set, the 7d rate, the quarantine threshold) is
-- therefore over DISTINCT heads. `test` is the failing test name where the log
-- carried one, else "job:<failed job name>", else "workflow:<path>" — the
-- fallbacks still count as reds but can never become quarantine entries,
-- because no test runner will ever match a name shaped like that.
CREATE TABLE IF NOT EXISTS ci_flakes (
  repo TEXT NOT NULL,             -- github slug, the same key outcome_metrics uses
  workflow TEXT NOT NULL,         -- .github/workflows/<file>.yml
  test TEXT NOT NULL,             -- failing test name | job:<name> | workflow:<path>
  head TEXT NOT NULL,             -- the head sha the red ran on
  kind TEXT NOT NULL,             -- flake | red
  day TEXT,                       -- YYYY-MM-DD of the newest run in the group
  created_at TEXT NOT NULL,
  PRIMARY KEY (repo, workflow, test, head)
);
CREATE INDEX IF NOT EXISTS idx_ci_flakes_day ON ci_flakes(day);
CREATE INDEX IF NOT EXISTS idx_ci_flakes_repo_kind ON ci_flakes(repo, kind);

-- ── CI health: quarantine state and the per-repo health snapshots (BH-2517) ──
-- flaky_quarantine is the CURRENT quarantine switch, one row per (repo, test).
-- active=1 means a red on that test is forgiven, active=0 means it was lifted.
-- The row is rewritten in place, so it is never the history.
-- flaky_quarantine_changes is that history, append-only: one row per flip with
-- the state before (NULL for the first write), the state after, who and why.
-- ci_health holds the newest snapshot per (repo, metric), payload a JSON object
-- and box the host that sent it. The box side is ci_health_put in
-- bin/lib/jobs/cost.sh. The worker routes that read and write all three tables
-- are sibling slices of BH-2517, so until they land nothing writes here.
-- Applied by bin/harness-sync.sh statement by statement before the deploy.
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS flaky_quarantine (repo TEXT NOT NULL, test TEXT NOT NULL, active INTEGER NOT NULL, actor TEXT NOT NULL, reason TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (repo, test));
CREATE TABLE IF NOT EXISTS flaky_quarantine_changes (id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, test TEXT NOT NULL, before_active INTEGER, after_active INTEGER NOT NULL, actor TEXT NOT NULL, reason TEXT NOT NULL, at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_flaky_quarantine_changes_rt ON flaky_quarantine_changes(repo, test, at);
CREATE TABLE IF NOT EXISTS ci_health (repo TEXT NOT NULL, metric TEXT NOT NULL, payload TEXT NOT NULL, box TEXT, as_of TEXT NOT NULL, PRIMARY KEY (repo, metric));

-- ci_batches is the per-merge-queue-batch CI cost ledger (BH-4971, BH-4964.3):
-- one row per Harness CI run_id on a mergify/merge-queue/ branch, the ci-plan
-- notice's mode/selected/total/escalation beside what the run cost (wall_s,
-- billed_min = sum of ceil(job seconds / 60) over MonkCI jobs). The writer is
-- bin/ci-batch-ledger.sh through PUT /api/ci-batches, an upsert on the natural
-- key run_id, so a re-read run is one row, never two. run_attempt is the attempt
-- the row was read at: a re-run of a recorded batch is read again and its row
-- overwritten, and billed_min sums the jobs of EVERY attempt (filter=all).
-- Applied by bin/harness-sync.sh statement by statement before the deploy.
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS ci_batches (run_id INTEGER PRIMARY KEY, repo TEXT NOT NULL, head_ref TEXT, head_sha TEXT, mode TEXT, selected INTEGER, total INTEGER, escalation TEXT, conclusion TEXT, run_attempt INTEGER, started_at TEXT, completed_at TEXT, wall_s INTEGER, billed_min INTEGER, as_of TEXT);
CREATE INDEX IF NOT EXISTS idx_ci_batches_repo_completed ON ci_batches(repo, completed_at);

-- ── SDLC item 2: STEER BY OUTCOMES, NOT ACTIVITY (2026-08-29) ────────────────
-- The metrics tables above MEASURE. These two let a measurement CHANGE what the
-- fleet is allowed to do, in exactly one direction: tighter.
--
-- review_gate is the DETECTOR'S OWN RECORD, one row per repo, rewritten every
-- run of bin/review-tighten.sh — the trailing-window revert/reopen rate it
-- computed, the thresholds it judged that rate against, and the verdict. It is
-- NOT the switch. The switch is a pause_flags row named review-tighten-<repo>
-- (bin/jobs-client.sh review_tighten_flag_name), because that rail already has
-- the file write-through every box relies on and bin/merge-sweep.sh already
-- reads flags through flag_active. One switch, one reader, no second copy of
-- "is this repo tightened" to drift.
--
-- A row is written on EVERY measurement, including the ones that change
-- nothing. A gate that only records the days it fired cannot answer "was this
-- repo measured at all last week", which is the first question asked of any
-- detector that did not fire.
CREATE TABLE IF NOT EXISTS review_gate (
  repo TEXT PRIMARY KEY,          -- github slug, the same key outcome_metrics uses
  tightened INTEGER NOT NULL,     -- 1 = harness PRs park instead of auto-merging
  rate REAL,                      -- bad / merges over the window; NULL = not measurable
  bad INTEGER,                    -- DISTINCT PRs with any bad outcome, never outcome rows
  merges INTEGER,                 -- the denominator: PRs merged inside the window
  window_days INTEGER,
  tighten_rate REAL,              -- the thresholds this measurement was judged against,
  clear_rate REAL,                -- stored WITH the row so a later threshold edit cannot
  min_merges INTEGER,             -- silently rewrite the history of why a repo parked
  threshold_scope TEXT,           -- repo | * | fallback — where those numbers came from
  decision TEXT,                  -- tighten | clear | hold | insufficient
  evidence TEXT,                  -- the checkable trail, never a secret
  actor TEXT,
  tightened_at TEXT,              -- when it last crossed; cleared back to NULL on clear
  updated_at TEXT NOT NULL
);

-- The thresholds themselves, DB-driven per the fleet's standing rule that a
-- business parameter is a settings edit and not a deploy. scope '*' is the
-- fleet default; a repo slug overrides it for that repo alone.
-- bin/review-tighten.sh carries a DOCUMENTED code fallback for an empty table.
CREATE TABLE IF NOT EXISTS review_gate_thresholds (
  scope TEXT PRIMARY KEY,         -- '*' or a github slug
  window_days INTEGER NOT NULL,
  min_merges INTEGER NOT NULL,    -- below this many merges a rate means nothing
  tighten_rate REAL NOT NULL,     -- >= this parks the repo
  clear_rate REAL NOT NULL,       -- <= this releases it; between the two, hold
  note TEXT,
  updated_at TEXT NOT NULL
);

-- ── LANE LIVENESS (2026-08-30): what is SUPPOSED to be ticking ───────────────
-- On 2026-08-30 project `project-7` on box box-project-6-1 lost every
-- one of its crons at 05:17 (a daily crontab re-apply from a stale repo file)
-- and the lane was silent for TEN HOURS. Nothing alerted, and nothing could
-- have: every table above records work that HAPPENED. A job row exists because
-- a claimant made it; jobs_watchdog ages rows that exist. The one thing no row
-- in this database could express was an ABSENCE — "project-7 should have ticked
-- six times an hour and did not tick at all" — because nothing here knew the
-- lane was expected.
--
-- A lane is one (project, box) pair: the unit fleet.conf actually declares and
-- the unit a crontab actually loses. Not the project alone (a project can move
-- between boxes, and two projects share box-project-6-1 and
-- box-small), and not the box alone (box-project-6-1 lost ONE
-- of its two lanes while the other kept ticking — a box-level ping said the box
-- was perfectly alive, which it was).
--
-- TWO WRITERS, DISJOINT COLUMNS, and that separation is the design:
--   the HUB declares expectation  — cadence_min, offset_min, expected_since,
--     retired_at — from fleet.conf, on the same */10 push that already carries
--     fleet status (bin/fleet-status-push.sh).
--   the BOX records ticks         — last_tick_at, last_tick_kind — one write at
--     the top of every bin/run-triage.sh run (bin/jobs-client.sh lane_tick).
-- A box therefore cannot enrol itself and a hub push cannot fake a heartbeat.
-- A row with ticks but no expected_since is an UNEXPECTED lane: worth seeing,
-- never alertable, because it was judged against an expectation nobody made.
--
-- RETIRED, NEVER DELETED. A lane dropped from fleet.conf keeps its row with
-- retired_at stamped, so "this lane used to exist and stopped being watched" is
-- answerable — and an empty expected set (a mid-rsync fleet.conf) retires
-- NOTHING, the same judgement bin/fleet-status-push.sh already makes about
-- pushing an empty fleet.
--
-- alerted_at IS THE DEDUPE, and it lives here rather than in a file on the hub
-- for the half a file cannot do: RECOVERY. The latch says an alert has been
-- sent, so a dead lane pages once instead of every five minutes, and clearing
-- it is what emits "the lane came back". A hub-local seen-file would forget the
-- first half on every rebuild and could never express the second.
--
-- NOT a second heartbeat path. bin/jobs-client.sh job_heartbeat beats a CLAIM
-- (a job row that exists, every ~150s while it works); this beats a LANE (a
-- cron that fired, once per tick, whether or not it claimed anything). A gate
-- `SKIP` — the normal shape of a quiet board — spends nothing, claims nothing
-- and is still the lane being alive, which is precisely the fact the job
-- ledger cannot carry.
CREATE TABLE IF NOT EXISTS lanes (
  project TEXT NOT NULL,          -- fleet.conf col 1
  box TEXT NOT NULL,              -- fleet.conf col 6, resolved (bin/box-for.sh)
  cadence_min INTEGER,            -- minutes between expected ticks (10 for triage)
  offset_min INTEGER,             -- fleet.conf col 5, recorded not enforced
  expected_since TEXT,            -- when the hub first declared it; NULL = undeclared
  retired_at TEXT,                -- dropped from fleet.conf; the row stays
  last_tick_at TEXT,              -- the box's last cron tick, server clock
  last_tick_kind TEXT,            -- start | skip | paused | locked | run | failed
  alerted_at TEXT,                -- the stale latch; NULL = nothing outstanding
  actor TEXT,                     -- who declared it, for the human who finds it
  updated_at TEXT NOT NULL,
  -- ── THE PROCESS HALF (BH-1031, state→DB slice 6) ──────────────────────────
  -- Everything above is about a CRON: did the clock fire on this box. These
  -- columns carry the other liveness question the fleet kept answering in three
  -- places at once — is the long-lived PROCESS that lane runs still breathing —
  -- and they are here rather than in a table of their own because a second
  -- table is a second answer, which is the bug this slice closes.
  --
  -- Three answers existed before this. state/heartbeat/<lane>.<pid>.json on the
  -- box (bin/lib/heartbeat.sh) can only be read by the box that wrote it, so it
  -- goes blind at exactly the moment that matters: the box itself is gone.
  -- bin/fleet-heartbeat.sh ssh'd every box every 15 minutes to stat a log file,
  -- which answered "can the hub reach it" and not "is the lane alive" (its own
  -- comments said so). The `lanes` row answered a third thing again. One row,
  -- two clocks, disjoint writers.
  --
  -- A PROCESS ROW IS KEYED `project`='hb.<lane>'. A box runs several long-lived
  -- lanes at once (merge-conductor and blocked-resolver overlap as their normal
  -- state), so one row per (lane, box) is required, and the `hb.` prefix is
  -- what keeps a process row out of the hub's fleet.conf namespace: the PUT
  -- above only ever declares or retires rows it names, and a process row is
  -- never one of them, so it can never be judged against a cron expectation
  -- nobody made.
  --
  -- THE PID IS EVIDENCE, NOT THE TEST. The worker cannot `kill -0` a pid on
  -- another machine; it judges SILENCE (beats stopped) and the expected-by.
  -- The box-local reaper still owns the pid probe, and carries the pid here so
  -- the page names the process a human has to go look for.
  proc_pid INTEGER,               -- the writer's $$ on its own box; evidence only
  proc_note TEXT,                 -- the lane's own last words ("waiting on CI")
  proc_started_at TEXT,           -- the launch this beat belongs to
  proc_interval_s INTEGER,        -- the declared rhythm; the stale threshold derives from it
  proc_deadline_at TEXT,          -- expected-by; NULL/absent = a loop that runs for ever on purpose
  proc_beat_at TEXT,              -- the last beat, server clock — the fact `stale` is computed from
  proc_ended_at TEXT,             -- a clean hb_done; >= proc_beat_at means it finished, not died
  PRIMARY KEY (project, box)
);
CREATE INDEX IF NOT EXISTS idx_lanes_tick ON lanes(last_tick_at);
CREATE INDEX IF NOT EXISTS idx_lanes_proc_beat ON lanes(proc_beat_at);

-- Runner-CLI versions (2026-09-06). One row per (box, cli) per daily update on
-- the box (bin/cli-update.sh, source='update') and per hub sweep
-- (bin/cli-version-check.sh, source='check'), pushed through
-- bin/jobs-client.sh metric_cli_version(s). The box's logs/cli-versions.csv
-- stays the write-ahead copy; this is what answers "which box is behind the
-- hub / below the floor for model X" without nine ssh sessions. `at` is the
-- run's own timestamp, carried in the row, so a resend after a failed push is
-- a no-op on the PK.
CREATE TABLE IF NOT EXISTS cli_versions (
  box TEXT NOT NULL,              -- cron/<box>.cron's id (hub, project-9, ...)
  cli TEXT NOT NULL,              -- claude | codex
  at TEXT NOT NULL,               -- ISO instant of the update run / sweep
  source TEXT NOT NULL,           -- update | check
  version_before TEXT,            -- "missing" when PATH could not resolve it
  version_after TEXT,
  method TEXT,                    -- native | npm | native+npm | none | check
  ok INTEGER,                     -- 0 when the CLI ended worse or missing
  path TEXT,                      -- what `command -v <cli>` resolved to afterwards
  note TEXT,                      -- relinks, forced retries, stale files (';'-joined)
  inserted_at TEXT NOT NULL,
  PRIMARY KEY (box, cli, at, source)
);
CREATE INDEX IF NOT EXISTS idx_cli_versions_box_at ON cli_versions(box, at);

-- The CURRENT state per box, upserted from every cli_versions push — the
-- table the ops-fixes plan (PR #195, fix 5) designed as box_status, created
-- here with its column names so that work lands on it rather than beside it.
-- cli_version / codex_version are the latest version_after seen for each CLI;
-- node_version, harness_commit and rules_commit are fix 5's to fill.
--
-- BH-1031 added the backup_* half. "When did this box last get a VERIFIED
-- off-box copy" is a fact only the box can answer, and until this slice the hub
-- collected it by ssh'ing every box every 15 minutes inside
-- bin/fleet-heartbeat.sh -- the lane this slice deletes. So the box reports its
-- own three raw facts here (bin/state-backup.sh, on the tick that produced
-- them) and the hub reads them back with everything else it already reads from
-- this table. THREE FACTS, NEVER A VERDICT, exactly as the ssh probe carried
-- them: bin/lib/backup-freshness.sh on the hub decides what they MEAN, so a box
-- running an older bin/ cannot answer in a vocabulary the hub has moved on from.
-- backup_reported_at is the COLLECTION time and is load-bearing: it is what
-- lets a box that stopped reporting age out instead of being re-read for ever
-- as if it had just answered.
CREATE TABLE IF NOT EXISTS box_status (
  box TEXT PRIMARY KEY,
  host TEXT,
  cli_version TEXT,               -- claude
  cli_checked_at TEXT,
  codex_version TEXT,
  node_version TEXT,
  harness_commit TEXT,
  rules_commit TEXT,
  backup_ts TEXT,                 -- state/backup-last.json .ts, verbatim ('' = never stamped)
  backup_off TEXT,                -- 'off' when the lane is deliberately switched off
  backup_unconfigured TEXT,       -- 'unconfigured' while the BACKUP_* keys are a handoff
  backup_reported_at TEXT,        -- when the BOX last said so -- the collection clock
  harness_reported_at TEXT,       -- BH-1511.1: when the box last reported harness_commit (lane-gate liveness)
  rules_hash TEXT,                -- BH-2532: hash of the rules the box renders (self-reported)
  rules_reported_at TEXT,         -- BH-2532: when the box last reported rules_hash
  actor TEXT,
  updated_at TEXT NOT NULL
);

-- ── THE QUEUE BEFORE THE CLAIM (2026-09-10) ─────────────────────────────────
-- Every table above models a job from the moment a box CLAIMS it. The minutes
-- or hours BEFORE that — "this ticket is buildable, somebody run it" — were a
-- DIRECTORY on a box: state/build-queue/<project>/<KEY>.json, written by
-- bin/run-build.sh's QUEUED_FLY branch and pulled to the hub by
-- bin/fly-dispatch.sh over tailnet ssh.
--
-- Three costs came out of that, and this table exists to remove all three:
--   * THE HUB NEEDS SSH INTO EVERY BOX for the pool to see any work at all. A
--     queue that lives on the box can only be read by reaching into the box.
--   * A QUEUED BUILD IS INVISIBLE. Mission Control, the console and every
--     fleet-wide question can see a job the moment it is claimed and nothing
--     before it, so "why has TK-109 not started" is answerable only by ssh.
--   * TWO QUEUE NOTIONS. The file queue and the jobs table each call something
--     "waiting", and nothing reconciles them.
--
-- KEYED ON (project, ticket_key), which is EXACTLY the file queue's identity:
-- one file per KEY per project, so the row and the file cannot disagree about
-- what is queued. ticket_key is the board KEY (TK-109), not the board's
-- internal id — the key is what the filename carried, what `run-build.sh` is
-- invoked with, and what a human reads in a log line. ticket_id rides along
-- because the launch needs it, but it is not identity.
--
-- FOUR STATUSES, and `claimed` is the one that matters: it is written by a
-- COMPARE-AND-SWAP inside POST /api/queue/claim, so two dispatchers ticking in
-- the same second cannot both take one row. The file queue's equivalent was
-- `mv` — atomic on one box, and meaningless across two.
--
-- THE FILE STAYS THE FALLBACK, exactly as pause_flags and the merge ledger do:
-- producers write both during the transition and readers ask the DB first, so
-- an unreachable worker leaves every box queueing and draining precisely as it
-- does today. A queue that can refuse work when a database blinks is worse than
-- no queue in a database at all.
--
-- SHIPS EMPTY. No row is today's behaviour.
CREATE TABLE IF NOT EXISTS build_queue (
  project TEXT NOT NULL,          -- fleet.conf project name
  ticket_key TEXT NOT NULL,       -- the board KEY (TK-109) — the file queue's filename
  ticket_id TEXT,                 -- the board's internal id, carried for the launch
  status TEXT NOT NULL,           -- queued | claimed | done | failed
  target TEXT NOT NULL DEFAULT 'local',  -- local | fly — who is expected to run it
  attempt INTEGER NOT NULL DEFAULT 0,    -- the requeue counter the fly path already carries
  requested_by TEXT,              -- the box that enqueued it
  claimed_by TEXT,                -- the box / fly machine that took it
  claimed_at TEXT,
  enqueued_at TEXT NOT NULL,
  finished_at TEXT,
  reason TEXT,                    -- why it failed, or why it was released. Never a secret.
  meta TEXT,                      -- JSON; NO SECRETS, same rule as jobs.meta
  updated_at TEXT NOT NULL,
  -- BH-1026.0: WHICH Fly machine took it, when a machine took it at all. The
  -- fleet's answer to "is this key already building" is state/fly/<p>-active.json
  -- on ONE box, so a dispatcher that cannot reach that box cannot see the live
  -- build and spawns a second machine for a key already in flight (the TK-70
  -- shape). Nullable and NEVER backfilled: a row claimed by a local build has no
  -- machine and must keep reading exactly as it does today.
  -- IT BELONGS TO THE CLAIM, not to the ticket: the release path (PATCH to
  -- `queued`) and the re-queue (POST /api/queue) both clear it, so a `claimed`
  -- row names the machine of the claim that set it or names none. A dead id
  -- left behind would be re-read as the live location of the next claim.
  -- KEPT IN SYNC WITH ADDED_COLUMNS (src/lib/core.js): this CREATE reaches only
  -- a FRESH database, so the live one is widened by that map and by nothing else.
  machine TEXT,
  PRIMARY KEY (project, ticket_key)
);
-- The dispatcher's question is always "what is queued for this project", and
-- the console's is "what is queued anywhere" — both answered from this index.
CREATE INDEX IF NOT EXISTS idx_build_queue_status ON build_queue(status, project, enqueued_at);

-- ── THE MERGE QUEUE (2026-09-10) ────────────────────────────────────────────
-- state/merge-queue/<project>/<pr-number> — an EMPTY FILE per PR, plus a
-- `<pr>.blocked` sibling — written by bin/tier2-merge-sweep.sh,
-- bin/run-build.sh, bin/review-prs.sh and, over ssh, by bin/fly-pool.sh and
-- bin/fly-results-ingest.sh. That last pair is the hop this table removes: a
-- fly build that finished on the hub's machine reaches into the owning watcher
-- box to `touch` a filename, because the queue it must join lives on that box.
--
-- A FILENAME CANNOT SAY WHY. `.blocked` records that a PR was stopped and
-- nothing about what stopped it — the reason lives only in a beat that scrolled
-- past. `reason` is strictly more than the convention it replaces, and it is
-- the field an operator actually needs when they find a PR parked.
--
-- FOUR STATUSES, and the fourth is a deliberate addition to the three the brief
-- named. `queued`, `blocked` and `landed` cannot describe a PR dequeued because
-- it is no longer open — it has not landed and nothing is blocking it — and
-- calling that `landed` would put a lie in the one ledger a merge decision
-- reads. `dropped` carries the state that removed it.
--
-- `blocked` IS RE-QUEUEABLE, and that is fidelity to today rather than a
-- choice: bin/tier2-merge-sweep.sh tests `[ -f <Q>/<num> ]` only, so a PR moved
-- aside to `<num>.blocked` is re-enqueued on its next pass. Matching that keeps
-- this table a description of the existing policy instead of a new one.
--
-- THIS IS NOT A DONE-LIST. Whether a PR has already been merged is answered by
-- the `ledgers` row (kind=merge) that bin/merge-sweep.sh has written since
-- phase 2, and by nothing else. A second copy of that fact here would drift,
-- and the copy that drifts is the one that merges something twice.
--
-- SHIPS EMPTY, files stay the fallback: same contract as build_queue above.
CREATE TABLE IF NOT EXISTS merge_queue (
  project TEXT NOT NULL,          -- fleet.conf project name
  pr INTEGER NOT NULL,            -- the PR number — the file queue's filename
  status TEXT NOT NULL,           -- queued | blocked | landed | dropped
  repo TEXT,                      -- owner/name, so a reader needs no fleet.conf
  reason TEXT,                    -- why it blocked / dropped. NEVER a secret.
  enqueued_by TEXT,               -- the box or lane that put it here
  enqueued_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, pr)
);
CREATE INDEX IF NOT EXISTS idx_merge_queue_status ON merge_queue(status, project, enqueued_at);

-- ── WAKES: EVENTS, NOT CLOCKS (2026-09-12) ──────────────────────────────────
-- Every post-review stage of a ticket advanced only when a clock said so: the
-- conductor every 5 minutes, merge-sweep every 10, the deploy train every 15
-- (plus a 20-minute self-source floor), post-merge QA every 30-60, and the
-- triage gate's 45-minute queue brake on top. Worst case that is 150-240
-- minutes of a ticket sitting still with nothing wrong — pure waiting, because
-- no receiver existed anywhere in bin/, worker/ or console-ui/functions and the
-- only way the fleet learned that GitHub had changed was to go and look.
--
-- A ROW HERE IS A DOORBELL, NOT A MESSAGE. It records THAT something changed on
-- a repo, named by identifiers only — repo slug, a PR number, an issue number,
-- a sha — and never what changed. The lanes still re-read GitHub exactly as they
-- do today; a webhook payload is attacker-adjacent data (anyone who learns the
-- URL can POST, and the signature only proves the SENDER, never the CONTENT's
-- relationship to reality), so nothing downstream may believe a word of it. The
-- worst a forged-but-signed row can do is make a lane run a tick early.
--
-- IDEMPOTENT ON (repo, kind, key, minute). GitHub redelivers, and a PR that is
-- synchronized, reviewed and check-completed inside one minute is ONE doorbell
-- press as far as any lane is concerned: the conductor re-reads the whole PR
-- either way. The minute bucket is part of the primary key and the insert is
-- ON CONFLICT DO NOTHING, so a redelivery storm cannot turn into a launch storm.
--
-- THE CRON LINES STAY. This table makes the fleet FASTER, never load-bearing:
-- with the webhook uninstalled, the secret unset or this worker unreachable, no
-- row is ever written and every lane ticks on its clock exactly as it does
-- today. That is the whole safety argument — see docs/EVENTS.md.
--
-- SHIPS EMPTY, and stays empty until an operator creates the GitHub webhook and
-- sets GITHUB_WEBHOOK_SECRET.
CREATE TABLE IF NOT EXISTS wakes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,             -- owner/name, verbatim from the delivery
  kind TEXT NOT NULL,             -- pr | checks | push | deploy | issue | deploy_failed | merge_group (BH-4058)
  key TEXT NOT NULL,              -- PR number, issue number or sha — an IDENTIFIER, never content
  event TEXT,                     -- the X-GitHub-Event name, for the log line only
  minute TEXT NOT NULL,           -- at, truncated to the minute — the dedupe bucket
  at TEXT NOT NULL,               -- server clock when the delivery landed
  acked_at TEXT                   -- set by POST /api/wakes/ack once a loop has run the owning lane
);
-- The loop's only question is "what is new for me" — answered by id order, with
-- the repo filter for a box that watches one project. UNIQUE is the dedupe.
CREATE UNIQUE INDEX IF NOT EXISTS idx_wakes_dedupe ON wakes(repo, kind, key, minute);
CREATE INDEX IF NOT EXISTS idx_wakes_unacked ON wakes(acked_at, id);
-- BH-1267: AGE. Nothing deleted a wake until this ticket, so the table was pure
-- growth; POST /api/wakes/prune walks `at < ?1 ORDER BY at ASC LIMIT ?2` once a
-- day and this index is what turns that into a covering index search instead of
-- a scan of every row ever written. (Measured: GET /api/wakes/summary's
-- `at >= ?1 GROUP BY repo` keeps choosing idx_wakes_dedupe, which already
-- delivers repo order — this index is for the prune.)
CREATE INDEX IF NOT EXISTS idx_wakes_at ON wakes(at);

-- ── BH-433: PR ownership and coordination topics (2026-09-16) ────────────────
-- Worker-side tables for the hub to push PR ownership, merge decisions,
-- review findings, and telegram thread mappings. All are additive and
-- re-runnable; writes are behind the same bearer gate as the rest of /api.

CREATE TABLE IF NOT EXISTS pr_owners (
  repo TEXT NOT NULL,
  number INTEGER NOT NULL,
  project TEXT,
  state TEXT NOT NULL,
  since TEXT NOT NULL,
  reason TEXT,
  key TEXT,
  url TEXT,
  author TEXT,
  draft INTEGER NOT NULL DEFAULT 0,
  dirty_since INTEGER,
  closed_at TEXT,
  actor TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, number)
);
CREATE INDEX IF NOT EXISTS idx_pr_owners_project ON pr_owners(project, closed_at);

CREATE TABLE IF NOT EXISTS decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  stamp TEXT NOT NULL,
  project TEXT NOT NULL,
  gate TEXT,
  scope TEXT,
  ticket TEXT,
  line TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_decisions_dedupe ON decisions(project, stamp, line);
CREATE INDEX IF NOT EXISTS idx_decisions_stamp ON decisions(stamp);

CREATE TABLE IF NOT EXISTS findings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  stamp TEXT NOT NULL,
  project TEXT NOT NULL,
  ticket TEXT,
  lens TEXT,
  line TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_findings_dedupe ON findings(project, stamp, line);
CREATE INDEX IF NOT EXISTS idx_findings_stamp ON findings(stamp);

CREATE TABLE IF NOT EXISTS telegram_topics (
  project TEXT PRIMARY KEY,
  thread_id INTEGER NOT NULL,
  actor TEXT,
  updated_at TEXT NOT NULL
);

-- HUB-NESS IS A LEASE, NOT A BOX (BH-429, after the hub wipe of 2026-09-15).
-- ONE ROW, forever: `CHECK (id=1)` is what makes "who is the hub" a single fact
-- the whole fleet reads, instead of a row per box that two boxes could both own.
-- `epoch` is the fencing token. Every change of ownership bumps it inside the
-- same statement that writes `holder`, so a box holding a cached epoch cannot
-- renew a lease it has already lost — it gets a 409 and learns the truth.
-- `expires_at`/`updated_at` are the SERVER's clock (ISO seconds, Z): fleet boxes
-- were 66-464 s slow on 2026-09-14, so expiry is never judged on a box's clock.
CREATE TABLE IF NOT EXISTS hub_lease (
  id INTEGER PRIMARY KEY CHECK (id=1),
  holder TEXT NOT NULL,
  epoch INTEGER NOT NULL DEFAULT 0,
  expires_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Conductor held pages (BH-1201 / BH-1381). Key is the hold's identity: a moved
-- head or new state is a new hold. first_held_at is the age and never moves.
CREATE TABLE IF NOT EXISTS conductor_held_pages (
  repo TEXT NOT NULL,
  number INTEGER NOT NULL,
  state TEXT NOT NULL,
  head TEXT NOT NULL,
  kind TEXT NOT NULL,
  text TEXT NOT NULL,
  mark TEXT,
  mode TEXT NOT NULL,
  first_held_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  PRIMARY KEY (repo, number, state, head, kind)
);
CREATE INDEX IF NOT EXISTS idx_conductor_held_first ON conductor_held_pages(first_held_at);

-- ── SHARED FACTS THAT USED TO BE PER-BOX FILES (BH-1043, audit §2.4) ────────
-- The 2026-09-19 spend/state audit found three facts every box kept its own
-- copy of, all three of which are only true fleet-wide.
--
-- ACCOUNT LEASES. bin/lib/pool-account.sh counts live leases as FILES under
-- state/quota/leases/<account>/<machine-id>, so a second box counts zero and
-- leases the same account the first box just filled: fly/account-capacity.conf
-- says a claude account carries ~4 concurrent sessions, and two boxes at cap 4
-- put 8 on it. The row is the shared count, and the CAS below is what makes
-- "one wins" true instead of hoped for: the cap is checked INSIDE the insert,
-- against rows that have not expired on the SERVER's clock.
--
-- (account, machine_id) is the key, not (account) — a machine renewing its own
-- lease must not be refused by its own row, and the count subquery excludes it
-- for the same reason. expires_at is the TTL: a machine that vanished without a
-- release frees the account by aging out, which a counter could never do.
CREATE TABLE IF NOT EXISTS account_leases (
  account TEXT NOT NULL,
  machine_id TEXT NOT NULL,
  box TEXT,
  project TEXT,
  ticket_key TEXT,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (account, machine_id)
);
CREATE INDEX IF NOT EXISTS idx_account_leases_live ON account_leases(account, expires_at);

-- TOKEN HEALTH (BH-2516.0, BH-2644). Nothing records when a Claude OAuth login
-- expires, when it last refreshed, or that a GitHub App token mint failed, so a
-- dead token is found by the build it kills. One row per credential:
--   kind 'oauth'   subject = the Claude login label, the `account` in account_leases
--   kind 'gh_app'  subject = 'app-<installation id>'
-- This slice only creates the table; no route writes or reads it yet (the
-- BH-2516 siblings add the reporter and the read). D1 has no RLS: the worker
-- bearer guards /api/*, the same stance as fleet_cooldowns. The PK covers the
-- lookups, so there is no index.
CREATE TABLE IF NOT EXISTS token_health (
  kind TEXT NOT NULL,
  subject TEXT NOT NULL,
  box TEXT,
  expires_at TEXT,
  last_ok_at TEXT,
  last_attempt_at TEXT,
  last_ok INTEGER,
  fail_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (kind, subject)
);

-- Its own statement, for the one-seed-per-statement reason given at the
-- gh_quota_alert_pct seed. Nothing reads it yet: the stub health route answers
-- its code default (24) and says so with warn_h_source 'default'.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lib.token-health.token_health_warn_h','24','BH-2516: hours before token expiry the health panel flags red','seed','2026-09-26T00:00:00Z');

-- THE GITHUB BUDGET IS PER TOKEN, NEVER PER BOX. bin/lib/gh-budget.sh caches
-- `gh api rate_limit` at state/gh-budget/<token-fingerprint>.json, per box —
-- but the bucket that number describes belongs to the TOKEN, and the fleet
-- shares one App/PAT identity. Nine boxes each read "4,800 remaining" and each
-- decided it had 4,800 to spend. One row per fingerprint is the shared figure,
-- and a box that finds a fresh one skips its own rate_limit read entirely (one
-- read per TTL fleet-wide instead of one per box per TTL).
--
-- fetched_at is epoch seconds, the same unit the file cache carries, and the
-- upsert is MONOTONIC on it: a slow box's older read can never overwrite a
-- newer one, which is the only way "remaining" can be read as a countdown.
CREATE TABLE IF NOT EXISTS gh_budget (
  fingerprint TEXT PRIMARY KEY,
  core_remaining INTEGER,
  core_limit INTEGER,
  core_reset INTEGER,
  graphql_remaining INTEGER,
  graphql_limit INTEGER,
  graphql_reset INTEGER,
  fetched_at INTEGER NOT NULL,
  box TEXT,
  updated_at TEXT NOT NULL
);

-- ── The fleet GitHub-call ledger (BH-1574) ──────────────────────────────────
-- One row per (box, UTC hour, caller, project, token meter, rate-limit bucket,
-- method, path class, status, source): the hourly AGGREGATE of that box's
-- state/gh-rest-ledger/<hour>.tsv, pushed by bin/gh-ledger-push.sh every ten
-- minutes from the hub, the boxes and every Fly builder, read by
-- bin/gh-quota-report.sh.
--
-- WHY. The hub App installation (161623167) is ONE 6,600/h bucket shared by
-- eight machines and the pool, and the report read only the box it ran on — so
-- the bucket looked ~5,000/h "unaccounted" when most of it was other boxes'
-- ledgers nobody summed (2026-09-23 gh-reads audit). The files stay the
-- write-ahead truth on each box (48h); this is the copy that answers the fleet.
--
-- THE PUSH IS AN UPSERT, NOT AN APPEND. A box re-reads a whole hour file every
-- time it grew and re-sends that hour's aggregates, so the route REPLACES the
-- numbers on the key: a re-push is a no-op, a grown hour is a correction, and
-- neither is ever a second row.
--
--   meter      the TOKEN's bucket family: app-<installation id>, pat-<sha12>,
--              pat-default, legacy `app` (gh_quota_bucket, column 10)
--   resource   X-RateLimit-Resource of the response: core | graphql | search …;
--              `-` for a line written before the header was recorded
--   source     rest = gh_rest (bin/lib/gh-rest-ledger.sh); gh = the PATH shim
--              bin/gh-ledger/gh ledgering a raw `gh` call
--   counted    calls GitHub charged (a 304 and a 000 are calls, not charges)
--   remaining_min / used_max / limit_max / reset_max   the header extremes seen
--              that hour — the lowest remaining is the one a drain shows in
--
-- Retention is the `gh.ledger.retention_days` settings row (seeded below), code
-- default 14; each push prunes a bounded slice of hours older than that.
CREATE TABLE IF NOT EXISTS gh_ledger (
  box TEXT NOT NULL,
  hour TEXT NOT NULL,
  lane TEXT NOT NULL,
  project TEXT NOT NULL,
  meter TEXT NOT NULL,
  resource TEXT NOT NULL,
  method TEXT NOT NULL,
  path_class TEXT NOT NULL,
  status TEXT NOT NULL,
  source TEXT NOT NULL,
  calls INTEGER NOT NULL,
  counted INTEGER NOT NULL,
  remaining_min INTEGER,
  used_max INTEGER,
  limit_max INTEGER,
  reset_max INTEGER,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (box, hour, lane, project, meter, resource, method, path_class, status, source)
);
CREATE INDEX IF NOT EXISTS idx_gh_ledger_hour ON gh_ledger(hour);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('gh.ledger.retention_days','14','BH-1574: days of hourly gh_ledger aggregates D1 keeps; each POST /api/metrics/gh-ledger prunes older hours (bounded)','seed','2026-09-23T00:00:00Z');

-- ── Per-lane liveness and box-local flag sightings (BH-1165) ────────────────
-- THE `lanes` TABLE IS KEYED (project, box) AND BELONGS TO TRIAGE. That is why
-- phase A's control plane showed `last_tick_at: null` for 77 of 78 lanes: a
-- merge-conductor tick had nowhere to land, and posting it into `lanes` would
-- have refreshed a clock the stale-lane pager reads for something else — a dead
-- triage lane rendered alive by a sibling that is working fine.
--
-- So one row per (lane, project, box), written by bin/lib/lane-gate.sh on EVERY
-- tick, gated or not. `paused` is not a gap: a lane an operator stopped is
-- still alive, and a page that cannot tell "stopped" from "dead" is the page
-- this whole ticket exists to stop shipping. project is '-' for a hub- or
-- box-scoped lane, never NULL, because a NULL in a composite PRIMARY KEY lets
-- SQLite store the same lane twice.
CREATE TABLE IF NOT EXISTS lane_ticks (
  lane TEXT NOT NULL,             -- catalog/lanes.json id
  project TEXT NOT NULL,          -- fleet.conf slug, or '-' for hub/box lanes
  box TEXT NOT NULL,
  last_tick_at TEXT NOT NULL,
  last_outcome TEXT NOT NULL,     -- ran | paused
  why TEXT,                       -- which switch gated it, when paused
  updated_at TEXT NOT NULL,
  PRIMARY KEY (lane, project, box)
);
CREATE INDEX IF NOT EXISTS idx_lane_ticks_lane ON lane_ticks(lane, last_tick_at);

-- A FLAG FILE ON A BOX THAT NO ROW DROVE. A hand `touch flags/lane-off-x`, or a
-- cost autohalt, is a real stop that this worker cannot see — so the page said
-- the lane was ON. The gate now reports what it found here.
--
-- IT IS A SIGHTING, NOT A DECISION. Nothing reads this table to gate anything:
-- writing the file back into pause_flags would turn one box's hand touch into a
-- fleet-wide stop the next time every other box reconciled, which is a
-- reporting mechanism changing what it reports. One row per (name, box), so two
-- boxes holding the same switch are two lines and not one overwriting the other.
CREATE TABLE IF NOT EXISTS lane_flag_sightings (
  name TEXT NOT NULL,             -- the flags/ file name found
  box TEXT NOT NULL,
  lane TEXT,                      -- the registry lane that read it
  project TEXT,
  active INTEGER NOT NULL,        -- 1 = the file is there, 0 = it went away
  seen_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (name, box)
);
CREATE INDEX IF NOT EXISTS idx_lane_flag_sightings_lane ON lane_flag_sightings(lane, active);

-- ── MERGE TRAINS (BH-1269) ──────────────────────────────────────────────────
-- bin/batch-resolve.sh builds a union branch out of N approved PRs, runs one CI
-- run over it and lands it with a merge commit so every member becomes merged
-- by ancestry. Until this table the ONLY record of that was
-- state/batch-resolve/<project>/train-*.json on ONE box: Mission Control could
-- not show a train at all, and a box that was rebuilt while a train was in
-- flight lost the members, the union sha and the run — so nothing could settle
-- it and every member sat held until the seven-day gc.
--
-- ONE ROW PER TRAIN, KEYED ON ITS BRANCH, because the branch is the only name a
-- train has before its PR exists (the record is written BEFORE `pr create`, so
-- a crash in that window is reconcilable). `members` is the csv of PR numbers,
-- deliberately denormalised: a train is read whole or not at all, and a join
-- table for a list that is never queried by member would be a second thing to
-- keep true.
--
-- THIS IS NOT A DONE-LIST either. Whether a member PR's work landed is the
-- `ledgers` row (kind=pr_merged, merged_via=batch:<sha>) and nothing else.
CREATE TABLE IF NOT EXISTS merge_trains (
  project TEXT NOT NULL,          -- fleet.conf project name
  branch TEXT NOT NULL,           -- batch/<project>/<stamp>-<pid>-<n>
  repo TEXT,                      -- owner/name, so a reader needs no fleet.conf
  train_pr INTEGER,               -- the train's own PR number, once it exists
  members TEXT,                   -- csv of member PR numbers, in train order
  member_count INTEGER,
  union_sha TEXT,                 -- the sha CI ran once over
  run_id TEXT,                    -- that one workflow run
  outcome TEXT NOT NULL,          -- creating | open | landed | abandoned
  merge_sha TEXT,                 -- what it landed as
  detail TEXT,                    -- why it ended that way. NEVER a secret.
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, branch)
);
CREATE INDEX IF NOT EXISTS idx_merge_trains_outcome ON merge_trains(outcome, project, created_at);

-- ── STATE→DB SLICE 8 (BH-1033): the two log-as-state stores ────────────────
-- Both of these are a FILE ON ONE BOX that a fleet-wide decision depends on.
--
-- logs/READY-QUEUE.log needs no new table. "This ticket is ready to build" is
-- a `build_queue` row that has not been claimed yet, and the only thing missing
-- from that table was a status ahead of `queued`: `queued` means a build has
-- been enqueued and any dispatcher may claim it, which is NOT what a ready line
-- says. So `ready` joins the status vocabulary (the column is TEXT and the
-- graph lives in the worker's QUEUE_TRANSITIONS), and `dropped` records a line
-- a triage session consumed. A `ready` row is never claimable: every claim path
-- selects `status='queued'` and none of them is touched by this slice.
--
-- state/closeout-aged-out.tsv DOES need one. Its rows are not builds — they are
-- decisions ABOUT build records ("old enough that paging about it is noise"),
-- keyed on a build DIRECTORY, and they outlive every queue row. Said exactly:
-- that tsv is the AUDIT set, NOT the paging gate — bin/pipeline-health.sh stops
-- alerting from the RESULT's own mtime and never reads this file to decide, and
-- this slice does not touch that. So losing the file (a box rebuild, a state
-- restore, a rotation, an operator clearing it) pages nothing; it loses the
-- RECORD of a verdict the fleet already made, and the next sweep re-appends a
-- row for every aged dir still under builds/ — an audit refill. The decision
-- has to live where the fleet can read it, not on whichever box swept.
--
-- THE FILES STAY. Both lanes keep writing them for a full cycle: the log is
-- still the log, the tsv is still the archive, and each is the fallback the
-- moment this worker is unreachable.
CREATE TABLE IF NOT EXISTS closeout_aged (
  build_dir TEXT PRIMARY KEY,     -- the record's directory name, the tsv's key
  project TEXT,                   -- fleet.conf project name, for the read-back
  result_head TEXT,               -- the RESULT's first line, flattened to one
  reason TEXT,                    -- why it aged out. NEVER a secret.
  recorded_by TEXT,               -- the box that decided it
  at TEXT NOT NULL                -- when. The server's clock, like every other.
);
CREATE INDEX IF NOT EXISTS idx_closeout_aged_project ON closeout_aged(project, at);

-- BOTH LAND DARK. At `0` no lane's behaviour changes at all — not one request
-- beyond the settings read — and the flag row is the whole rollback.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('ready_queue_rows','0','BH-1033: the READY queue is build_queue ready ROWS first, logs/READY-QUEUE.log second','seed','2026-09-20T00:00:00Z'),
  ('closeout_aged_table','0','BH-1033: the age-out audit is the closeout_aged TABLE first, state/closeout-aged-out.tsv second','seed','2026-09-20T00:00:00Z');

-- ── BH-1025.0 (child of BH-1025): PR STATE AND ATTEMPTS, AS ROWS ────────────
-- state/merge-conductor/pr-state.tsv and state/merge-conductor/attempts.txt
-- are two files on ONE box that the whole fleet's merge behaviour depends on.
-- attempts.txt was 396 KB on the hub on 2026-09-22 with no twin anywhere: lose
-- it and every open PR is offered one more rebase and one more re-review, which
-- is real money; and `alerted` lives only in the tsv, so a hub restore re-pages
-- about every PR it already paged about.
--
-- pr_state_events is an EVENT log, not a current-state table, because the
-- thing the conductor needs to dedupe on is a sighting: (repo, number, state,
-- since, alerted). `alerted` is NOT NULL DEFAULT '-' on purpose — a NULL never
-- collides in a SQLite UNIQUE index, so a nullable column here would let the
-- same sighting insert forever and the dedupe index would be decorative.
-- pr_state is the current state: the MAX(id) event per PR, as a view, so the
-- readers cannot disagree about what "latest" means.
--
-- LANDS DARK. Nothing reads or writes any of this until the `pr-state-rows`
-- flag is up, and the routes are a sibling child (#1386). The files stay: they
-- are still the ledger of record for one full cycle.
--
-- BH-4953 (BH-4950.0): PR GATE FACTS. Eleven nullable columns ride on this
-- table — draft, closed, held, hotfix (INTEGER 0/1), ci_green_sha,
-- builder_approved_sha, lead_verdict_sha, lead_verdict_word, reviewing_sha,
-- review_failed_sha, nudged_sha (TEXT) — and they are NOT in the CREATE below:
-- D1 has no ADD COLUMN IF NOT EXISTS, so they are applied by ensureColumns
-- (worker/jobs/src/lib/core.js ADDED_COLUMNS) before any gate read or write.
-- Gate facts are rows with state='gate', folded per field (latest non-null by
-- id) in src/lib/pr-gate.js. The pr_state view below still counts them, so
-- every current-state reader (GET /api/pr-state, the daily digest) excludes
-- state='gate' itself.
CREATE TABLE IF NOT EXISTS pr_state_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL, number INTEGER NOT NULL, state TEXT NOT NULL, since TEXT NOT NULL,
  head TEXT, reviewed TEXT, reason TEXT, url TEXT,
  alerted TEXT NOT NULL DEFAULT '-',
  at TEXT NOT NULL, actor TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_pr_state_events_dedupe ON pr_state_events(repo, number, state, since, alerted);
CREATE INDEX IF NOT EXISTS idx_pr_state_events_pr ON pr_state_events(repo, number, id);
CREATE INDEX IF NOT EXISTS idx_pr_state_events_state_at ON pr_state_events(state, at);
CREATE VIEW IF NOT EXISTS pr_state AS SELECT e.* FROM pr_state_events e WHERE e.id = (SELECT MAX(id) FROM pr_state_events WHERE repo=e.repo AND number=e.number);
CREATE TABLE IF NOT EXISTS pr_attempts (
  repo TEXT NOT NULL, number INTEGER NOT NULL, kind TEXT NOT NULL, sha TEXT NOT NULL,
  at TEXT NOT NULL, actor TEXT,
  PRIMARY KEY (repo, number, kind, sha)
);

-- ── THE DEPLOY QUEUE (BH-1026.0) ────────────────────────────────────────────
-- state/deploy-queue/<project>/<epoch>-<sha8> — ONE FILE PER REQUEST, holding
-- `<merge-sha> <build-dir>` on a single line (bin/deploy-request.sh:17; the
-- build-dir reads `self-sourced` when bin/deploy-train.sh enqueued it itself).
-- bin/deploy-train.sh drains the whole directory as one batch and reads the sha
-- back with `cut -d' ' -f1`. Same shape as the build queue before it was a
-- table, and the same two problems: a queue that lives in a directory on one
-- box can only be read by reaching into that box, and a box rebuilt with
-- departures pending loses every one of them with no record that they existed.
--
-- (project, sha) IS A DELIBERATE CHANGE OF IDENTITY, not a copy of the file
-- store's. The filename keys on <epoch>-<sha8>, so the SAME sha requested twice
-- is two files and the train departs on both; this table collapses that to one
-- row, because "deploy this commit" is a desired END STATE and deploying one
-- sha twice is a double-move (the exactly-once iron law), not two units of
-- work. The cost of the collapse is that a repeat request is no longer a new
-- row, so THE WRITER CONTRACT IS RE-OPEN, NEVER `INSERT OR IGNORE`: a request
-- for a sha whose row is terminal must set status back to `queued` and clear
-- departed_at/reason. The case that proves it is real — bin/deploy-train.sh:60,
-- the self-sourced departure, which fires precisely when a sha has already
-- departed `done` and production is STILL not serving it. An `INSERT OR IGNORE`
-- there would no-op against that row, the train would see an empty queue, and
-- production would stay stale with no departure and no alert: the exact outage
-- the self-source path exists to end.
--
-- SHIPS EMPTY, and the directory stays the write-through cache and the fallback
-- for a full cycle — `deploy_queue_rows` below is `0`, so nothing reads this
-- table yet and no deploy lane changes its source of truth in this slice.
CREATE TABLE IF NOT EXISTS deploy_queue (
  project TEXT NOT NULL,          -- fleet.conf project name
  sha TEXT NOT NULL,              -- the merge sha asked for, the first field of the file
  build_dir TEXT,                 -- the build record that asked, or `self-sourced`
  status TEXT NOT NULL,           -- queued | claimed | held | done | failed (held: BH-3154 operator hold)
  claimed_by TEXT,                -- the box that took the departure
  reason TEXT,                    -- why it failed, or why it was released. Never a secret.
  enqueued_at TEXT NOT NULL,
  departed_at TEXT,               -- when the train actually left
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, sha)
);
-- The drain's question is always "what is queued for this project, oldest
-- first", and the console's is "what is queued anywhere" — both ride this index.
CREATE INDEX IF NOT EXISTS idx_deploy_queue_status ON deploy_queue(status, project, enqueued_at);

-- ── THE THREE QUEUES-ARE-ROWS KNOBS (BH-1026.0) ─────────────────────────────
-- THREE ROWS, NOT ONE, on purpose: the sibling slices of #1026 land as separate
-- PRs, and a single shared knob would arm a lane whose PR had not merged yet.
-- All three land DARK at `0` — off is today's behaviour byte for byte, not one
-- request beyond the settings read — and the row is the whole rollback.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('build_queue_rows_only','0','BH-1026: the build queue is build_queue ROWS first, state/build-queue + state/fly/<p>-active.json second','seed','2026-09-22T00:00:00Z'),
  ('merge_queue_rows_only','0','BH-1026: the merge queue is merge_queue ROWS first, state/merge-queue/<p>/<pr> second','seed','2026-09-22T00:00:00Z'),
  ('deploy_queue_rows','0','BH-1026: the deploy queue is deploy_queue ROWS first, state/deploy-queue/<p>/<epoch>-<sha8> second','seed','2026-09-22T00:00:00Z');

-- ── BH-1510.0: MODEL ROUTES — the ladder becomes a row ──────────────────────
-- the operator, 2026-09-22: "We shouldn't have hardcodes anywhere; all of that should
-- be DB values." 136 model-id literals were measured on main (b4912c5c) across
-- ~40 files — every lane's model, and every failover rung below it, typed as a
-- `${VAR:-claude-fable-5-1}` shell default or a bare argv literal. There was no
-- table and no resolver: an operator who wanted to move one lane to a different
-- model had to find every call site that carried it and ship a deploy.
--
-- THIS SLICE IS THE CONTRACT ONLY. It creates the table, the audit trail and
-- the routes, and seeds TODAY's effective model into every role it could
-- verify against a literal on main — nothing reads from here yet. No lane's
-- behaviour changes: every caller still resolves its own env-var fallback
-- exactly as it does today. #1510.1 and #1510.2 point the build lanes and
-- every other lane at bin/lib/model-route.sh's resolver; that PR is the one
-- that turns this table from documentation into truth.
--
-- SHAPE. `role` names a JOB, not a runner: `build.execute`, `build.review`,
-- `triage`, `codex.default`, … — the same vocabulary #1510's issue body lists.
-- `position` is the failover order within a role's ladder, 0 = primary. A row
-- with `project` NULL is the HUB DEFAULT for that role+position; a row with
-- `project` set belongs to a project OVERRIDE of that role. PRECEDENCE IS PER
-- ROLE, NOT PER POSITION: a project that has any row for a role owns that
-- role's WHOLE ladder, and the hub's rungs are not consulted for it at all —
-- a project never overrides position 0 alone and inherits the hub's 1/2 rungs.
-- worker/jobs/src/lib/core.js resolveModelLadder and bin/lib/model-route.sh
-- model_ladder both implement it that way (a whole-ladder PUT, a whole-scope
-- reset), and a scope whose rows do not start at position 0 is no scope.
--
-- WHY NOT A PLAIN COMPOSITE PRIMARY KEY. SQLite (and D1) never equate two NULLs
-- in a uniqueness check, so `PRIMARY KEY (project, role, position)` would let
-- an unlimited number of hub rows (project IS NULL) collide at the same
-- (role, position) — exactly the row a hub PUT is supposed to replace. The
-- issue's own design names the fix: `unique (coalesce(project,''), role,
-- position)`, expressed here as an INTEGER PRIMARY KEY plus a UNIQUE INDEX on
-- that COALESCE expression, so a hub row and a project row can never collide
-- with each other and two hub rows for the same role+position always collide
-- with themselves.
--
-- NO RLS STEP. This is Cloudflare D1, reached only through the bearer-authed
-- worker (HARNESS_SECRET) — same as every other table in this file (see
-- docs/DB-COORDINATION-SPEC.md:320,502). The Supabase RLS doctrine this repo's
-- other rules import does not apply to a D1 binding; the worker's bearer check
-- (src/lib/http.js bearerOk) is the access boundary here, and it already gates
-- every route below.
CREATE TABLE IF NOT EXISTS model_routes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  scope TEXT NOT NULL,             -- 'hub' | 'project', decorative — project IS NULL is the real switch
  project TEXT,                    -- NULL = hub default; fleet.conf project name otherwise
  role TEXT NOT NULL,              -- the job this rung serves: build.execute, triage, codex.default, ...
  position INTEGER NOT NULL,       -- 0 = primary; 1.. = failover order within this role+scope
  model TEXT NOT NULL,             -- must exist in model_prices at write time (PUT /api/model-routes)
  runner TEXT NOT NULL,            -- claude | codex | openrouter | grok | fireworks
  updated_by TEXT,                 -- who wrote this rung last (a box name, an operator, or 'seed')
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_model_routes_key
  ON model_routes(coalesce(project,''), role, position);
CREATE INDEX IF NOT EXISTS idx_model_routes_role ON model_routes(role, project);

-- APPEND-ONLY, never updated or deleted: the same shape as verdict_history —
-- one row per WRITE, not per rung, so a role's history reads as a sequence of
-- decisions rather than a single overwritten fact. `before_*` is NULL when the
-- write ADDED a rung that did not exist at that position; `after_*` is NULL
-- when a PUT shortened a ladder and this rung's position no longer exists —
-- both are real answers, not a photograph of an active row.
CREATE TABLE IF NOT EXISTS model_route_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  scope TEXT NOT NULL,
  project TEXT,
  role TEXT NOT NULL,
  position INTEGER NOT NULL,
  before_model TEXT,
  before_runner TEXT,
  after_model TEXT,
  after_runner TEXT,
  actor TEXT NOT NULL,
  reason TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_model_route_changes_role ON model_route_changes(role, project, at);

-- ── Seed: TODAY's effective model per role, so deploying the resolver and this
-- table changed NOTHING. Every value below was first read off a literal or an env-var
-- `${VAR:-...}` fallback on main (b4912c5c, 2026-09-22) — the derivation table
-- in this ticket's PR body names the exact file:line for each row so a reviewer
-- can check it against the source rather than trust this comment. `updated_by`
-- is 'seed' throughout, matching every other seeded table in this file.
--
-- BH-1908 moved the rung-0 values of this seed, and of the #1510.1 and #1510.2
-- seeds below, to the live hub ladders (GET /api/model-routes, as_of
-- 2026-09-24T14:40:55Z), so a fresh D1 runs what the hub runs. The file:line
-- on each row still names the call site that reads the role; the value no
-- longer is that site's old literal. The new rung-1 positions of those ladders
-- are seeded by the guarded BH-1908 statement after the #1510.2 block. One
-- carve-out: alert.triage keeps claude-fable-5-1 as its only rung (see its row).
-- On an already-seeded D1 (the hub) every edit here is a no-op: INSERT OR
-- IGNORE never overwrites a row an operator, or an earlier seed, already wrote
-- (the same rule settings/concurrency_rules follow).
--
-- `build.review.t0` and `build.fix` are seeded further down, by #1510.1 (the
-- slice that points run-build at them). The grep this comment once cited missed
-- the `_T0` spelling: REVIEW_MODEL_T0 and FIX_MODEL are real call sites in
-- bin/run-build.sh, each defaulting to another role's model.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT v.column1, v.column2, v.column3, v.column4, v.column5, v.column6, v.column7, v.column8
  FROM (VALUES
  -- build.execute: bin/run-build.sh:1329 EXECUTE_MODEL, bin/lib/rb/gates.sh:1051, fly/builder-runner.sh:424
  ('hub', NULL, 'build.execute', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- build.execute.fallback: bin/blocked-resolver.sh:496 EXECUTE_MODEL fallback, catalog/lanes.d/blocked-resolver.json:261
  ('hub', NULL, 'build.execute.fallback', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- build.review: bin/run-build.sh:1330, bin/lib/rb/gates.sh:1052, bin/lib/review-model.sh REVIEW_MODEL_FALLBACK,
  --   bin/blocked-resolver.sh:497, bin/review-autopilot.sh:121, bin/review-rescue.sh:364, bin/review-prs.sh:1031 (bare)
  ('hub', NULL, 'build.review', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- build.qa: bin/run-build.sh:1337 QA_MODEL, bin/lib/rb/gates.sh:1059
  ('hub', NULL, 'build.qa', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- build.plan: bin/run-build.sh:1328 PLAN_MODEL, bin/lib/rb/gates.sh:1050 (same value as the standalone plan role below)
  ('hub', NULL, 'build.plan', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- plan (standalone preplan): bin/run-preplan.sh:157 PLAN_MODEL
  ('hub', NULL, 'plan', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- triage: bin/run-triage.sh:271 TRIAGE_MODEL, bin/lib/triage-shards-lib.sh:354, bin/claude-auth-check.sh:60,
  --   catalog/lanes.d/claude-auth-check.json:35, catalog/lanes.d/prompt-eval.json:51,82
  ('hub', NULL, 'triage', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- triage.light: bin/run-triage.sh:294 TRIAGE_MODEL_LIGHT, bin/lib/triage-shards-lib.sh:353,
  --   catalog/lanes.d/prompt-eval.json:58,87, catalog/lanes.d/run-triage.json:131
  ('hub', NULL, 'triage.light', 0, 'claude-sonnet-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- triage.shard: bin/triage-shard.sh:91 SHARD_MODEL=claude-fable-5-1 (bare)
  ('hub', NULL, 'triage.shard', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- decompose: bin/run-decompose.sh:133,184,286 (bare literal, no env override exists today)
  ('hub', NULL, 'decompose', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- orchestrate: bin/orchestrate.sh:258 ORC_MODEL primary, :259 ORC_FALLBACK — the one role in
  --   this statement seeded with both rungs; the others get rung 1 from the BH-1908 statement
  ('hub', NULL, 'orchestrate', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'orchestrate', 1, 'claude-fable-5-1', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- alert.triage: bin/alert-triage.sh:1097, the non-floor (FTIER != floor) default; the floor
  --   variant (line 1093-1094, HOUSEKEEPING_RUNNER=fireworks) is its own lever, not seeded here —
  --   #1510.2 names alert-triage explicitly and is where that branch gets its own role.
  --   BH-1908 carve-out: NOT moved to the live ladder. Rung 0 is the never-seen-family
  --   investigator (bin/alert-triage.sh lane_role_model alert.triage) and stays on Fable 5.1,
  --   which tests/triage-split-test.sh pins (the operator on BH-1908, 2026-09-24)
  ('hub', NULL, 'alert.triage', 0, 'claude-fable-5-1', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- product: bin/product-cmd.sh:47 CHAT_MODEL — representative of run-product.sh's several
  --   sub-stage models (MAP/SIGNALS/IDEATE/SYNTH/PRD/MOCKUP_MODEL), which are genuinely distinct
  --   call sites left for #1510.2 to name as their own sub-roles rather than guessed into one here
  ('hub', NULL, 'product', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- greenfield: bin/greenfield.sh:33 GF_MAP_MODEL — representative of its own several sub-stage
  --   models, same caveat as product above
  ('hub', NULL, 'greenfield', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- rescue.review: bin/review-rescue.sh:364 REVIEW_MODEL fallback, catalog/lanes.d/review-rescue.json:25
  ('hub', NULL, 'rescue.review', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- postmerge.qa: bin/postmerge-qa.sh:127 POSTMERGE_QA_MODEL/QA_MODEL fallback, catalog/lanes.d/postmerge-qa.json:98
  ('hub', NULL, 'postmerge.qa', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- auth.fallback: bin/claude-auth-check.sh:60 AUTH_FALLBACK_MODEL, catalog/lanes.d/claude-auth-check.json:28
  ('hub', NULL, 'auth.fallback', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- codex.default: bin/agent-call.sh:80 CODEX_DEFAULT_MODEL
  ('hub', NULL, 'codex.default', 0, 'gpt-6-astra', 'codex', 'seed', '2026-09-22T00:00:00Z'),
  -- grok.default: bin/agent-call.sh:744 GROK_MODEL fallback (also :1840,:1844,:1877,:2604,:2610,:2783)
  ('hub', NULL, 'grok.default', 0, 'grok-4.7', 'grok', 'seed', '2026-09-22T00:00:00Z'),
  -- fireworks.default: bin/agent-call.sh:660 FIREWORKS_MODEL fallback (the general fireworks rung)
  ('hub', NULL, 'fireworks.default', 0, 'accounts/fireworks/models/kimi-k2p7-code', 'fireworks', 'seed', '2026-09-22T00:00:00Z'),
  -- housekeeping.floor: bin/alert-triage.sh:1093 / bin/alerts-medic.sh:572 HOUSEKEEPING_FLOOR_MODEL
  --   fallback — the cheap floor lane, a DIFFERENT fireworks model than fireworks.default above
  ('hub', NULL, 'housekeeping.floor', 0, 'accounts/fireworks/models/deepseek-v4-flash-0731', 'fireworks', 'seed', '2026-09-22T00:00:00Z'),
  -- bench: bin/runner-bench.sh:25 BENCH_CLAUDE_MODEL fallback
  ('hub', NULL, 'bench', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z')
  ) AS v
  -- BH-1572: never a role with hub audit history — an operator has decided it
  -- (a PUT, or POST /api/model-routes/remove, whose audit rows are its tombstone).
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column3);

-- ── #1510.1: the build lanes' roles that #1510.0 did not seed ──────────────────
-- Each role below is seeded ONLY WHEN IT HAS NO HUB ROW AT ALL, in one
-- statement per role family, so a re-apply on the next deploy can never put
-- back a rung an operator deliberately removed with a whole-ladder PUT (a plain
-- per-rung INSERT OR IGNORE would re-add position 1 to a ladder an operator cut
-- to one rung, every deploy, for ever). SQLite runs an INSERT whose SELECT reads
-- the target table through a temporary copy, so the NOT EXISTS below sees the
-- table as it was before this statement, not half-way through it.
--
-- The values were what main ran after #1523 (BH-1507) when these rows were
-- added; BH-1908 reordered claude.ladder to the live hub ladder. Nothing in
-- this file UPDATEs a row: an UPDATE is not additive, and harness-sync
-- re-applies this file on every deploy, so a live row moves only by an audited PUT.
--
--   build.review.t0  bin/run-build.sh REVIEW_MODEL_T0, which falls back to
--                    REVIEW_MODEL: the same ladder as build.review after #1523.
--   build.fix        bin/run-build.sh FIX_MODEL, which falls back to
--                    EXECUTE_MODEL: the same ladder as build.execute.
--   claude.ladder    bin/agent-call.sh's claude-lane ladder for a call whose own
--                    role does not start at the model it was asked for (every
--                    lane #1510.2 has not converted yet, and any env-pinned
--                    model): Opus 5.5, then Fable, then the Opus CLI floor —
--                    the live hub order (BH-1908).
--   openrouter.floor bin/agent-call.sh's OpenRouter survival rung below the
--                    stage's anthropic/ slug (the provider-independent floor).
--   fireworks.floor  bin/agent-call.sh's Fireworks rung below FIREWORKS_MODEL.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, v.column1, v.column2, v.column3, v.column4, 'seed', '2026-09-23T00:00:00Z'
  FROM (VALUES
    ('build.review.t0', 0, 'claude-opus-5-5', 'claude'),
    ('build.review.t0', 1, 'claude-fable-5-1', 'claude'),
    ('build.fix', 0, 'claude-opus-5-5', 'claude'),
    ('build.fix', 1, 'claude-opus-5', 'claude'),
    ('claude.ladder', 0, 'claude-opus-5-5', 'claude'),
    ('claude.ladder', 1, 'claude-fable-5-1', 'claude'),
    ('claude.ladder', 2, 'claude-opus-5', 'claude'),
    ('openrouter.floor', 0, 'deepseek/deepseek-v4-flash', 'openrouter'),
    ('fireworks.floor', 0, 'accounts/fireworks/models/deepseek-v4-flash-0731', 'fireworks')
  ) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_routes m WHERE m.project IS NULL AND m.role = v.column1)
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column1);

-- Dark by construction: nothing above reads from model_routes yet, so the
-- seed's presence changes zero fleet behaviour. No settings flag is needed to
-- gate it — the gate IS "no caller uses bin/lib/model-route.sh yet", enforced
-- by tests/model-literal-lint.sh staying in WARN mode until #1510.1/.2 convert
-- their call sites and #1510.4 flips the lint to error.

-- ── Seed, #1510.2: the roles the non-build lanes read that #1510.0 did not seed.
-- Same rules as the seed above: INSERT OR IGNORE only (an operator's row, or an
-- earlier seed's, is never overwritten), and every value is TODAY's effective
-- model on main (50380e9b, 2026-09-22), read off the literal each lane carried
-- until #1510.2 deleted it — the file:line is on each row so a reviewer can
-- check the value against the source rather than trust this comment. BH-1908
-- has since moved the claude-fable-5-1 / claude-opus-4-8 rows and
-- openrouter.default to the live hub values (see the #1510.0 header).
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT v.column1, v.column2, v.column3, v.column4, v.column5, v.column6, v.column7, v.column8
  FROM (VALUES
  -- product.*: bin/run-product.sh:80-83 (MAP/SIGNALS/IDEATE/SYNTH_MODEL); product.prd and
  --   product.mockup are bin/draft-proposal.sh:18-19 (run-product.sh:84-85 carried the same
  --   values but never read them); product.revise is bin/product-cmd.sh:165 REVISE_MODEL
  ('hub', NULL, 'product.map', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'product.signals', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'product.ideate', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'product.synth', 0, 'claude-sonnet-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'product.prd', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'product.mockup', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'product.revise', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- greenfield.*: bin/greenfield.sh:34-38 (the MAP stage, :33, is the `greenfield` row above)
  ('hub', NULL, 'greenfield.signals', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'greenfield.ideate', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'greenfield.synth', 0, 'claude-sonnet-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'greenfield.mockup', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'greenfield.deck', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- responder: bin/watchdog-responder.sh:611,617,673 (bare literal, three calls)
  ('hub', NULL, 'responder', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- remediate: bin/remediate-agent.sh:261 REMEDIATE_MODEL
  ('hub', NULL, 'remediate', 0, 'claude-sonnet-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- rule.miner: bin/rule-miner.sh:51 MINER_MODEL
  ('hub', NULL, 'rule.miner', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- lander: bin/lander.sh:89 LANDER_MODEL
  ('hub', NULL, 'lander', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  -- openrouter.default: bin/lane-probe.sh:26 OPENROUTER_MODEL (the openrouter canary)
  ('hub', NULL, 'openrouter.default', 0, 'anthropic/claude-opus-5.5', 'openrouter', 'seed', '2026-09-22T00:00:00Z')
  ) AS v
  -- BH-1572: the tombstone guard, as on the #1510.0 seed above.
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column3);

-- BH-1908: rung 1 of the roles whose live hub ladder has two rungs (read
--   2026-09-24T14:40:55Z). New positions on existing roles: rung 0 is the row seeded
--   above. GUARDED on each role's audit trail, not only on the unique key, for the
--   housekeeping.floor reason below: harness-sync re-applies this file on every deploy,
--   and a plain INSERT OR IGNORE would put rung 1 back the deploy after an operator PUT a
--   one-rung ladder (the PUT deletes the row, so the key no longer collides). Once anyone
--   has written the role at hub scope, the operator owns its shape and this never fires,
--   which is every role here on the live hub. A project-scoped audit row does not count.
--   alert.triage is not here (see its carve-out above).
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, v.column1, 1, v.column2, v.column3, 'seed', '2026-09-24T00:00:00Z'
  FROM (VALUES
    ('auth.fallback', 'claude-opus-5', 'claude'),
    ('build.execute', 'claude-opus-5', 'claude'),
    ('build.execute.fallback', 'claude-opus-5', 'claude'),
    ('build.qa', 'claude-opus-5', 'claude'),
    ('postmerge.qa', 'claude-opus-5', 'claude'),
    ('build.plan', 'claude-fable-5-1', 'claude'),
    ('build.review', 'claude-fable-5-1', 'claude'),
    ('decompose', 'claude-fable-5-1', 'claude'),
    ('greenfield', 'claude-fable-5-1', 'claude'),
    ('greenfield.ideate', 'claude-fable-5-1', 'claude'),
    ('lander', 'claude-fable-5-1', 'claude'),
    ('plan', 'claude-fable-5-1', 'claude'),
    ('product', 'claude-fable-5-1', 'claude'),
    ('product.ideate', 'claude-fable-5-1', 'claude'),
    ('product.map', 'claude-fable-5-1', 'claude'),
    ('rescue.review', 'claude-fable-5-1', 'claude'),
    ('responder', 'claude-fable-5-1', 'claude'),
    ('rule.miner', 'claude-fable-5-1', 'claude'),
    ('triage', 'claude-fable-5-1', 'claude'),
    ('triage.shard', 'claude-fable-5-1', 'claude'),
    ('grok.default', 'grok-4.6', 'grok'),
    ('openrouter.default', 'anthropic/claude-fable-5.1', 'openrouter')
  ) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.role = v.column1 AND c.project IS NULL);

-- housekeeping.floor rung 1: the claude model arg bin/alert-triage.sh:1094,1123 and
--   bin/alerts-medic.sh:573 pass on the floor branch — agent-call's fallback when the floor
--   lane (rung 0, seeded above) exits nonzero. A new position on an existing role, not a
--   changed row: rung 0 is untouched. GUARDED on the role's audit trail, not only on the
--   unique key: harness-sync re-applies this file on every deploy, and a plain INSERT OR
--   IGNORE would put this rung back the deploy after an operator PUT a one-rung ladder
--   (the PUT deletes the row, so the key no longer collides). Once anyone has written
--   housekeeping.floor at hub scope, the operator owns its shape and this never fires.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'housekeeping.floor', 1, 'claude-sonnet-5', 'claude', 'seed', '2026-09-22T00:00:00Z'
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes WHERE role = 'housekeeping.floor' AND project IS NULL);

-- ── BH-1766 (BH-1749.4): the runner per build stage, as rows ─────────────────
-- stage.<stage> (bin/lib/model-route.sh stage_route_role spells the name) says
-- which RUNNER a build stage calls and which one it falls back to: today that
-- is RUNNER_<STAGE> / RUNNER_<STAGE>_FALLBACK in env/global.env. For a stage.*
-- role the RUNNER column is what decides. The model is the model that rung runs
-- once agent-call reads these rows, and every id below is reused from a seed row
-- above with the same runner (claude: alert.triage rung 0 and build.fix /
-- build.review.t0 rung 0; codex: codex.default), so no new literal enters here.
--
-- INERT UNTIL the agent-call sibling of #1749 lands: nothing reads stage.* yet
-- (stage_runner_for is a stub answering rc 75). Position 0 = claude is
-- agent-call's default runner; position 1 = codex mirrors the
-- RUNNER_*_FALLBACK=codex template value. The worker caps a stage.* ladder at
-- two rungs (routes/model-routes.js MAX_STAGE_LADDER).
--
-- A box's LIVE values (the hub's RUNNER_TRIAGE=grok) are never seeded here:
-- bin/runner-routes-seed.sh writes those as an audited PUT with the box as the
-- actor. Guarded per role like #1510.1 above, so a re-apply never puts back a
-- rung an operator cut.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, v.column1, v.column2, v.column3, v.column4, 'seed', '2026-09-24T00:00:00Z'
  FROM (VALUES
    ('stage.triage', 0, 'claude-fable-5-1', 'claude'),
    ('stage.triage', 1, 'gpt-6-astra', 'codex'),
    ('stage.plan', 0, 'claude-fable-5-1', 'claude'),
    ('stage.plan', 1, 'gpt-6-astra', 'codex'),
    ('stage.preplan', 0, 'claude-fable-5-1', 'claude'),
    ('stage.preplan', 1, 'gpt-6-astra', 'codex'),
    ('stage.execute', 0, 'claude-opus-5-5', 'claude'),
    ('stage.execute', 1, 'gpt-6-astra', 'codex'),
    ('stage.review', 0, 'claude-opus-5-5', 'claude'),
    ('stage.review', 1, 'gpt-6-astra', 'codex'),
    ('stage.fix', 0, 'claude-opus-5-5', 'claude'),
    ('stage.fix', 1, 'gpt-6-astra', 'codex')
  ) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_routes m WHERE m.project IS NULL AND m.role = v.column1)
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column1);

-- ── BH-2536: a stage.* route for every catalogued stage ─────────────────────
-- Every stage a through_agent_call site in catalog/llm-sites.json passes to
-- agent-call gets a row, so the Models page can switch any of them
-- (tests/stage-route-seed.bh-2536-test.sh is the ratchet). ONE rung, claude, no
-- fallback: that is what agent-call runs for a stage with no route today, so
-- seeding it changes no runner. stage_runner_for reads only the RUNNER column of
-- a stage.* row; the model below is what the Models page shows. It is reused
-- from stage.execute rung 0 (same runner), so no new literal enters.
-- chat IS seeded: bin/product-cmd.sh and box-chat's primary call run it with no
-- RUNNER_CHAT, so they read this route. Only box-chat's fallback retry exports
-- RUNNER_CHAT, and an env runner that disagrees with a non-claude route is
-- agent-call's existing ALERTS line.
-- Five stages get NO row, on purpose, because their callers decide the runner in
-- code and a route would be a switch that changes nothing: decompose,
-- orchestrator, trapeval and bench (bin/run-decompose.sh, bin/orchestrate.sh,
-- bin/trap-eval.sh and bin/runner-bench.sh set RUNNER_<STAGE> on every call);
-- and eval, which runs under AGENT_CALL_NO_TOOLS=1 and so only on claude.
-- Guarded per role like BH-1766 above: once an operator has written a role, a
-- re-apply never puts this rung back.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, v.column1, v.column2, v.column3, v.column4, 'seed', '2026-09-26T00:00:00Z'
  FROM (VALUES
    ('stage.qa', 0, 'claude-opus-5-5', 'claude'),
    ('stage.preplan-files', 0, 'claude-opus-5-5', 'claude'),
    ('stage.prodqa', 0, 'claude-opus-5-5', 'claude'),
    ('stage.repro', 0, 'claude-opus-5-5', 'claude'),
    ('stage.lead-review', 0, 'claude-opus-5-5', 'claude'),
    ('stage.map', 0, 'claude-opus-5-5', 'claude'),
    ('stage.signals', 0, 'claude-opus-5-5', 'claude'),
    ('stage.ideate', 0, 'claude-opus-5-5', 'claude'),
    ('stage.synth', 0, 'claude-opus-5-5', 'claude'),
    ('stage.prd', 0, 'claude-opus-5-5', 'claude'),
    ('stage.mockup', 0, 'claude-opus-5-5', 'claude'),
    ('stage.revise', 0, 'claude-opus-5-5', 'claude'),
    ('stage.remediate', 0, 'claude-opus-5-5', 'claude'),
    ('stage.mine', 0, 'claude-opus-5-5', 'claude'),
    ('stage.feature-map-draft', 0, 'claude-opus-5-5', 'claude'),
    ('stage.readout', 0, 'claude-opus-5-5', 'claude'),
    ('stage.chat', 0, 'claude-opus-5-5', 'claude')
  ) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_routes m WHERE m.project IS NULL AND m.role = v.column1)
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column1);

-- ── BH-1525: lead verdicts, as rows (2026-09-22) ─────────────────────────────
-- The lead's reviews ran on the Mac and reached the merge lanes as FILES written
-- over an SSH hop to the hub (state/review-autopilot/<slug>-<pr>-<sha12> plus a
-- `provcleared <slug>#<pr> <sha>` line in state/merge-conductor/attempts.txt).
-- A session restart lost in-flight reviews, the hop timed out, a Mac
-- REQUEST_CHANGES was dismissed because it shared the fleet PAT's login, and
-- the vocabulary drifted (APPROVE vs MERGE). This table is the one home for a
-- head-bound verdict any machine holding HARNESS_SECRET can write.
--
-- BOUND TO A HEAD. A verdict is a fact about ONE sha; a push is a new head with
-- no row, which is how "a new push invalidates" is true without anything
-- deleting anything. bin/lib/verdicts.sh asks by (repo, pr, LIVE head) only.
--
-- APPEND-ONLY, ENFORCED BY THE TABLE. The routes offer no edit, but the
-- triggers (see below for where they live) are what make it true: a later answer is a later ROW, and the newest
-- lead/human row on a head is the standing one (GET /api/verdicts `standing`).
--
-- source: lead = the lead's own review; human = a person; box = a pool review.
-- A box row is recorded but never STANDS: it cannot lift a lead/human BLOCK and
-- it cannot clear a lead-authored PR. Same D1 / bearer note as model_routes.
CREATE TABLE IF NOT EXISTS verdicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,              -- owner/name
  pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL,          -- 40 lower-case hex; the sha the reviewer read
  verdict TEXT NOT NULL,           -- MERGE | MERGE-WITH-NOTES | BLOCK
  source TEXT NOT NULL,            -- lead | human | box
  reviewer_model TEXT,             -- the model that read the diff, when a model did
  reviewer TEXT,                   -- who posted the row (a box name, 'mac-lead', a login)
  report_url TEXT,                 -- the markdown report, when one was stored
  note TEXT,                       -- one line of findings for the refusal comment
  created_at TEXT NOT NULL,
  auth TEXT,                       -- secret | lead-token | human-token: the credential that wrote the row (BH-3831); NULL = before BH-3831
  human_sig TEXT,                  -- HMAC-SHA256 the worker signs a human-token row with (HUMAN_VERDICT_SIG_KEY, BH-3846); NULL = unsigned
  review_tier TEXT,                -- low | medium | high: the risk tier of the head (BH-6967); NULL = not said
  review_mode TEXT,                -- full | intent | risk-tier: the review that wrote the row (BH-6967); NULL = not said
  break_it TEXT                    -- clean | failed:<k> | could-not-run: the break-it verifier on this head (BH-6970); NULL = no run
);
CREATE INDEX IF NOT EXISTS idx_verdicts_pr_head ON verdicts(repo, pr, head_sha, id);
-- The two append-only triggers (BEFORE UPDATE / BEFORE DELETE -> RAISE(ABORT))
-- are NOT in this file: tests/schema-additive.bh-1000-test.sh admits only
-- CREATE TABLE/INDEX/VIEW IF NOT EXISTS and INSERT OR IGNORE here. They live in
-- the worker's own CREATED_TABLES.verdicts (src/lib/core.js), which every
-- verdicts route runs (IF NOT EXISTS) before it touches the table, so the
-- deployed table carries them from its first read or write.

-- BH-3565: POST /api/verdicts refuses (426) a lead|human row whose
-- x-lead-verdict-client is below this. 0 = off. The operator sets it to 2 only
-- after the hub's bin/lead-verdict.sh carries LV_CLIENT_LEVEL=2.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lead_verdict_min_client','0','BH-3565: lead|human verdict rows from a bin/lead-verdict.sh below this client level are refused 426; 0 = off','seed','2026-09-29T00:00:00Z');

-- BH-3831: shadow = a source=human verdict without x-human-verdict-token is
-- recorded (verdicts.auth=lead-token) and logged; enforce = refused 403. Only a
-- PUT carrying the human token may change it (routes/settings.js).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('human_verdict_mode','shadow','BH-3831: shadow = a source=human verdict without x-human-verdict-token is recorded (verdicts.auth=lead-token) and logged; enforce = refused 403','seed','2026-10-01T00:00:00Z');

-- BH-3846: shadow = a standing source=human MERGE whose verdicts.human_sig does
-- not verify is logged and still stands as human; enforce = it stands as lead
-- (GET /api/verdicts `standing`). Like human_verdict_mode, only a PUT carrying
-- the human token may change it, and that PUT signs it (`<key>.sig`).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('human_verdict_sig_mode','shadow','BH-3846: shadow = an unsigned/bad-signature standing human MERGE is logged; enforce = it stands as lead','seed','2026-10-02T00:00:00Z');

-- BH-3905 (BH-4087): one row per signed write of a protected setting (the two
-- switches above, lead_authority.* and lead_protected_paths_extra.*). sig =
-- HMAC-SHA256(HUMAN_VERDICT_SIG_KEY, "bh-setting-v2\n<key>\n<value>\n<seq>"),
-- seq per key, so a signed value saved earlier and written back later is bound
-- to its old seq and does not verify as the newest row (protectedMode,
-- routes/verdicts.js). PUT /api/settings is the only writer. The UNIQUE(key,
-- seq) autoindex serves both the newest-row read and the MAX(seq) read. The
-- append-only triggers are not in this file, for the reason the verdicts note
-- above gives: they live in CREATED_TABLES.setting_sigs (src/lib/core.js).
CREATE TABLE IF NOT EXISTS setting_sigs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL,
  seq INTEGER NOT NULL,            -- 1, 2, ... per key; judged newest by seq, never by id
  sig TEXT NOT NULL,               -- hex HMAC over the v2 message above
  actor TEXT,
  at TEXT NOT NULL,
  UNIQUE(key, seq)
);

-- ── BH-1607 (BH-1595.0): reconcile-prs owner heartbeat + reconcile memory ──
-- reconcile_owner_beat: one row per lane. Once the owner sibling lands, the
-- box that owns bin/reconcile-prs.sh stamps beat_at each tick it runs, so an
-- owner that stopped running is judgeable as stale. The seed row is what makes
-- an owner that NEVER beat judgeable too: expected_since starts the clock the
-- day the table lands. alerted_at is for recording that a stale owner was paged.
--
-- reconcile_memory: a D1 copy of the per-kind watermarks the lane keeps today
-- as box-local files under state/reconcile-prs/{open,terminal,gone}, keyed
-- (kind, name), so that a new owner box can start from them.
--
-- Both tables are contract only in this slice: the routes answer 501 until
-- their BH-1595 siblings land, and nothing reads or writes a row yet.
CREATE TABLE IF NOT EXISTS reconcile_owner_beat (lane TEXT PRIMARY KEY, box TEXT, beat_at TEXT, expected_since TEXT NOT NULL, alerted_at TEXT, updated_at TEXT NOT NULL);
INSERT OR IGNORE INTO reconcile_owner_beat (lane, expected_since, updated_at) VALUES ('reconcile-prs', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'));
CREATE TABLE IF NOT EXISTS reconcile_memory (kind TEXT NOT NULL CHECK (kind IN ('terminal','open','gone')), name TEXT NOT NULL, value TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (kind, name));

-- ── BH-1681 (BH-1672.0): pauses ──
-- A pause as a visible, expiring row instead of an env edit on a box. One row
-- per (scope, what) pause: scope is 'fleet' or a project name, what is the lane
-- it stops. A row is live while ended_at IS NULL, and the pauses_live partial
-- unique index keeps at most one live row per (scope, what), so setting the same
-- pause again is a renew of that row, never a second one. end_reason is
-- 'expired' (the expiry sweep stamped it) or 'resumed' (a person ended it).
-- Boxes read pauses through bin/lib/pause.sh from the state/pauses.json cache
-- (the routes and the refresh that fill it are BH-1672 siblings).
-- pause_flags (BH-1370, the flag-file cache contract) is a separate table and
-- this block does not touch it.
CREATE TABLE IF NOT EXISTS pauses (
  id INTEGER PRIMARY KEY,
  scope TEXT NOT NULL,             -- 'fleet' or a project name
  what TEXT NOT NULL CHECK(what IN ('reviews','merges','builds','triage')),
  reason TEXT NOT NULL,            -- why, for the human who finds it later
  actor TEXT NOT NULL,             -- console | box name | a login
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,        -- ISO-8601 UTC, live only while > now
  ended_at TEXT,                   -- NULL = live
  end_reason TEXT                  -- expired | resumed
);
CREATE UNIQUE INDEX IF NOT EXISTS pauses_live ON pauses(scope, what) WHERE ended_at IS NULL;

-- The pause thresholds, one seed per statement (the rule stated above). Nothing
-- reads them in this slice. The BH-1672 siblings that do keep a code constant
-- only as the fallback for a missing row.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pause_default_ttl_s','86400','BH-1672: seconds a pause lives when PUT /api/pauses gets no ttl_s or expires_at (route not implemented yet)','seed','2026-09-24T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pause_env_review_cap_below','5','BH-1672: review-cap threshold for reading an env-shaped reviews pause (pause_env_shapes, not implemented yet)','seed','2026-09-24T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pause_env_laneoff_age_s','86400','BH-1672: lane-off age threshold in seconds for reading an env-shaped pause (pause_env_shapes, not implemented yet)','seed','2026-09-24T00:00:00Z');

-- ── BH-1948 (BH-1525.0): lead review requests ──
-- One row per request for a lead review of one PR head. Contract only in this
-- slice: the /api/lead-reviews routes that read and write it are implemented by
-- the worker sibling, and nothing writes a row yet. D1 (SQLite), not Supabase,
-- so there is no RLS; bin/harness-sync.sh applies this file statement by
-- statement on every deploy, which is the apply mechanism (no hand step).
-- status and verdict carry no CHECK, the same as `verdicts`: the routes validate.
CREATE TABLE IF NOT EXISTS lead_review_requests (
  id TEXT PRIMARY KEY,
  repo TEXT NOT NULL,              -- owner/name
  pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL,          -- the full 40-hex sha the review reads
  scope_notes TEXT,
  prior_verdict_ref TEXT,
  requested_by TEXT,
  status TEXT NOT NULL DEFAULT 'requested', -- requested | running | done | superseded | failed
  job_id TEXT,
  box TEXT,
  verdict TEXT,                    -- MERGE | MERGE-WITH-NOTES | BLOCK | NULL
  report_ref TEXT,
  reviewer_model TEXT,
  detail TEXT,
  promoted_verdict_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(repo, pr, head_sha)
);
CREATE INDEX IF NOT EXISTS idx_lead_review_requests_status ON lead_review_requests(status, repo);
-- BH-5349: heartbeat_at TEXT, participant TEXT and head_authors TEXT (JSON) are
-- ADDED columns: they arrive on the live table by ensureColumns (ADDED_COLUMNS in
-- src/lib/core.js), like BH-5151's priority, and are not in this CREATE, which
-- bh-1948/bh-1949 pin at 17 columns. Nothing reads or writes them yet.

-- The lead review job's model, rank 0 at hub scope. The model string lives
-- ONLY here; the role guard never joins or overwrites an operator's ladder.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'lead.review', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-24T00:00:00Z'
  WHERE NOT EXISTS (SELECT 1 FROM model_routes m WHERE m.project IS NULL AND m.role = 'lead.review');

-- Keyed lead-review/*/*: resolveRetryPolicy looks a lane up only through
-- laneCandidates' <stage>/<project|*>/<runner|*> keys, so this is the key every
-- lead-review lane falls back to.
INSERT OR IGNORE INTO retry_policies (lane, max_attempts, backoff_seconds, escalate_allowed, note, updated_at) VALUES
  ('lead-review/*/*', 2, 300, 0, 'BH-1525: lead review job, seeded by BH-1948', '2026-09-24T00:00:00Z');

-- ── Hub recovery: the lease audit and the restore-lab queue (BH-1942 / BH-1909.0) ──
-- The contract slice of BH-1909. These two tables are created here; the routes
-- that write them are sibling slices (#1943 promote, #1944 restore lab), and
-- until those land the stub routes in src/routes/hub-recovery.js and
-- src/routes/restore-lab.js answer 501 and read nothing.
--
-- hub_lease_changes is APPEND-ONLY. The contract (#1943 implements it): every
-- promote asked for writes one row here, the promote itself in the SAME
-- env.DB.batch as the hub_lease epoch bump (so a promote without its audit row
-- cannot exist) and every refusal (no confirm, unknown box, stale epoch).
-- Nothing updates or deletes a row, and nothing dedups against it.
--
-- restore_lab_runs is the restore-lab queue. The contract (#1944 implements
-- it): the console requests a run, a box claims it with a CAS UPDATE, and the
-- box reports ok or fail. The partial
-- unique index below is the whole "one open run per box+snapshot" rule, so a
-- double click or two consoles cannot queue the same restore twice.
--
-- The enum values sit in comments, not CHECK constraints: D1 cannot ALTER a
-- CHECK, so a later state would need a table rebuild.
--
-- NO RLS STEP. This is Cloudflare D1, reached only through the bearer-authed
-- worker (HARNESS_SECRET) — same as every other table in this file (see
-- docs/DB-COORDINATION-SPEC.md:320,502). The Supabase RLS doctrine this repo's
-- other rules import does not apply to a D1 binding; the worker's bearer check
-- (src/lib/http.js bearerOk) is the access boundary here, and it already gates
-- every route below.
CREATE TABLE IF NOT EXISTS hub_lease_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action TEXT NOT NULL,            -- promote | promote_refused | restore_lab_request | restore_lab_refused
  before_holder TEXT,
  before_epoch INTEGER,
  after_holder TEXT,
  after_epoch INTEGER,
  target TEXT,                     -- the box the request named
  actor TEXT NOT NULL,             -- console | mcp | a login
  reason TEXT,
  outcome TEXT NOT NULL,           -- ok | refused:<why>
  at TEXT NOT NULL                 -- ISO-8601 UTC
);
CREATE INDEX IF NOT EXISTS idx_hub_lease_changes_at ON hub_lease_changes(at);
-- BH-2198: POST /api/hub/promote stays shut (403 promote-disabled) until an
-- operator flips this to '1'. #2158 shipped the route without its split-brain
-- guard; OFF by default means a fresh or re-applied schema never opens it.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('hub.promote_enabled','0','BH-2198: 1 opens POST /api/hub/promote. Stop the old hub (or cut its lane gate) BEFORE promoting: bin/hub-lease.sh fails open while the worker is unreachable (BH-1000)','seed','2026-09-24T00:00:00Z');

CREATE TABLE IF NOT EXISTS restore_lab_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  box TEXT NOT NULL,               -- the box whose backup is restored
  snapshot TEXT NOT NULL DEFAULT 'latest',
  status TEXT NOT NULL,            -- requested|claimed|ok|fail
  requested_by TEXT,
  requested_at TEXT NOT NULL,
  claimed_by TEXT,                 -- the box running the restore
  claimed_at TEXT,
  finished_at TEXT,
  verdict_detail TEXT,
  sha256 TEXT,
  snapshot_ts TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS restore_lab_runs_open ON restore_lab_runs(box, snapshot) WHERE status IN ('requested','claimed');

-- ── BH-2519: hub standby heartbeat + verify queue ────────────────────────────
-- standby_status is one row per standby box: the last heartbeat its stream run
-- reports (ok, the hub it follows, the snapshot it last pulled). standby_verify_runs
-- is the verify-drill queue, shaped like restore_lab_runs: requested, then
-- claimed, then ok or fail. The partial unique index is the "one open verify per
-- box" rule. The routes that read and write these land in BH-2519's sibling
-- slices; this block is the contract.
-- Enum values sit in comments, not CHECKs (D1 cannot ALTER a CHECK).
--
-- NO RLS STEP. This is Cloudflare D1, reached only through the bearer-authed
-- worker (HARNESS_SECRET) — same as every other table in this file (see
-- docs/DB-COORDINATION-SPEC.md:320,502). The worker's bearer check
-- (src/lib/http.js bearerOk) is the access boundary.
CREATE TABLE IF NOT EXISTS standby_status (
  box TEXT PRIMARY KEY,
  of_hub TEXT NOT NULL,
  snapshot TEXT,
  ok INTEGER NOT NULL,
  reported_at TEXT NOT NULL        -- ISO-8601 UTC
);
CREATE TABLE IF NOT EXISTS standby_verify_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  box TEXT NOT NULL,               -- the standby box that runs the drill
  of_hub TEXT NOT NULL,
  status TEXT NOT NULL,            -- requested|claimed|ok|fail
  requested_by TEXT,
  requested_at TEXT NOT NULL,
  claimed_at TEXT,
  finished_at TEXT,
  verdict_detail TEXT,
  sha256 TEXT,
  snapshot_ts TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS standby_verify_runs_open ON standby_verify_runs(box) WHERE status IN ('requested','claimed');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('standby_verify_claim_ttl_s','1800','BH-2519: seconds a claimed standby verify run may sit before it is re-offered','seed','2026-09-26T00:00:00Z');

-- ── Seed, #1510.4: bootstrap.smoke ────────────────────────────────────────────
-- The one-turn `claude -p` smoke test at the end of bin/bootstrap-machine.sh (its
-- `# >>> smoke model` block) reads this role instead of the literal it carried until
-- #1510.4. The value is that literal, so deploying this changes nothing. INSERT OR
-- IGNORE only: an operator's edit is never overwritten on a later deploy.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at) VALUES
  ('hub', NULL, 'bootstrap.smoke', 0, 'claude-haiku-4-5-20251001', 'claude', 'seed', '2026-09-24T00:00:00Z');

-- ── Seed, BH-2005.3: feature-map.draft ────────────────────────────────────────
-- The model bin/feature-map-draft.sh resolves through lane_model (FEATURE_MAP_MODEL
-- still wins). The value copies build.qa above: the session drives screens the way
-- a QA session does. INSERT OR IGNORE plus the BH-1572 tombstone guard, so an
-- operator's edit or removal is never undone by a later deploy.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT v.column1, v.column2, v.column3, v.column4, v.column5, v.column6, v.column7, v.column8
  FROM (VALUES ('hub', NULL, 'feature-map.draft', 0, 'claude-opus-5-5', 'claude', 'seed', '2026-09-24T00:00:00Z')) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column3);

-- ── Seed, BH-2545: review.trivial ─────────────────────────────────────────────
-- The reviewer bin/review-prs.sh uses for a diff under REVIEW_TRIVIAL_MAX_LINES
-- whose class is in REVIEW_TRIVIAL_ROUTE_CLASSES, when
-- lib.review-saving.review_trivial_mode is `route` (bin/lib/review-saving.sh
-- review_trivial_pick). The default mode (shadow) never asks for it. INSERT OR
-- IGNORE plus the BH-1572 tombstone guard, as feature-map.draft above.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT v.column1, v.column2, v.column3, v.column4, v.column5, v.column6, v.column7, v.column8
  FROM (VALUES ('hub', NULL, 'review.trivial', 0, 'claude-haiku-4-5-20251001', 'claude', 'seed', '2026-09-26T00:00:00Z')) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column3);

-- ── K3: THE PRE-CALL GUARD'S COUNTER (bin/agent-call.sh, bin/lib/call-guard.sh) ──
-- Every paid LLM call in the fleet goes through bin/agent-call.sh, and before it
-- spends anything it asks POST /api/call-guard/claim: how many paid calls has
-- this piece of work (project, stage, fingerprint) had inside the window? Under
-- the stage's ceiling the call is recorded here and runs. At the ceiling it is
-- refused, recorded as `refused`, and nothing is called and nothing is billed.
-- The fingerprint is the stable identity of the work: a PR and its head sha for
-- a review, a ticket and its board-state digest for a triage shard.
--
-- WHY A TABLE AND NOT A FILE. The 09-17..19 runaway (docs/HARNESS_SPEND_AND_
-- STATE_AUDIT_2026-09-19.html: 52 reviews of one head, triage shards re-run
-- 60-153 times) was a dedup key in a plain file on one box. A wiped, truncated
-- or rsynced-mid-write file re-buys everything. This row survives all of that,
-- and every box and fly builder sees the same count.
--
-- status: claimed (in flight, or the box died - COUNTS as paid) | ok | empty
-- (billed, nothing in it - COUNTS, terminal) | failed (billed failure - COUNTS)
-- | unbilled (no rung ran - does NOT count) | refused (not a call - does NOT
-- count, kept so the daily digest can name the fingerprint) | reset:<old> (an
-- operator's DELETE /api/call-guard - does NOT count) | reset (the audit row). The count and the
-- insert are ONE statement, so two boxes asking at the same instant cannot both
-- slip under the ceiling. No lock, no queue.
CREATE TABLE IF NOT EXISTS call_guard (
  call_id TEXT PRIMARY KEY,       -- minted by the caller, the idempotency key
  project TEXT NOT NULL,
  stage TEXT NOT NULL,            -- the GUARD stage (review, triage-shard, ...)
  fp TEXT NOT NULL,               -- the work's fingerprint. NEVER a secret.
  status TEXT NOT NULL,           -- see above
  box TEXT,                       -- the box that asked
  runner TEXT,                    -- the primary runner the call was about to use
  at TEXT NOT NULL,               -- claim time, the server's clock
  settled_at TEXT,                -- when the outcome landed
  note TEXT                       -- a reset's audit reason (status=reset)
);
CREATE INDEX IF NOT EXISTS idx_call_guard_key ON call_guard(project, stage, fp, at);
CREATE INDEX IF NOT EXISTS idx_call_guard_at ON call_guard(at);

-- BH-2329: main-red detail and audit.
-- Since BH-945 a red main already has a pause_flags row (main-red-<owner>-<repo>),
-- but that row holds only name/active/actor/reason. main_red holds the detail
-- that row does not (project, sha, workflow, job, run, since) and the last clear,
-- keyed by the same name. main_red_events holds one row per raise, new sha,
-- green or clear. PUT /api/main-red (the detector's mr_row) writes both, and
-- POST /api/main-red/clear writes the clear to both and turns the pause_flags
-- row off. bin/harness-sync.sh applies this file before wrangler deploy.
CREATE TABLE IF NOT EXISTS main_red (
  name TEXT PRIMARY KEY,        -- the pause_flags / flags/ name, e.g. main-red-example-org-cromford
  slug TEXT, project TEXT,      -- project from fleet.conf col 2 -> col 1; NULL when no project names the repo
  active INTEGER NOT NULL,      -- mirrors the detector's last publish
  sha TEXT, workflow TEXT, job TEXT, run_url TEXT, since TEXT, reason TEXT,
  cleared_sha TEXT, cleared_at TEXT, cleared_by TEXT, clear_reason TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS main_red_project ON main_red(project);
CREATE TABLE IF NOT EXISTS main_red_events (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL, action TEXT NOT NULL CHECK(action IN ('raise','new_sha','green','clear')),
  sha TEXT, actor TEXT NOT NULL, reason TEXT, at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS main_red_events_name ON main_red_events(name, id);

-- ── BH-2352 (BH-2319.0): fleet_cooldowns ──
-- WHY A TABLE. A 429 cooldown stays on the box that got refused, and lane-down
-- exists only on the hub, so every other box keeps hitting the refused account.
-- A row here is seen by every box and survives a dead box. It is a new table
-- and not rows in account_leases, because a row there would count toward the
-- capacity CAS.
-- Keys: kind is account (vendor = runner, subject = account), model (vendor =
-- claude, subject = the model or model/account) or lane (vendor = lane, subject
-- = box). The shell seam is bin/lib/fleet-cooldown.sh.
-- Contract only in this slice: nothing reads or writes it yet.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS fleet_cooldowns (
  kind TEXT NOT NULL,
  vendor TEXT NOT NULL,
  subject TEXT NOT NULL,
  until_at TEXT NOT NULL,
  since_at TEXT,
  reason TEXT,
  box TEXT,
  set_at TEXT NOT NULL,
  PRIMARY KEY (kind, vendor, subject)
);
CREATE INDEX IF NOT EXISTS idx_fleet_cooldowns_kind_until ON fleet_cooldowns(kind, until_at);

-- ── BH-2525: wake claims, cursors, cooldowns ──
-- WHY TABLES. bin/wake-loop.sh keeps its watermark in a settings row per box
-- (wake-cursor.<box>) and its per-(kind, project) cooldowns in files under
-- state/wake-cooldown on that box, so no other box can see either.
-- wake_claims is keyed per (wake, box), not per wake: a claim says THIS box has
-- taken the wake, and other boxes may take it for their own lanes.
-- wake_cursors is the per-box watermark. wake_cooldowns holds the last time a
-- (kind, project) ran anywhere in the fleet, last_at in INTEGER epoch seconds.
-- The client seam is bin/lib/jobs/queue.sh (wakes_claim, wake_cursor_get,
-- wake_cursor_put, wake_cooldown_take).
-- Contract only in this slice: nothing reads or writes these tables yet.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS wake_claims (
  wake_id INTEGER NOT NULL,
  box TEXT NOT NULL,
  claimed_at TEXT NOT NULL,
  PRIMARY KEY (wake_id, box)
);
CREATE INDEX IF NOT EXISTS idx_wake_claims_box_wake ON wake_claims(box, wake_id);
CREATE TABLE IF NOT EXISTS wake_cursors (
  box TEXT PRIMARY KEY,
  cursor INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS wake_cooldowns (
  kind TEXT NOT NULL,
  project TEXT NOT NULL,
  last_at INTEGER NOT NULL,
  box TEXT,
  PRIMARY KEY (kind, project)
);
-- Seed each box's cursor from its settings row wake-cursor.<box> (written by
-- bin/wake-loop.sh) so the first claim does not re-drain history. Digits only,
-- and OR IGNORE never moves a cursor that already exists.
INSERT OR IGNORE INTO wake_cursors(box, cursor, updated_at)
  SELECT substr(key, 13), CAST(value AS INTEGER), datetime('now')
  FROM settings WHERE key LIKE 'wake-cursor.%' AND value GLOB '[0-9]*' AND value NOT GLOB '*[^0-9]*';

-- ── BH-2523: fly_images ──
-- WHY A TABLE. The Fly builder image a project's pool dispatches from, what it
-- baked and when, lived only in the hub's state/fly/<p>.image, .bake and
-- .baked-at files. A fresh hub had none of them, so fleet-propagate read "never
-- baked" and bought a remote bake the fleet already had. One row per
-- (project, digest); `active` marks the one the pool dispatches from, and the
-- PUT flips it in one batch, so a project has at most one active row.
-- BH-2743: `state` says where a row is. The rollout writes its candidate
-- `baked` (inactive) and flips it active only after SMOKE passes; a failed
-- smoke records `smoke_failed` and the active row never moves. An activating
-- PUT sets `active` on its row and `demoted` on the one it replaces. Rows
-- written before the column read NULL. No index on it (BH-2473).
-- digest is the pushed ref (registry.fly.io/builder-<p>:deployment-XXXX), the
-- value state/fly/<p>.image holds. bake and cli are the manifests the build
-- recorded; baked_at is epoch seconds. The shell seam is bin/lib/fly-image-row.sh.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS fly_images (
  project TEXT NOT NULL,
  digest TEXT NOT NULL,
  app TEXT NOT NULL,
  bake TEXT,
  cli TEXT,
  baked_at INTEGER,
  active INTEGER NOT NULL DEFAULT 0,
  box TEXT,
  set_at TEXT NOT NULL,
  state TEXT,
  PRIMARY KEY (project, digest)
);
CREATE INDEX IF NOT EXISTS idx_fly_images_active ON fly_images(project, active);
-- ── BH-2531: product_proposals ──
-- WHY A TABLE. The product lane's proposal ledger is one file on the owning
-- box, state/product-<project>.ledger.json. Lose it (a rebuilt box, a restore
-- from an old backup) and the lane no longer knows which proposals it already
-- gated, vetoed or posted, so it can post the same [Proposal] ticket to the
-- client's board again. A row here outlives the box.
-- proposal_id is the run-product slug; record is the ledger entry as JSON text.
-- The client is bin/lib/proposal-rows.sh. No lane reads or writes this table
-- yet: the worker route and the lane wiring are sibling slices of BH-2531.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS product_proposals (
  project TEXT NOT NULL,
  proposal_id TEXT NOT NULL,   -- the run-product slug
  status TEXT NOT NULL,        -- candidate | gate_pending | posting | posted | vetoed | expired
  record TEXT NOT NULL,        -- the ledger entry, JSON object
  actor TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, proposal_id)
);

-- ── BH-2668 (BH-2530.0): fix_round_jobs ──
-- WHY A TABLE. blocked-resolver's fix round becomes a queued job that the
-- owning box claims, with no ssh from the hub. A row here is the durable job:
-- the hub enqueues it, the addressed box claims and finishes it, and the hub
-- adopts the result.
-- status is queued, claimed, done or adopted. fix_round_jobs_open allows one
-- un-adopted round per (project, cap_key), so the database refuses a second
-- paid round for the same park. Adopted rows leave that index and stay as
-- history. The shell seam is bin/lib/fix-round-queue.sh.
-- Contract only in this slice: nothing reads or writes it yet.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS fix_round_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  cap_key TEXT NOT NULL,
  box TEXT NOT NULL,
  args TEXT NOT NULL,
  record_in TEXT,
  hotfix INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 0,
  claimed_by TEXT,
  claimed_at TEXT,
  result TEXT,
  record_out TEXT,
  enqueued_at TEXT NOT NULL,
  finished_at TEXT,
  adopted_at TEXT,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS fix_round_jobs_open ON fix_round_jobs(project, cap_key) WHERE status IN ('queued','claimed','done');
CREATE INDEX IF NOT EXISTS fix_round_jobs_box ON fix_round_jobs(box, status);

-- ── REGISTRY SEED RUNS (BH-2521.2) ──────────────────────────────────────────
-- One row per console apply of the registry seed that got past the fleet gate
-- and the plan fingerprint (POST /api/settings/seed-registry/apply). `settings`
-- has no history, so this is the only record of who applied which plan and
-- what it wrote. 'started' is written before the seed and 'applied' only after
-- it returned, so a worker that died mid-seed leaves 'started', never
-- 'applied'. `changed` stays NULL on a failed run: it did not measure zero.
-- The CLI `harness-ctl seed-registry` POST does not write here.
CREATE TABLE IF NOT EXISTS registry_seed_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor TEXT NOT NULL,            -- the human the coord proxy stamped
  plan_fp TEXT NOT NULL,          -- planFingerprint of the plan they looked at
  status TEXT NOT NULL CHECK (status IN ('started','applied','failed')),
  rows INTEGER,
  changed INTEGER,
  pruned INTEGER,
  changed_keys TEXT,              -- JSON array
  pruned_keys TEXT,               -- JSON array
  error TEXT,
  started_at TEXT NOT NULL,
  finished_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_registry_seed_runs_started ON registry_seed_runs(started_at);

-- BH-2543: GET /api/preplans/adoption reads stage='preplan' rows by time window.
CREATE INDEX IF NOT EXISTS idx_events_stage_created ON stage_events(stage, created_at);

-- ── BH-2518: box_commands ──
-- One row is one operator request for a box or machine op (backup now, stop or
-- destroy a Fly machine, harness-sync, CLI update). The console POSTs it
-- through the coord proxy, the addressed box's lane claims it, and the lane
-- records ok or fail with a detail line. box_commands_open allows one open
-- (requested or claimed) command per (box, type, target), so the database
-- refuses a second click on the same target. Finished rows leave that index and
-- stay as history. target is '' for the non-Fly types.
-- The claim TTL is settings.box_commands_claim_ttl_s, read by the worker
-- sibling with a code fallback of 1800 s; there is no seed row.
-- Contract only in this slice: nothing reads or writes it yet.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS box_commands (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  box TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('backup_now','fly_machine_stop','fly_machine_destroy','harness_sync','cli_update')),
  target TEXT NOT NULL DEFAULT '',
  args TEXT,
  reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
  status TEXT NOT NULL CHECK (status IN ('requested','claimed','ok','fail')),
  requested_by TEXT,
  requested_at TEXT NOT NULL,
  claimed_by TEXT,
  claimed_at TEXT,
  finished_at TEXT,
  detail TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS box_commands_open ON box_commands(box, type, target) WHERE status IN ('requested','claimed');
CREATE INDEX IF NOT EXISTS box_commands_box_status ON box_commands(box, status, id);

-- ── BH-2653 (BH-2528.0): box_console_commands ──
-- WHY A TABLE. A console command the hub forwards to a box becomes a row the
-- addressed box claims, runs and answers, so the console needs no ssh to reach
-- a box. command_id is the natural key: a forward that repeats it is the same
-- command, not a second one.
-- status is queued, claimed, done or expired. payload is the console payload
-- as JSON text, stored as sent. ok is 1 or 0 once the box answers, result is
-- its one-line outcome and body its full output.
-- Not #2518's box_commands table: a different queue with its own routes.
-- The shell seam is bin/lib/jobs/box-console-commands.sh. Contract only in
-- this slice: nothing reads or writes it yet.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS box_console_commands (
  command_id TEXT PRIMARY KEY,
  box TEXT NOT NULL,
  type TEXT NOT NULL,
  project TEXT,
  payload TEXT NOT NULL,       -- JSON text, byte-for-byte as forwarded
  status TEXT NOT NULL,        -- queued | claimed | done | expired
  ok INTEGER,                  -- 1 or 0 once answered
  result TEXT,
  body TEXT,
  claimed_at TEXT,
  finished_at TEXT,
  actor TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_box_console_commands_box ON box_console_commands(box, status, created_at);

-- Its knobs, one seed per statement (see gh_quota_alert_pct above). The key
-- shape is lane_env_apply's lane.<lane-id>.<lowercased env name>.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.box-console-commands.box_console_commands_ttl_s','300','BH-2528: seconds a forwarded console command may wait unclaimed or claimed before it expires','seed','2026-09-26T00:00:00Z');

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.box-console-commands.box_console_commands_claim_limit','10','BH-2528: most console commands one box claims per cycle','seed','2026-09-26T00:00:00Z');

-- ── BH-2568 (BH-2544.0): alert family scripts ──
-- One row per alert family the triage lane can settle without a model: a match
-- (akey prefix or line regex) and an optional read-only verify script under
-- bin/alert-verify/. Contract only in this slice: nothing reads the table and no
-- rows are seeded here (a BH-2544 sibling owns both). The protocol the rows
-- drive is the header of bin/triage-family-scripts.sh.
CREATE TABLE IF NOT EXISTS alert_family_scripts (
  id TEXT PRIMARY KEY,                 -- ^[a-z0-9-]{1,48}$
  match_kind TEXT NOT NULL CHECK (match_kind IN ('akey_prefix','line_regex')),
  match TEXT NOT NULL,
  verify TEXT,                         -- basename under bin/alert-verify/, NULL = no verify
  on_clear TEXT NOT NULL DEFAULT 'settle' CHECK (on_clear IN ('settle','model')),
  on_repro TEXT NOT NULL DEFAULT 'model' CHECK (on_repro IN ('model','park')),
  enabled INTEGER NOT NULL DEFAULT 1,
  priority INTEGER NOT NULL DEFAULT 100,
  note TEXT, actor TEXT, updated_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_alert_family_scripts_enabled_priority ON alert_family_scripts(enabled, priority);
-- The TRIAGE_RUNNERS knob's row, seeded by the runner-allowlist sibling that
-- reads it (BH-2570, bin/alert-triage.sh). OR IGNORE: harness-sync re-applies
-- this file on every deploy, and an operator's edit must survive it.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.alert-triage.triage_runners','claude,fireworks','BH-2570: alert-triage runs only on these runners; grok is off because the context meter cannot see grok requests (docs/verification-map/responder-cliff-cap.md)','seed','2026-09-28T00:00:00Z');
-- ── BH-2577 (BH-2544.4): the ten seed families ──
-- One row per family, each with its read-only verify script at
-- bin/alert-verify/<verify>.sh. akey_prefix only where the beat is written with
-- that akey directly; everything bin/lane-alert.sh re-keys to orclane:<ID> is
-- matched on its line. Operator edits survive a re-apply (INSERT OR IGNORE).
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('mc-state-note','line_regex','conductor: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+ [A-Z_]+ ','mc-state-note','settle','model',1,10,'merge-conductor page on a PR; cleared when gh-pr-state reads MERGED or CLOSED','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('pipeline-health-clean-open','akey_prefix','health:sweepstall:','pipeline-health-clean-open','settle','model',1,20,'pipeline-health OPEN and CLEAN but not swept; cleared when the PR is not OPEN','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('merge-queue-pr','line_regex','Merge queue: #[0-9]+ ','merge-queue-pr','settle','model',1,30,'merge-queue page on a PR; cleared when the PR is not OPEN','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('main-red','line_regex','\[orchestrator/main-red\] [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+ main is (STILL )?RED','main-red','settle','model',1,40,'main is RED; cleared when every check-run on main completed and none failed (REST)','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('ghdefault-visibility','line_regex','DEFAULT GH TOKEN CANNOT SEE [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+ ','ghdefault-visibility','settle','model',1,50,'default token cannot see a repo; cleared when its GET repos/<slug> answers 200','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('hb-db-silent','line_regex','[A-Za-z0-9_.-]+ on [A-Za-z0-9_.-]+ is (silent|overdue): its last beat was [0-9]+m ago','hb-db-silent','settle','model',1,60,'heartbeat-reaper DB page (was hb-stale); cleared when lane-procs reads fresh or ended','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('lane-silent','line_regex','\[jobs-watchdog\] LANE SILENT: [A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+ ','lane-silent','settle','model',1,70,'jobs-watchdog lane staleness; cleared when the worker reads the lane live','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('deferral-backlog','line_regex','\[alert-triage\] DEFERRAL BACKLOG: [0-9]+ lines spooled','deferral-backlog','settle','model',1,80,'alert-triage spool depth between ticks, cleared when it is not over TRIAGE_SPOOL_ALERT, doubt while a tick holds the lane lock','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('fleet-propagate-partial','line_regex','\[orchestrator/fleet-propagate\] propagating [0-9a-f]{7,} to the fleet FAILED in part','fleet-propagate-partial','settle','model',1,90,'partial fleet propagate; cleared when the last run for the sha in the last 20 KB of its log is clean','seed-bh-2544','2026-09-27T00:00:00Z');
INSERT OR IGNORE INTO alert_family_scripts (id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at) VALUES
  ('pr-url-reconcile-verdict','akey_prefix','prurlreconcile:verdict:','pr-url-reconcile-verdict','settle','model',1,100,'PR owes a verdict; cleared when it is closed or has a standing verdict for its head','seed-bh-2544','2026-09-27T00:00:00Z');
-- Project triage off grok (BH-3224): the run-triage lane's RUNNER_TRIAGE row.
-- A lane.<id>.<env> row outranks the box env (lane_env_apply run-triage in
-- bin/run-triage.sh), so the hub's RUNNER_TRIAGE=grok stops choosing the runner
-- for project triage and its shards. OR IGNORE: an operator's edit survives
-- every re-apply. The stage.triage route row is NOT flipped here: this file is
-- additive only (tests/schema-additive.bh-1000-test.sh), so that is an
-- operator PUT on the console Model routes page.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.run-triage.runner_triage','claude','BH-3224: project triage runs claude; grok failed instantly (rc=1, no usage) on every hub triage call. The row outranks a box env RUNNER_TRIAGE.','seed','2026-09-28T00:00:00Z');

-- ── BH-3387 ──
-- deploy.<project>.kind = github-deployment | none | smoke-only, read by
-- bin/lib/deploy-kind.sh before bin/deploy-verify.sh polls any deployments.
-- cromford reaches its boxes through harness-sync/update-runners and has
-- no GitHub Production deployment, so every merge paged deployfail. OR IGNORE:
-- an operator's edit survives every re-apply. No row = today's poll.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('deploy.cromford.kind','none','BH-3387: cromford reaches boxes via harness-sync/update-runners, never a GitHub Production deployment; deploy-verify skips it','seed','2026-09-29T00:00:00Z');

-- ── P4: PLAN-DRIVEN MODEL ROUTING, SHADOW MODE (2026-09-25) ──────────────────
-- Every build stage runs on the same model today (model_routes build.* = Opus
-- 5.5), whatever the plan says the work is. P4 writes down, as ROWS, the rules
-- that would pick the execute model from the plan's own structure — risk
-- surface, invariants, size, how fully it is specified — and records, per
-- build, what those rules WOULD have picked beside what the build actually ran
-- on. Nothing reads a rule to choose a model: `mode` has no 'live' value, and
-- PUT /api/route-rules refuses one (worker/jobs/src/routes/route-rules.js).
-- The decision to route live is a later ticket, made on this table's evidence.
-- Doc: docs/ROUTE-RULES.md.
--
-- A rule names a model_routes ROLE (`execute_role`), never a model id, so the
-- model a rule would buy is whatever that role's ladder says on the day — the
-- same DB-first path every live lane reads (bin/lib/model-route.sh).
-- The REVIEWER is not a column: the would-be review model is always the
-- build.review role's model, so no rule can move review to a cheaper model.
-- A rule may only RAISE the review tier above what the classifier gives the
-- planned files (bin/lib/review-tier.sh), never lower it.
--
-- Same D1 / bearer note as model_routes: no RLS step (see that block).
CREATE TABLE IF NOT EXISTS route_rules (
  name TEXT PRIMARY KEY,           -- stable key, ^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$
  priority INTEGER NOT NULL,       -- ascending: the FIRST matching 'route' rule wins
  effect TEXT NOT NULL,            -- 'route' (picks the unit's routing) | 'bump' (raises it after)
  mode TEXT NOT NULL,              -- 'shadow' (evaluated, logged) | 'off' (skipped). No 'live' in P4.
  match_json TEXT NOT NULL,        -- the conditions, a JSON object (docs/ROUTE-RULES.md, "match")
  execute_role TEXT,               -- a model_routes role: the execute model this rule would buy
  review_tier TEXT,                -- T0 | T1 | T2: the review-tier FLOOR (never below the classifier)
  test_scope TEXT,                 -- minimal | impact | full
  tier_bump INTEGER NOT NULL DEFAULT 0, -- 'bump' only: review tiers to raise
  note TEXT,
  version INTEGER NOT NULL DEFAULT 1,   -- moves on every write; PUT's expected_version guards it
  updated_by TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_route_rules_priority ON route_rules(priority);

-- APPEND-ONLY, one row per decision (a PUT that changed the row). before_json is
-- NULL when the PUT created the rule; after_json is the row as written.
CREATE TABLE IF NOT EXISTS route_rule_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  before_json TEXT,
  after_json TEXT,
  actor TEXT NOT NULL,
  reason TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_route_rule_changes_name ON route_rule_changes(name, at);

-- One row per BUILD (the build dir's basename is the key, so a resumed build
-- dir records once). would_* is what the rules picked; actual_execute_model is
-- what EXECUTE ran on. `differs` is computed by the worker, never sent.
CREATE TABLE IF NOT EXISTS route_shadow (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  build TEXT NOT NULL,
  job_id TEXT,
  project TEXT NOT NULL,
  ticket_key TEXT,
  rule TEXT,                       -- the matched 'route' rule, '' when none matched
  bumped TEXT,                     -- the 'bump' rules applied, comma list
  would_execute_role TEXT,
  would_execute_model TEXT,
  actual_execute_model TEXT,
  would_review_tier TEXT,
  planned_review_tier TEXT,        -- bin/lib/review-tier.sh over planned-files.txt
  review_model TEXT,               -- build.review's model: the reviewer never downshifts
  would_test_scope TEXT,
  differs INTEGER NOT NULL DEFAULT 0,
  features_json TEXT,              -- the plan features the resolver read. NEVER a secret.
  box TEXT,
  at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_route_shadow_build ON route_shadow(build);
CREATE INDEX IF NOT EXISTS idx_route_shadow_at ON route_shadow(at, project);
CREATE INDEX IF NOT EXISTS idx_route_shadow_job ON route_shadow(job_id);

-- Seed: the four rules of the approved design, all mode 'shadow'. INSERT OR
-- IGNORE plus the BH-1572 tombstone guard: a rule with ANY audit row has been
-- decided by an operator and is never re-seeded by a later deploy.
--   risk-surface     unit 0 / invariant-bearing / schema-auth-money-webhook-
--                    migration files -> the live execute role, T2, full suite
--   docs-tests-copy  tests/docs/copy only -> the lite execute role, T0 floor
--   specified-small  fully specified, no risk surface, <= 150 product lines ->
--                    the lite execute role, T1 floor, impact-selected suites
--   bounce-escalate  the project's (or the unit class's) first-review BLOCK
--                    share over 30 days above 0.30 on >= 5 reviews -> back to
--                    the live execute role and one review tier up
INSERT OR IGNORE INTO route_rules (name, priority, effect, mode, match_json, execute_role, review_tier, test_scope, tier_bump, note, version, updated_by, updated_at)
  SELECT v.column1, v.column2, v.column3, v.column4, v.column5, v.column6, v.column7, v.column8, v.column9, v.column10, 1, 'seed', '2026-09-25T00:00:00Z'
  FROM (VALUES
    ('risk-surface', 10, 'route', 'shadow', '{"any":["u0","invariant_bearing","risk_surface"]}', 'build.execute', 'T2', 'full', 0,
     'P4: unit 0, invariant-bearing or risk-surface work stays on the frontier execute model with the deepest review'),
    ('docs-tests-copy', 20, 'route', 'shadow', '{"all":["docs_only"],"none":["u0","invariant_bearing","risk_surface"]}', 'build.execute.lite', 'T0', 'minimal', 0,
     'P4: tests/docs/copy-only work'),
    ('specified-small', 30, 'route', 'shadow', '{"all":["fully_specified"],"none":["u0","invariant_bearing","risk_surface"],"max_lines":150}', 'build.execute.lite', 'T1', 'impact', 0,
     'P4: a fully specified plan with no risk surface, 150 product lines or fewer'),
    ('bounce-escalate', 100, 'bump', 'shadow', '{"bounce_rate_gt":0.3,"min_reviews":5,"days":30}', 'build.execute', NULL, NULL, 1,
     'P4: escalation on measured failure — a project or unit class whose first reviews block too often goes back up a tier')
  ) AS v
  WHERE NOT EXISTS (SELECT 1 FROM route_rule_changes c WHERE c.name = v.column1);

-- The lite execute role the two cheap rules name. A brand-new model_routes
-- role (bin/model-route-seed-lint.sh passes it: it has no history), read by
-- NOTHING live — bin/lib/route-rules.sh resolves it only to write a shadow row.
-- The value copies triage.light above. Tombstone-guarded like every seed here.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT v.column1, v.column2, v.column3, v.column4, v.column5, v.column6, v.column7, v.column8
  FROM (VALUES ('hub', NULL, 'build.execute.lite', 0, 'claude-sonnet-5', 'claude', 'seed', '2026-09-25T00:00:00Z')) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column3);

-- ── TRIAGE-STATE (the operator, 2026-09-28): triage_state ──────────────────────────
-- One row per ticket: what the triage model last decided about it, and the
-- INPUT HASH that verdict was made against. Before a tick spends a token, the
-- pre-check (bin/lib/triage-state.sh) hashes each open ticket's inputs again —
-- the thread minus our own comments, its labels minus ours, the state of every
-- ticket and PR it depends on — and a ticket whose hash still equals
-- verdict_hash, with its recheck not yet due, is not sent to the model. A
-- `buildable` verdict that is unchanged and has no build or PR is handed to the
-- launch path directly. Doc: docs/TRIAGE-STATE.md. Plan:
-- .harness/specs/TRIAGE-STATE/plan.md.
--
-- ticket_key is the tick's canonical unit key (triage_shard_canon): the issue
-- NUMBER on a GitHub-Issues board, the board ticket id in-app. ticket_label is
-- the human key (BH-2657, TK-12). A PUT writes only the columns it carries, so
-- the pre-check's observe write (input_hash, last_decision) never erases a
-- verdict. verdict is one of buildable | needs_clarification | waiting_client |
-- queued | hold | closed | blocked | triaged (checked by the route, not here, so
-- the vocabulary can grow without a table rebuild). Timestamps are ISO-8601 UTC.
--
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS triage_state (
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  ticket_label TEXT,
  input_hash TEXT,              -- the last pre-check's hash of this ticket's inputs
  verdict TEXT,                 -- the model's last verdict (vocabulary above)
  waiting_on TEXT,              -- client | team | none
  verdict_hash TEXT,            -- the input_hash that verdict was made against
  triaged_at TEXT,              -- when that verdict was written
  next_recheck_at TEXT,         -- triaged_at + the TTL row; due = back to the model
  reason TEXT,                  -- the DECISION line (or seed) the verdict came from
  last_decision TEXT,           -- the pre-check's last answer: llm <why> | skip <why> | enqueue
  last_decision_at TEXT,
  last_mode TEXT,               -- off | shadow | enforce, the mode that answer ran under
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key)
);
CREATE INDEX IF NOT EXISTS idx_triage_state_recheck ON triage_state(project, next_recheck_at);

-- ── BH-1793.0 (BH-1805) ──
-- The split-watchdog's per-(project, child, step, reason) action ledger. It is
-- the dedupe behind "one provable step per family per tick": a repeat bumps
-- repeats and last_at instead of acting twice. bin/harness-sync.sh applies it.
CREATE TABLE IF NOT EXISTS split_watchdog_actions (
  project TEXT NOT NULL,
  family TEXT NOT NULL,
  child TEXT NOT NULL,
  step TEXT NOT NULL,
  reason_fp TEXT NOT NULL,
  reason TEXT,
  outcome TEXT,
  repeats INTEGER NOT NULL DEFAULT 1,
  first_at TEXT NOT NULL,
  last_at TEXT NOT NULL,
  actor TEXT,
  PRIMARY KEY (project, child, step, reason_fp)
);
CREATE INDEX IF NOT EXISTS idx_split_watchdog_family ON split_watchdog_actions(project, family, last_at);
CREATE INDEX IF NOT EXISTS idx_split_watchdog_last ON split_watchdog_actions(last_at);

-- ── BH-1795.2 (BH-3327): the lookback lane's clustering model ────────────────
-- Two brand-new roles, tombstone-guarded like every seed above, and NO new
-- model literal (tests/alert-triage-runners R6): each copies rung 0 of an
-- existing hub route, so the Models page is where the model is chosen.
-- lookback.cluster: bin/lookback.sh LOOKBACK_MODEL. Copied from rule.miner, the
-- other weekly analysis session, and pinned to its claude rung.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'lookback.cluster', 0, m.model, m.runner, 'seed', '2026-09-28T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'rule.miner' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'lookback.cluster')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'lookback.cluster');
-- stage.lookback: the BH-2536 rule (every agent-call stage has a rung-0 stage
-- route), reused from stage.execute rung 0 exactly as the BH-2536 block is.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.lookback', 0, m.model, m.runner, 'seed', '2026-09-28T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.lookback')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.lookback');

-- ── BH-3422.0 (BH-3425): the model-watch table ───────────────────────────────
-- One row per vendor model the daily model-watch lane has seen, keyed by the
-- normalized id (bin/lib/model-watch.sh mw_norm_id). Filled by the #3422
-- siblings through /api/model-watch; CREATED_TABLES.model_watch is the same DDL
-- for a D1 this apply never reached.
CREATE TABLE IF NOT EXISTS model_watch (
  vendor TEXT NOT NULL,
  model_id TEXT NOT NULL,
  slug TEXT,
  source TEXT NOT NULL,
  source_url TEXT,
  released_at TEXT,
  prompt REAL,
  completion REAL,
  cache_read REAL,
  cache_write REAL,
  context_window INTEGER,
  status TEXT NOT NULL DEFAULT 'new' CHECK(status IN ('new','suggested','adopted','ignored')),
  suggestion TEXT,
  probe TEXT,
  probe_attempted_at TEXT,
  announced_at TEXT,
  first_seen TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  actor TEXT,
  reason TEXT,
  PRIMARY KEY (vendor, model_id)
);
CREATE INDEX IF NOT EXISTS idx_model_watch_status ON model_watch(status, first_seen);

-- ── BH-3481.2 (BH-3499): live cost rows ────────────────────────────────────
-- One row per running claude session, keyed (box, row_hash) where row_hash is
-- sha256("live|<box>|<session_id>"). The session's meter POSTs its running
-- total to /api/cost/live while it runs, and the row only ever goes up. When
-- the session's final cost_rows row lands (same session_id) the live row is
-- settled and stops counting as in-flight spend. updated_at is the worker's
-- clock, never the box's, so staleness is judged on one clock. Rows older than
-- 14 days are pruned by the POST itself.
CREATE TABLE IF NOT EXISTS cost_rows_live (
  box TEXT NOT NULL,
  row_hash TEXT NOT NULL,
  session_id TEXT NOT NULL,
  run_id TEXT,
  ticket TEXT,
  project TEXT,
  stage TEXT,
  model TEXT,
  input_toks INTEGER,
  output_toks INTEGER,
  cache_read INTEGER,
  cache_write INTEGER,
  cost_usd REAL,
  unpriced TEXT,
  started_at TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (box, row_hash)
);
CREATE INDEX IF NOT EXISTS cost_rows_live_run ON cost_rows_live(run_id);
CREATE INDEX IF NOT EXISTS cost_rows_live_upd ON cost_rows_live(updated_at);
-- Serves the settled test in GET /api/cost/live. session_id is on the live
-- cost_rows already (ensureColumns, since 2026-09-14), so this applies there.
CREATE INDEX IF NOT EXISTS cost_rows_session ON cost_rows(session_id);
-- ── BH-3478.1 (BH-3493): child context packs ─────────────────────────────────
-- One row per split child: the map of the code its parent's plan already paid
-- to read, published by bin/lib/context-pack.sh cp_put and read back by cp_fetch
-- when the child plans. Written only through POST /api/context-packs, which
-- refuses a pack over 64000 bytes rather than storing a slice of it.
-- CREATED_TABLES.context_packs is the same DDL for a D1 this apply never reached.
-- The primary key covers the only read, so there is no extra index.
CREATE TABLE IF NOT EXISTS context_packs (
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  parent_key TEXT NOT NULL,
  base_sha TEXT,
  pack_md TEXT NOT NULL,
  bytes INTEGER,
  box TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key)
);
-- stage.plan.child: the route a warm-started child plans on. Copied from the
-- plan rung 0 with no new model literal and tombstone-guarded like the BH-3327
-- block above, so an operator who removed the role is never overruled by a
-- re-apply. Absent, the resolver falls back to the plan role.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.plan.child', 0, m.model, m.runner, 'seed', '2026-09-29T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'plan' AND m.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.plan.child')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.plan.child');
-- >>> replan seed (BH-3955)
-- replan: the one cheap call bin/replan-check.sh makes for a split child whose
-- blockers have merged (keep / amend / escalate). A copy of triage.light rung 0,
-- no new model literal, tombstone-guarded like stage.plan.child above.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'replan', 0, m.model, m.runner, 'seed', '2026-10-03T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'triage.light' AND m.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'replan')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'replan');
-- stage.replan: the runner route agent-call reads for the `replan` stage, one
-- claude rung like the BH-2536 stage seeds (tests/stage-route-seed.bh-2536-test.sh).
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.replan', 0, m.model, 'claude', 'seed', '2026-10-03T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'triage.light' AND m.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.replan')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.replan');
-- <<< replan seed (BH-3955)
-- The two child-plan knobs, one seed per statement (see the settings seeds
-- above). Their readers keep the same numbers as code fallbacks.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('child_plan_tripwire_pct','50','BH-3478: a split child''s plan that re-reads more than this percent of its parent''s planning tokens logs CHILD_PLAN_TRIPWIRE FIRE','seed','2026-09-29T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('child_preplan_delta_tokens','150000','BH-3478: planning-token budget a warm-started split child is expected to stay under','seed','2026-09-29T00:00:00Z');
-- BH-3685: the main-red-bisect lane's two budget knobs, one seed per statement.
-- The lane keeps the same numbers as its ${VAR:-default} fallbacks.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.main-red-bisect.main_red_bisect_max_steps','8','BH-3685: probes per red episode, P0 and P1 included','seed','2026-09-30T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.main-red-bisect.main_red_bisect_max_merges','40','BH-3685: the most merges between green and red the lane will bisect','seed','2026-09-30T00:00:00Z');

-- ── BH-3703 (BH-3688): the daily digest's seeds ─────────────────────────────
-- The UTC hour the daily Telegram digest is sent, a lane knob the BH-3688 lane
-- slice registers as lane.daily-digest.daily_digest_send_hour_utc. One seed
-- per statement (bin/harness-sync.sh applies statement by statement).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.daily-digest.daily_digest_send_hour_utc','7','BH-3688: UTC hour the daily Telegram digest is sent','seed','2026-09-30T00:00:00Z');
-- stage.daily-digest: the digest's summary stage route (BH-2536: every
-- agent-call stage has a rung-0 stage route), copied from stage.execute rung 0
-- on the claude runner exactly as stage.lookback is, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.daily-digest', 0, m.model, m.runner, 'seed', '2026-09-30T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.daily-digest')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.daily-digest');

-- ── BH-3434 (BH-3448): the hub-probe request ledger ───────────────────────────
-- One row per probe a ticket asked the hub to run, keyed by (project,
-- ticket_key, probe, args_hash). args_hash is the sha256 of the canonical args
-- JSON and the worker is the only thing that computes it. A key is requested
-- once ever, so a finished row is never run again. status moves pending to
-- claimed (POST /api/hub-probe/claim), then claimed to pass or fail or rejected,
-- or back to pending with a note (POST /api/hub-probe/result). Routes live in
-- worker/jobs/src/routes/hub-probe.js and hub-probe-count.js.
CREATE TABLE IF NOT EXISTS hub_probe_requests (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  probe TEXT NOT NULL,
  args_json TEXT NOT NULL,
  args_hash TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','claimed','pass','fail','rejected')),
  requested_by TEXT,
  requested_at TEXT NOT NULL,
  claimed_by TEXT,
  claimed_at TEXT,
  finished_at TEXT,
  http_status INTEGER,
  output TEXT,
  commented_at TEXT,
  note TEXT,
  UNIQUE(project, ticket_key, probe, args_hash)
);
CREATE INDEX IF NOT EXISTS idx_hub_probe_status ON hub_probe_requests(status, requested_at);

-- ── BH-3719.0 (BH-3726): the dequeue-watch classifier model ─────────────────
-- Two brand-new roles, tombstone-guarded like every seed above, and NO model
-- literal: each copies rung 0 of an existing hub route, so the Models page is
-- where the model is chosen. Nothing calls either role until a later BH-3719
-- slice ships the classifier.
-- dequeue.classify: copied from lookback.cluster rung 0, pinned to its claude rung.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'dequeue.classify', 0, m.model, m.runner, 'seed', '2026-09-30T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'lookback.cluster' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'dequeue.classify')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'dequeue.classify');
-- stage.dequeue-classify: the BH-2536 rule (every agent-call stage has a rung-0
-- stage route), reused from stage.execute rung 0 exactly as stage.lookback is.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.dequeue-classify', 0, m.model, m.runner, 'seed', '2026-09-30T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.dequeue-classify')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.dequeue-classify');

-- ── BH-3719.1 (BH-3727): the dequeue-watch ledger ────────────────────────────
-- dequeue_events is the detection ledger, one row per (repo, pr, head, run_id);
-- dequeue_actions is the once-per-(pr, head, class) claim the lane takes before
-- it acts. repo and head are lowercased by the route before every write and
-- lookup (D17). The class/action/status words are the ones the contract
-- (bin/lib/jobs/dequeue-watch.sh) fixed. CREATED_TABLES in src/lib/core.js
-- carries the same statements for ensureTable; the BH-3727 test pins the parity.
CREATE TABLE IF NOT EXISTS dequeue_events (
  repo TEXT NOT NULL,
  pr INTEGER NOT NULL,
  head TEXT NOT NULL,
  run_id TEXT NOT NULL,
  project TEXT NOT NULL,
  dequeued_at TEXT,
  run_url TEXT,
  comment_id TEXT,
  batch_size INTEGER,
  members TEXT,
  draft INTEGER,
  attribution TEXT,
  attribution_how TEXT,
  class TEXT CHECK (class IS NULL OR class IN ('rule-break','scanner-fp','semantic-test','textual-conflict','bystander','stale-status','flake','main-red','unclassified')),
  class_how TEXT,
  rule_id TEXT,
  suites TEXT,
  fail_lines TEXT,
  llm_fp TEXT,
  llm_attempted_at TEXT,
  llm_class TEXT CHECK (llm_class IS NULL OR llm_class IN ('rule-break','scanner-fp','semantic-test','textual-conflict','bystander','stale-status','flake','main-red','unclassified')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, pr, head, run_id)
);
CREATE INDEX IF NOT EXISTS idx_dequeue_events_llm_fp ON dequeue_events(llm_fp);
CREATE INDEX IF NOT EXISTS idx_dequeue_events_created ON dequeue_events(created_at);
CREATE TABLE IF NOT EXISTS dequeue_actions (
  repo TEXT NOT NULL,
  pr INTEGER NOT NULL,
  head TEXT NOT NULL,
  class TEXT NOT NULL CHECK (class IN ('rule-break','scanner-fp','semantic-test','textual-conflict','bystander','stale-status','flake','main-red','unclassified')),
  action TEXT NOT NULL CHECK (action IN ('requeue','lead-request','fix-round','main-red-wait','hold','observe')),
  status TEXT NOT NULL DEFAULT 'claimed' CHECK (status IN ('claimed','done','failed','waiting')),
  project TEXT NOT NULL,
  ref TEXT,
  note TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, pr, head, class)
);
CREATE INDEX IF NOT EXISTS idx_dequeue_actions_repo_pr_class ON dequeue_actions(repo, pr, class);
CREATE INDEX IF NOT EXISTS idx_dequeue_actions_status_created ON dequeue_actions(status, created_at);
-- BH-3859: dequeue-watch ships in observe mode. OR IGNORE: on first
-- registration only, an operator's row is never overwritten. The registry
-- default and bin/lib/dequeue-watch/act.sh's fallback are 0 as well.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.dequeue-watch.dequeue_watch_act','0','BH-3859: dequeue-watch ships in observe mode; flip with bin/harness-ctl.sh set dequeue-watch DEQUEUE_WATCH_ACT 1','seed','2026-10-03T00:00:00Z');

-- ── BH-3790 (BH-3781.1): the stuck-work lane's SLA seeds ───────────────────
-- One per SLA knob in catalog/lanes.d/stuck-work.json, minutes (the build
-- stages are stage=minutes pairs). bin/lib/stuck-work/classify.sh keeps the
-- same values as its ${VAR:-default} fallbacks. One seed per statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.stuck-work.stuck_work_sla_lead_review_min','60','BH-3781: minutes a PR with no merge verdict on its head waits on the lead before it pages','seed','2026-10-01T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.stuck-work.stuck_work_sla_ready_min','15','BH-3781: minutes a ready PR waits on the conductor before it pages','seed','2026-10-01T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.stuck-work.stuck_work_sla_queued_min','90','BH-3781: minutes a PR may sit in the Mergify queue before it pages','seed','2026-10-01T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.stuck-work.stuck_work_sla_dequeued_min','30','BH-3781: minutes a dequeued PR waits on dequeue-watch before it pages','seed','2026-10-01T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.stuck-work.stuck_work_sla_blocked_min','60','BH-3781: minutes a BLOCKed PR waits on a fix round before it pages','seed','2026-10-01T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.stuck-work.stuck_work_sla_human_min','1440','BH-3781: minutes a PR waiting on a human counts as overdue in the digest (it never pages)','seed','2026-10-01T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.stuck-work.stuck_work_sla_unlaunched_min','60','BH-3781: minutes an ai-build ticket nothing launched waits before it pages','seed','2026-10-01T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.stuck-work.stuck_work_sla_build_stages','plan=45,execute=120,review=45,fix=60,default=90','BH-3781: minutes per build stage before a building ticket pages','seed','2026-10-01T00:00:00Z');

-- ── BH-4008 (BH-3988 tracer): hourly utilization snapshots ──────────────────
-- One row per (project, hour): is the fleet actually using the capacity it
-- has? verdict is one of starved|paused|blocked|saturated|busy|unknown and
-- payload a JSON object of sections (builds today; the BH-3988 siblings add
-- tickets, pauses and PRs). The writer is bin/utilization-push.sh (hub, :07
-- hourly) through utilization_put in bin/lib/jobs/utilization.sh. Readers:
-- GET /api/utilization (worker/jobs/src/routes/utilization.js), plus the
-- sibling history, went-quiet alert and console readers to come. The PUT prunes
-- the putting project's rows older than its retention (default 35 days), so
-- the table is bounded without a sweep.
-- Applied by bin/harness-sync.sh statement by statement before the deploy.
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS utilization_snapshots (project TEXT NOT NULL, hour TEXT NOT NULL, verdict TEXT NOT NULL, payload TEXT NOT NULL, box TEXT, as_of TEXT NOT NULL, PRIMARY KEY (project, hour));
CREATE INDEX IF NOT EXISTS idx_util_hour ON utilization_snapshots(hour);
-- ── BH-4062 (BH-3966.1): Archie's initiative register ──────────────────────
-- One row per initiative Archie watches: a goal, the metric that measures it,
-- how often to look (cadence_hours) and when to speak (escalation_rule). The
-- slug is the identity key, normalised once in src/routes/initiatives.js.
-- last_value moves only when a check slot CLOSES (advances next_check_at), so a
-- retried slot still compares against the previous closed value.
CREATE TABLE IF NOT EXISTS initiatives (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT NOT NULL UNIQUE,
  goal TEXT NOT NULL,
  metric_query TEXT NOT NULL,
  cadence_hours INTEGER NOT NULL,
  escalation_rule TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active','dropped')),
  next_check_at TEXT NOT NULL,
  links TEXT NOT NULL DEFAULT '[]',
  last_check_at TEXT,
  last_value TEXT,
  last_check_status TEXT,
  last_decision TEXT,
  last_decision_note TEXT,
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_initiatives_due ON initiatives(status, next_check_at);
-- One row per check slot (dedupe_key check:<id>:<due_at>) or reply
-- (reply:<id>:<token>). The key is the idempotency key: a retried check slot
-- upserts its own row, a replayed reply with a different payload is a 409.
-- A check row's status is pinned here; a reply row's status is the decision
-- (approve, change, or the drop decision), which the route validates: this
-- file must never carry that keyword (test/schema-deploy-queue.bh-1026's scan).
CREATE TABLE IF NOT EXISTS initiative_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  initiative_id INTEGER NOT NULL,
  dedupe_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('check','reply')),
  status TEXT NOT NULL CHECK (kind = 'reply' OR status IN ('silent','unreadable','composed','sent','model_failed','empty')),
  value TEXT,
  body TEXT,
  note TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  actor TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_initiative_events_initiative ON initiative_events(initiative_id, created_at);
-- The first initiative: tracer-first slicing (#3954, #3955, #3956), weekly.
INSERT OR IGNORE INTO initiatives (slug, goal, metric_query, cadence_hours, escalation_rule, status, next_check_at, links, created_by, created_at, updated_at) VALUES
  ('tracer-first-slicing','Tracer-first slicing cuts rework (#3954, #3955, #3956)','csv:logs/outcome-rework-rollup.csv#decomposed_rate@project=cromford',168,'change','active','2026-10-05T07:00:00Z','["https://github.com/example-org/cromford/issues/3954","https://github.com/example-org/cromford/issues/3955","https://github.com/example-org/cromford/issues/3956"]','seed','2026-10-03T00:00:00Z','2026-10-03T00:00:00Z');
-- stage.archie: Archie's compose stage route (BH-2536: every agent-call stage
-- has a rung-0 stage route), copied from stage.execute rung 0 on the claude
-- runner exactly as stage.daily-digest is, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.archie', 0, m.model, m.runner, 'seed', '2026-10-03T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.archie')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.archie');
-- ── BH-4760: Archie watch thresholds read by catalog/prompts/archie-watch.md ──
-- One seed per statement. The prompt names the keys and never a number.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('archie.watch.approved_idle_min','60','BH-4760: minutes a PR may sit open, clean and approved without merging before the Archie watch prompt calls it a finding','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('archie.watch.build_fail_pct','30','BH-4760: percent of the builds of one project in the last day that may fail before the Archie watch prompt calls it a finding (with at least archie.watch.build_fail_min_n builds)','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('archie.watch.build_fail_min_n','3','BH-4760: fewest builds in the last day before the Archie watch prompt judges the build failure rate of a project','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('archie.watch.lane_silent_cadences','2','BH-4760: how many of its own cadences a lane may go without a tick before the Archie watch prompt calls it silent','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('archie.watch.spend_pace_pct','120','BH-4760: percent of the cap pace that spend may run at before the Archie watch prompt calls it ahead of pace','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('archie.watch.quota_repeat_n','3','BH-4760: times a quota alert may repeat in the last day before the Archie watch prompt calls it a finding','seed','2026-10-06T00:00:00Z');
-- ── BH-3932 (BH-3929.0): the PR-owner hook knobs ──────────────────────────
-- Read once per bin/pr-owner-sweep.sh run through ph_knob (bin/lib/pr-health.sh):
-- this row wins, then the env named in catalog/lanes.d/pr-owner-sweep.json, then
-- the same default in code. 0 turns the rung off. One seed per statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pr_stale.rebase_hours','24','BH-3929: hours an untouched conflicting PR waits before the age ladder rebases it (arrives with #3935); 0 = rung off','seed','2026-10-03T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pr_stale.replan_days','5','BH-3929: days an untouched PR waits before the age ladder hands it to a re-plan (arrives with #3935); 0 = rung off','seed','2026-10-03T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pr_stale.close_days','10','BH-3929: days an untouched PR waits before the age ladder closes it (arrives with #3935); 0 = rung off','seed','2026-10-03T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pr_owner.enroll_external','1','BH-3929: 1 = the PR-owner sweep enrolls EXTERNAL PRs too (arrives with #3933); 0 = rung off','seed','2026-10-03T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pr_owner.ownerless_alert_hours','24','BH-3929: hours a PR may sit with no owner before the sweep alerts (arrives with #3936); 0 = rung off','seed','2026-10-03T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('trigger.actors.cromford','operator','BH-4490: who may make a cromford ticket buildable (GitHub logins; the harness Apps are always allowed)','seed','2026-10-04T00:00:00Z');

-- ── BH-4140.1 (BH-4146): the lead's protected-path globs, as rows ───────────
-- the operator, 2026-10-03: "protected paths and any data should be in databases not
-- files." One row per (repo, glob) addition. Append-only with soft delete: a
-- remove sets removed_at and never DELETEs, and a re-add inserts a new row, so
-- the table is its own history. lpp_live makes (repo, glob) unique among LIVE
-- rows only. repo is stored lowercased; the glob keeps its case. D1, so no RLS:
-- the gate is the worker bearer. Seeded once by bin/lead-protected-paths-seed.sh
-- from catalog/lead-protected-paths.tsv. The self-create copy is
-- CREATED_TABLES.lead_protected_paths in src/lib/core.js.
CREATE TABLE IF NOT EXISTS lead_protected_paths (id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, glob TEXT NOT NULL, added_by TEXT NOT NULL, added_at TEXT NOT NULL, removed_at TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS lpp_live ON lead_protected_paths(repo, glob) WHERE removed_at IS NULL;

-- BH-4489: the hard budget caps, seeded ON. Three key families, read by
-- bin/lib/budget-stop.sh before every model call (and the project rows by the
-- launch gate in bin/lib/rb/gates.sh):
--   budget.stage.<stage>.max_calls|max_usd|max_tokens  per (build, stage)
--   budget.stage.<stage>.day_usd|day_calls             per (project, stage, UTC day)
--   budget.project.<project>.day_usd                   per (project, UTC day)
-- plus the _default row of each, which caps every stage or project that has no
-- row of its own. Values are p99 x 2 of the 30 days of cost_rows before the
-- timestamp, from `bin/budget-defaults.sh --days 30` (re-runnable; the PR
-- carries its full output). Ceilings for runaways, not budgets. Under 100
-- samples p99 is the window's max, so a row is 2x the largest value seen; a
-- stage with fewer than 30 stage-days gets no day row of its own and is capped
-- by the pooled _default instead (a 16-day lane would have seeded 2x a max of
-- 1). INSERT OR
-- IGNORE, so a re-apply never resets a value an operator or the self-host
-- installer wrote; `off` on a row unarms that axis, `0` refuses everything.
-- Its own statement, for the one-seed-per-statement reason at gh_quota_alert_pct.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('budget.project._default.day_usd','7068.03','BH-4489: p99x2 of 402 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.alert-triage.day_usd','1939.85','BH-4489: p99x2 of 17 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.cromford.day_usd','11323.76','BH-4489: p99x2 of 21 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-4.day_usd','4970.21','BH-4489: p99x2 of 30 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.fleet.day_usd','269.40','BH-4489: p99x2 of 30 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.harness-console.day_usd','651.46','BH-4489: p99x2 of 18 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-8.day_usd','355.19','BH-4489: p99x2 of 31 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-6.day_usd','60.98','BH-4489: p99x2 of 25 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.medic.day_usd','16.24','BH-4489: p99x2 of 17 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-1.day_usd','1104.23','BH-4489: p99x2 of 30 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-3.day_usd','802.15','BH-4489: p99x2 of 31 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.responder.day_usd','182.37','BH-4489: p99x2 of 17 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-9.day_usd','600.56','BH-4489: p99x2 of 31 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-2.day_usd','512.54','BH-4489: p99x2 of 30 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-7.day_usd','807.94','BH-4489: p99x2 of 30 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.project.project-5.day_usd','10644.67','BH-4489: p99x2 of 30 project-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage._default.day_calls','1214','BH-4489: p99x2 of 1387 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage._default.day_usd','1807.85','BH-4489: p99x2 of 1387 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage._default.max_calls','12','BH-4489: p99x2 of 11674 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage._default.max_tokens','73367990','BH-4489: p99x2 of 11674 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage._default.max_usd','45.77','BH-4489: p99x2 of 11674 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.decompose.day_calls','120','BH-4489: p99x2 of 71 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.decompose.day_usd','230.47','BH-4489: p99x2 of 71 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.decompose.max_calls','6','BH-4489: p99x2 of 442 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.decompose.max_tokens','6677086','BH-4489: p99x2 of 442 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.decompose.max_usd','11.05','BH-4489: p99x2 of 442 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.execute.day_calls','476','BH-4489: p99x2 of 133 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.execute.day_usd','3637.25','BH-4489: p99x2 of 133 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.execute.max_calls','6','BH-4489: p99x2 of 2883 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.execute.max_tokens','148871800','BH-4489: p99x2 of 2883 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.execute.max_usd','86.69','BH-4489: p99x2 of 2883 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.fix.day_calls','216','BH-4489: p99x2 of 88 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.fix.day_usd','604.05','BH-4489: p99x2 of 88 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.fix.max_calls','6','BH-4489: p99x2 of 844 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.fix.max_tokens','37859252','BH-4489: p99x2 of 844 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.fix.max_usd','33.83','BH-4489: p99x2 of 844 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.infra.max_calls','2','BH-4489: p99x2 of 86 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.infra.max_usd','5.58','BH-4489: p99x2 of 86 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.plan.day_calls','1150','BH-4489: p99x2 of 128 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.plan.day_usd','1807.85','BH-4489: p99x2 of 128 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.plan.max_calls','6','BH-4489: p99x2 of 4464 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.plan.max_tokens','14486606','BH-4489: p99x2 of 4464 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.plan.max_usd','19.13','BH-4489: p99x2 of 4464 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.preplan.day_calls','536','BH-4489: p99x2 of 138 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.preplan.day_usd','1475.60','BH-4489: p99x2 of 138 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.qa.day_calls','90','BH-4489: p99x2 of 43 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.qa.day_usd','123.79','BH-4489: p99x2 of 43 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.qa.max_calls','12','BH-4489: p99x2 of 195 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.qa.max_tokens','16380672','BH-4489: p99x2 of 195 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.qa.max_usd','14.02','BH-4489: p99x2 of 195 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.remediate.day_calls','38','BH-4489: p99x2 of 65 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.remediate.day_usd','13.01','BH-4489: p99x2 of 65 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.review.day_calls','1386','BH-4489: p99x2 of 188 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.review.day_usd','2142.23','BH-4489: p99x2 of 188 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.review.max_calls','16','BH-4489: p99x2 of 2748 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.review.max_tokens','22847128','BH-4489: p99x2 of 2748 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.review.max_usd','32.89','BH-4489: p99x2 of 2748 build runs, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.triage.day_calls','2040','BH-4489: p99x2 of 363 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z'),
  ('budget.stage.triage.day_usd','1356.41','BH-4489: p99x2 of 363 stage-days, 2026-09-05T01:39:03Z..2026-10-05T01:39:03Z, bin/budget-defaults.sh','seed','2026-10-05T01:39:03Z');
-- ── BH-4079: one wake per webhook DELIVERY, not per minute ──────────────────
-- POST /webhooks/{github,jira,linear} record the vendor's delivery id
-- (X-GitHub-Delivery, X-Atlassian-Webhook-Identifier, Linear-Delivery) in the
-- SAME D1 batch as the wake, and the wake INSERT runs only when this row was
-- new — so a redelivery in a later minute is a duplicate, not a second wake.
-- Pruned by age (`at < now - webhook_delivery_keep_s`, 100 rows a delivery)
-- through the `at` index. D1, so no RLS: the gate is each route's HMAC.
CREATE TABLE IF NOT EXISTS webhook_deliveries (vendor TEXT NOT NULL, delivery_id TEXT NOT NULL, at TEXT NOT NULL, PRIMARY KEY (vendor, delivery_id));
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_at ON webhook_deliveries(at);
-- ── BH-4082 (BH-3979.8, slice C0): projects ─────────────────────────────────
-- The project registry the console's Projects form writes: one row per
-- project, the same columns as fleet.conf (project, repo, prod url, board API
-- prefix, cron offset, box, tailnet ip). PUT /api/projects
-- (src/routes/projects.js) is the only writer and batches a config_changes row
-- (kind 'project') with every change. No shell lane reads this table yet:
-- fleet.conf stays the boxes' source until the materializer slice lands.
-- Ships empty; src/lib/core.js CREATED_TABLES carries the same CREATE so the
-- route self-creates it before the first statement.
CREATE TABLE IF NOT EXISTS projects (
  project TEXT PRIMARY KEY,
  repo TEXT NOT NULL,
  prod_url TEXT,
  board_api_prefix TEXT,
  cron_offset INTEGER NOT NULL,
  box TEXT,
  tailnet_ip TEXT,
  note TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
-- stage.archie-replay: the replay gate of Archie's skill edits (BH-4066,
-- bin/archie-replay-model.sh), seeded the same way from stage.execute rung 0
-- on the claude runner, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.archie-replay', 0, m.model, m.runner, 'seed', '2026-10-04T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.archie-replay')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.archie-replay');

-- ── BH-4583 (BH-4574.1): Archie's factory-manager action ledger ──
-- One row per action the archie-fm lane (bin/archie-fm.sh) takes on a PR, in
-- either mode: 'on' acts, 'observe' records what it would have done. dedupe_key
-- is the idempotency key, and the lane CLAIMS it here (outcome 'started')
-- before any git or GitHub write, so two ticks never act on the same PR twice.
-- The outcome then moves by compare-and-swap through
-- POST /api/archie/actions/outcome (src/routes/archie-actions.js). day is the
-- server clock's UTC day, which the per-playbook day cap counts against. D1,
-- so no RLS: the gate is the worker bearer, as for lead_protected_paths.
-- Applied by bin/harness-sync.sh statement by statement before wrangler deploy.
CREATE TABLE IF NOT EXISTS archie_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dedupe_key TEXT NOT NULL UNIQUE,
  day TEXT NOT NULL,
  project TEXT NOT NULL,
  repo TEXT NOT NULL,
  pr INTEGER NOT NULL,
  playbook TEXT NOT NULL,
  mode TEXT NOT NULL,
  action TEXT NOT NULL,
  outcome TEXT NOT NULL,
  why TEXT NOT NULL,
  evidence TEXT NOT NULL DEFAULT '{}',
  attempts INTEGER NOT NULL DEFAULT 1,
  actor TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_archie_actions_day ON archie_actions(day, playbook);
CREATE INDEX IF NOT EXISTS idx_archie_actions_pr ON archie_actions(repo, pr);
-- The lane's knobs. archie.manage is the fleet mode; archie.manage.<project>
-- (not seeded) overrides it for one project. The cap counts mode 'on' rows whose
-- outcome is done or requested, per UTC day, across the fleet. One seed per statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.manage','observe','BH-4583: Archie factory-manager mode for every project: on | observe | off. archie.manage.<project> (not seeded) overrides it; a value that is none of the three is read as observe. Seeded observe (review N1, 2026-10-06): the first deploy only records what it would do; flip this row to on once a day of observe rows reads right','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.stacked-parent-merged','20','BH-4583: stacked-parent-merged actions (mode on, outcome done or requested) per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
-- ── BH-4585 (BH-4574.3): the rebase-repair playbook's knobs ──
-- No new table: rebase-repair rows go into archie_actions above. One seed per
-- statement; bin/lib/archie-fm-repair.sh carries each value as its code fallback.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.rebase-repair','10','BH-4585: rebase-repair actions (mode on, outcome done or requested) per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.fm.first_s','1200','BH-4585: seconds bin/blocked-resolver.sh leaves a conflict-unresolvable / rebase-gate-red park to Archie before its own fix round when Archie has no row for the head yet; 0 = never wait','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.fm.union_globs','worker/*/src/index.js,worker/*/schema.sql,catalog/*.json,*.d/*','BH-4585: comma list of path globs (* crosses /) whose conflicts rebase-repair may resolve as an append-only union, validated by parse; anything else goes to a fix round','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.fm.regen','docs/config-inventory/deployment.md=bin/config-inventory.sh;docs/config-inventory/deployment.json=bin/config-inventory.sh','BH-4585: <path>=<command> pairs separated by ; that rebase-repair re-renders in place (as nobody, in a snapshot) after merging main, beside the repo''s own Generated-files table; only tracked paths are carried back','seed','2026-10-05T00:00:00Z');

-- ── BH-4584 (BH-4574.2): Archie's queue doctor (bin/archie-fm-queue.sh) ──
-- No new table: its actions are archie_actions rows under four playbooks. The
-- caps count mode 'on' rows whose outcome is done or requested, per UTC day,
-- across the fleet (0 = the playbook is off); queue-solo caps the CI-pool solo
-- runs on their own because they spend CI minutes. The three thresholds are
-- seconds a conductor row must have sat before the lane reads it as stuck.
-- One seed per statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.queue-culprit','10','BH-4584: head-bound BLOCK verdicts on batch members that reproduce alone, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.queue-enqueue','20','BH-4584: enqueues of approved, green, clean PRs nobody enqueued, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.queue-reconcile','30','BH-4584: conductor/GitHub corrections (settle merged, release a dependency hold, report one, kick a stale WAIT_CI), per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.queue-solo','40','BH-4584: CI-pool solo runs of failed-batch members (CI minutes), per UTC day across the fleet; 0 = no solo runs','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.queue.wait_ci_stale_s','2700','BH-4584: seconds a WAIT_CI row with every check green on its head waits before archie-fm-queue runs the conductor keyed to it once','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.queue.dep_hold_stale_s','1800','BH-4584: seconds a READY row held by the PR-dependency gate waits before archie-fm-queue re-reads its dependencies','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.queue.ready_unqueued_s','1800','BH-4584: seconds a harness PR may sit READY with no Mergify ask on its head before archie-fm-queue enqueues it','seed','2026-10-05T00:00:00Z');

-- ── BH-4586 (BH-4574.4): Archie's whole-factory watch (bin/archie-fm-watch.sh) ──
-- No new table: each lever pull and escalation ticket is an archie_actions row
-- (playbooks watch-<class> and watch-ticket, pr 0). The caps count mode 'on' rows
-- whose outcome is done or requested, per UTC day, across the fleet (0 = the
-- playbook is off). The archie.watch.* rows are the lane's thresholds; disk and
-- tmpfs percentages stay with their own detectors. One seed per statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-build-stuck','20','BH-4586: alerts acked and routed for builds stuck past their stage SLA, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-review-unrescued','10','BH-4586: review-rescue kicks for reaped or blocked builds nobody rescued, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-pool-idle','5','BH-4586: tickets for pool machines idle but billed, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-disk','10','BH-4586: disk-clean runs on the hub and disk alerts acked for other boxes, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-cron-install','6','BH-4586: fleet-propagate kicks for a merged lane whose cron is not installed, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-deploy-drift','6','BH-4586: deploy re-runs (workers rerun-failed-jobs, console-pages-deploy), per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-main-red','10','BH-4586: main-red-bisect kicks for a red main, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-pause-waiting','5','BH-4586: tickets for a project paused with work waiting, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-triage-skip','10','BH-4586: run_triage box commands for a board with untriaged tickets, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-cost-anomaly','10','BH-4586: cost-rollup kicks and cost/quota alerts acked, per UTC day across the fleet; 0 = playbook off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-ticket','5','BH-4586: escalation issues filed on example-org/cromford for an incident still open after its lever, per UTC day across the fleet; 0 = no escalation tickets','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-owed-overdue','20','BH-4586: OWED TO OPERATOR lines past their expected-by recorded once each (note rows the model session reads), per UTC day; 0 = playbook off','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-metric-unreadable','20','BH-4586: initiatives whose metric is unreadable recorded once each (note rows the model session reads), per UTC day; 0 = playbook off','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.watch-session','12','BH-4586: archie-fm-watch model sessions (one agent-call, stage archie) per UTC day: only when a tick finds something new, or once per UTC 3h block to walk the owed ledger (the operator, 2026-10-06); 0 = no sessions','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.watch.escalate_s','7200','BH-4586: seconds after its lever ran that a still-open incident gets ONE escalation ticket','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.watch.rescue_grace_s','3600','BH-4586: seconds a REVIEW_BLOCKED (or reaped) build or a lane-reaper alert waits for review-rescue before archie-fm-watch kicks it','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.watch.cron_install_s','1800','BH-4586: seconds after a wired hub lane is added on main (or a fleet-propagate/CRONTAB alert opens) before its missing cron is a finding','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.watch.pause_waiting_s','7200','BH-4586: seconds a builds or merges pause must have lasted, with work waiting behind it, before archie-fm-watch files a ticket','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.watch.inode_pct','90','BH-4586: inode use percent on the hub (df -iP / /tmp) at or over which archie-fm-watch runs disk-clean','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.watch.interval_min','20','BH-4586: minutes between archie-fm-watch ticks that act (the operator, 2026-10-06). Cron fires every 10; a tick acts only when it is the first of its window of epoch minutes. 10..1440; outside that range is one warn line and the default','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.watch.alert_min_age_s','3000','BH-4586: seconds an alert must have been open before archie-fm-watch pulls a lever on it, so the detector self-heals first and alerts-medic (rows new >1200 s, every 30 min) has had one full pass before an ack moves the row out of its new-row path','seed','2026-10-05T00:00:00Z');

-- ── BH-4065 (BH-3966.4): Archie's research scout ledger ─────────────────────
-- One row per dedupe key, claimed BEFORE any billable call and settled after
-- it (src/routes/archie-research.js). The keys are normalised once, in
-- bin/lib/archie-research.sh: xq:<topic>:<day> (one X search per topic per UTC
-- day), wq:<day> (one web scan per day), x:<post id> and web:<sha40 of the
-- canonical url> (a find, scored at most once), sb:<sha16> (one scoring batch),
-- digest:<ISO week>. ok and empty are terminal: a claim on them is refused, so
-- a seen post or url never reaches the vendor again. attempts counts every
-- paid try (a crashed claim included), priced counts the tries whose dollars
-- are in cost_usd, and the day's spend charges every other try at a reserve.
-- raw is the vendor payload snapshot (at most 8000 chars).
CREATE TABLE IF NOT EXISTS archie_research (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dedupe_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('xquery','webscan','item','batch','digest')),
  source TEXT CHECK (source IN ('x','web') OR source IS NULL),
  status TEXT NOT NULL CHECK (status IN ('claimed','ok','empty','failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  day TEXT NOT NULL,
  url TEXT,
  title TEXT,
  applies INTEGER,
  score REAL,
  why TEXT,
  proposal_title TEXT,
  proposal_summary TEXT,
  proposal_slug TEXT,
  input_toks INTEGER,
  output_toks INTEGER,
  tool_calls INTEGER,
  cost_usd REAL,
  priced INTEGER NOT NULL DEFAULT 0,
  raw TEXT,
  note TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_archie_research_day ON archie_research(day, kind);
-- stage.archie-research: the web scan and the scoring call, copied from
-- stage.execute rung 0 on the claude runner (WebSearch exists only there), the
-- way stage.archie is, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.archie-research', 0, m.model, m.runner, 'seed', '2026-10-04T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.archie-research')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.archie-research');
-- archie-research.xsearch: the direct xAI X search, copied from grok.default rung 0.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'archie-research.xsearch', 0, m.model, m.runner, 'seed', '2026-10-04T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'grok.default' AND m.position = 0 AND m.runner = 'grok'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'archie-research.xsearch')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'archie-research.xsearch');
-- BH-4762: the cap's seed moves 1.00 -> 3.00. A fresh DB gets 3.00; on an
-- existing one ONLY a row nobody changed moves (actor seed, value 1.00): an
-- operator's row (any other actor) or a seed already moved is left alone, and
-- a second apply matches nothing. An upsert, not an UPDATE, so the statement
-- stays INSERT OR IGNORE (tests/schema-additive.bh-1000-test.sh) and can never
-- reset a knob an operator set.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.archie-research.archie_research_usd_cap_day','3.00','BH-4762: dollars the archie-research lane may spend per UTC day (xAI X search plus the web scan and scoring calls), read from its own ledger, fail closed. Was 1.00 (BH-4065)','seed','2026-10-06T00:00:00Z')
  ON CONFLICT(key) DO UPDATE SET value = excluded.value, note = excluded.note, updated_at = excluded.updated_at
  WHERE settings.actor = 'seed' AND settings.value = '1.00';
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.archie-research.archie_research_topics','AI software factories|autonomous SDLC|agent harnesses|improving AI dev loops|Anthropic and AI vendor releases|new AI model releases (Anthropic, OpenAI, Google, xAI, open-weight) and what they change for coding agents|automated SDLC and software factory talks on YouTube','BH-4762: pipe-separated research topics, one X search each per day (at most 10), all listed in the web scan prompt','seed','2026-10-06T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.archie-research.archie_research_max_attempts','3','BH-4065: paid tries per research key (a search, a find, a scoring batch, a digest) before it is left failed','seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.archie-research.approve_files_issue_repos','example-org/cromford','BH-4065: repos where an Approve on an Archie proposal files an ai-build issue (comma list, exact owner/repo); any other GitHub-Issues project only marks the Ideas row','seed','2026-10-04T00:00:00Z');

-- ── BH-4067 (BH-3966.6): Archie's earned autonomy ───────────────────────────
-- A decision class is the kind of call an escalation asks the operator to make. Each
-- one starts ask_first; it earns a delegation proposal after N agreements in a
-- row (settings row lane.archie.archie_delegate_after), moves to delegated only
-- on the operator's own `Archie delegate <class>` (src/routes/archie-autonomy.js), and
-- one overrule puts it back. The six protected classes can never be delegated:
-- the first CHECK pins their never_delegable to 1, the second keeps every
-- never_delegable class ask_first, and the route refuses them as well.
CREATE TABLE IF NOT EXISTS archie_classes (
  class TEXT PRIMARY KEY,
  never_delegable INTEGER NOT NULL DEFAULT 0 CHECK (never_delegable IN (0,1)),
  state TEXT NOT NULL DEFAULT 'ask_first' CHECK (state IN ('ask_first','delegated')),
  streak INTEGER NOT NULL DEFAULT 0,
  delegated_at TEXT,
  reverted_at TEXT,
  updated_at TEXT NOT NULL,
  note TEXT,
  CHECK (class NOT IN ('client-board','spend','production','merge','deploy','unclassified') OR never_delegable = 1),
  CHECK (never_delegable = 0 OR state = 'ask_first')
);
-- One row per escalation, keyed like its check slot (check:<id>:<due_at>): the
-- class, the recommendation, whether it was asked or handled (mode), and
-- the operator's answer once he gives it (choice, choice_key). counted = 1 when that
-- answer added to the class's streak.
CREATE TABLE IF NOT EXISTS archie_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  escalation_key TEXT NOT NULL UNIQUE,
  initiative_id INTEGER NOT NULL,
  class TEXT NOT NULL,
  sensitive INTEGER NOT NULL DEFAULT 0 CHECK (sensitive IN (0,1)),
  recommendation TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('ask','auto')),
  auto_choice TEXT,
  choice TEXT,
  choice_key TEXT,
  counted INTEGER NOT NULL DEFAULT 0 CHECK (counted IN (0,1)),
  created_at TEXT NOT NULL,
  chosen_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_archie_decisions_initiative ON archie_decisions(initiative_id, id);
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('watch-continue',0,'ask_first',0,'2026-10-04T00:00:00Z','keep watching, nothing to do'),
  ('watch-cadence',0,'ask_first',0,'2026-10-04T00:00:00Z','check more or less often'),
  ('watch-stop',0,'ask_first',0,'2026-10-04T00:00:00Z','stop watching a goal'),
  ('ticket-file',0,'ask_first',0,'2026-10-04T00:00:00Z','file an ai-build ticket'),
  ('hold-resume',0,'ask_first',0,'2026-10-04T00:00:00Z','hold or resume a wave'),
  ('client-board',1,'ask_first',0,'2026-10-04T00:00:00Z','protected: anything a client sees'),
  ('spend',1,'ask_first',0,'2026-10-04T00:00:00Z','protected: money'),
  ('production',1,'ask_first',0,'2026-10-04T00:00:00Z','protected: production'),
  ('merge',1,'ask_first',0,'2026-10-04T00:00:00Z','protected: merges'),
  ('deploy',1,'ask_first',0,'2026-10-04T00:00:00Z','protected: deploys'),
  ('unclassified',1,'ask_first',0,'2026-10-04T00:00:00Z','protected: the model named no known class');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.archie.archie_delegate_after','5','BH-4067: agreements in a row before Archie offers to take a class of call (and the least the delegate command accepts)','seed','2026-10-04T00:00:00Z');

-- BH-4664.0 (BH-4667): external-PR fix rounds, read by bin/lib/br/opt/external.sh
-- through br_xpr_knob (row, then env, then the code default; an outage reads the
-- default). fix_rounds.<project> opts a project in (0 or no row = off);
-- author_quiet_min is how long an outsider's head must sit before the lane
-- touches it. One seed per statement, INSERT OR IGNORE so a re-apply never
-- resets an operator's value.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('external_pr.author_quiet_min','60','BH-4664: minutes since an external PR head was committed before the resolver acts on it; a head authored as the harness git identity is quiet at once','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('external_pr.fix_rounds.project-4','1','BH-4664: 1 = project-4 external PRs are resolver candidates (changes requested / dirty); 0 = off','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('external_pr.fix_rounds.project-3','1','BH-4664: 1 = project-3 external PRs are resolver candidates (changes requested / dirty); 0 = off','seed','2026-10-05T00:00:00Z');

-- ── BH-4492 (BH-4475.5): egress allowlist rows ───────────────────────────────
-- Read per build-stage call by eg_hosts (bin/lib/egress.sh): the stage's CLI
-- runs in its own network namespace and reaches only these hosts, through
-- bin/egress-proxy.py. execute gets the model APIs plus the npm and PyPI
-- registries; review gets the model APIs only. A stage with no row is unfenced.
-- INSERT OR IGNORE so a re-apply never resets an operator's edit. One seed per
-- statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('egress.stage.execute.hosts','api.anthropic.com platform.claude.com api.x.ai api.openai.com chatgpt.com auth.openai.com openrouter.ai api.fireworks.ai generativelanguage.googleapis.com registry.npmjs.org registry.yarnpkg.com pypi.org files.pythonhosted.org','BH-4492: hosts an execute stage process may reach through the egress proxy; space/comma list of host, *.suffix, host:port; off = unfenced','seed','2026-10-05T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('egress.stage.review.hosts','api.anthropic.com platform.claude.com api.x.ai api.openai.com chatgpt.com auth.openai.com openrouter.ai api.fireworks.ai generativelanguage.googleapis.com','BH-4492: hosts a review stage process may reach through the egress proxy; space/comma list of host, *.suffix, host:port; off = unfenced','seed','2026-10-05T00:00:00Z');
