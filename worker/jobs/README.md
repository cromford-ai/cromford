# harness-jobs — deploy + catalog sync

DB-driven coordination for the fleet, phase 1 of `docs/DB-COORDINATION-SPEC.md`.
Jobs, stage events and lane budgets live in one Cloudflare D1 database that the
hub, every watcher box and every ephemeral fly builder reads over HTTPS.

- Worker: `harness-jobs` — https://harness-jobs.operator.workers.dev
- D1: `harness-jobs` (`00000000-0000-0000-0000-000000000000`), account
  `00000000000000000000000000000000` (the watchdog/locks account)
- Auth: `Authorization: Bearer $HARNESS_SECRET`, on every endpoint EXCEPT
  `POST /webhooks/github`, which GitHub cannot send a bearer to and which
  authenticates with an HMAC over the raw body instead (`GITHUB_WEBHOOK_SECRET`
  — see `docs/EVENTS.md`; unset = 503, never "allow"). Boxes hold
  that secret already; no Cloudflare credential ever leaves the hub.
- Client: `bin/jobs-client.sh` (source it, or run it directly)

Its own worker on purpose, like `harness-locks` and `harness-watchdog`: a bad
deploy here cannot take down the console or the Telegram relay.

## Layout (BH-1195)

```
src/index.js            the fetch entry; OPEN_ROUTES, and ROUTES from "#routes"
src/lib/http.js         nowIso, json, bearerOk, readBody
src/lib/router.js       first-match-wins resolution over the table
src/lib/route-families.js  which families make up ROUTES, from the fragments
src/routes.gen.js       GENERATED, git-ignored: ROUTES for the wrangler bundle
scripts/routes-build.mjs   renders src/routes.gen.js (wrangler build.command)
test/lib/routes.node.js ROUTES for node, read from the fragments at load time
src/lib/core.js         constants, transition graphs, SQL, computeDora,
                        computeAnchored, decorateLane … (the shared half)
src/routes/<family>.js  one file per route family, each exporting
                        `[method, matcher, handler]` rows
```

Until BH-1195 all 104 routes were one flat `if (path === … && req.method === …)`
chain inside `fetch`. Order is still load-bearing (`GET /api/jobs/:id` above
`GET /api/jobs`), and `test/route-table.test.js` compares the table against the
chain it replaced, entry for entry. A new route is added to the family module
AND to that fixture. The bearer still sits between the two tables: `OPEN_ROUTES`
holds only `/webhooks/github`, everything else is reached after `bearerOk`.

A new route family is a module plus a fragment, never an edit to `src/index.js`
(BH-4607). Write `src/routes/<family>.js` and `test/route-table.d/<NNN>-<family>.txt`;
the three-digit number is the family's place in `ROUTES`. `src/index.js` imports
`ROUTES` from `#routes`. `package.json` maps that to `src/routes.gen.js` under
`workerd` (wrangler's `build.command` runs `node scripts/routes-build.mjs` before
every bundle) and to `test/lib/routes.node.js` under `default` (node), so no
suite renders anything. A stray fragment name, a shared number or a fragment
with no module fails the render, and so fails the deploy.
`test/route-registry.bh-4607.test.js` fails if a gated import or spread comes
back to `src/index.js`. The open families (webhooks, ci-durations, ci-test-tiers,
suite-results) stay imported by hand in `src/index.js`, because they sit in front
of the bearer.

## Deploy

**Nothing to do by hand.** Since BH-1000 `bin/harness-sync.sh` applies this
worker's `schema.sql` to D1 and then deploys, in that order, whenever the
worker's tree sha moves — see the `# >>> d1 schema apply` block. A statement
that fails writes one ALERTS line naming it and SKIPS the deploy, leaving the
stamp untouched so the next `update-runners.sh` run retries. The evidence on the
hub is `schema.sql applied (<n> statements)` in `logs/update-runners.log`,
immediately before `worker jobs deployed`.

A long apply is resumable (BH-1555): every round trip D1 accepts is recorded in
`state/worker-schema-progress-jobs`, so a cold apply killed by
`fleet-propagate`'s `timeout 300` continues on the next run
(`schema apply: resuming at statement <k>/<m>` in the same log) instead of
restarting at statement 1. The file is removed when the apply completes, and a
stale one (the schema changed again since) is discarded, not trusted. Nothing to
do by hand for either.

One thing this apply cannot do for you: EDITING a statement that defines a
table, index, view or trigger D1 already has. `CREATE ... IF NOT EXISTS` is a
silent no-op there, so the edit is sent, reports success and changes nothing.
harness-sync detects that and writes one ALERTS line naming the object and its
statement ordinal (`edits the definition of an EXISTING object`); the fix is a
new object or an explicit migration, never an edit in place.

That retry covers a FAILED statement, and nothing else. The stamp
(`state/worker-schema-applied-jobs`) is `<schema.sql blob sha> <database name>`,
so an edited schema and a moved binding both re-apply on their own — but a D1
that is **reset or restored under the same name** leaves the stamp true while
the tables are gone, the apply is skipped on every run, and the routes answer
`503 <table> schema not applied` until somebody intervenes. There is no signal
this file can read for that, so it is a hand step, once, on the hub:

```bash
rm /root/harness/state/worker-schema-applied-jobs \
   /root/harness/state/worker-schema-progress-jobs  # next deploy-mode run re-applies in full
```

Remove BOTH files. The progress file (BH-1555) is keyed on the schema blob, the
database and the baseline, and a reset changes none of those: left in place
after an interrupted cold apply, it would make the re-apply skip the statements
it counted, which no longer exist on the reset database.

By hand, from this directory, with the hub's CF token in the environment:

The statements to run come from `schema.sql`, which is not in git (BH-6005). The
first command composes it from `schema.d/`, and the same goes for the
`--file=./schema.sql` steps in the per-phase sections below:

```bash
set -a; . /root/harness/env/cloudflare.env; set +a
../../bin/schema-build.sh --worker jobs --write
npx wrangler d1 execute harness-jobs --remote --command "<one statement>"   # additive, re-runnable
npx wrangler deploy
```

One statement per call, and not for neatness: under the hub's OAuth credentials
`wrangler d1 execute --file` fails with `Authentication error [code: 10000]`
while `--command` works (the operator, 2026-09-19). The older per-phase **Rollout**
sections below still show `--file=./schema.sql` as step 1; they are the record
of how each phase shipped, not instructions to follow today. The token in
`env/cloudflare.env` must carry **D1 Edit** for either form to work.

`schema.sql` is idempotent (every statement `IF NOT EXISTS`) and is meant to be
re-applied on every deploy — that re-apply IS this worker's migration mechanism,
so a phase's new tables ship in the same PR as the code that reads them and land
with the deploy. Phase 3 adds `job_heartbeats` and `pause_flags`, phase 5 adds
`job_phases`, and phase 6 adds `concurrency_rules`, `retry_policies` and
`job_claims`; every one is a new table rather than a column on `jobs`, because D1
has no `ADD COLUMN IF NOT EXISTS` and a column could not live in a re-runnable
file. The column adds so far — every one of them a row in `ADDED_COLUMNS`
(`pr_costs.auth_account` / `account_breakdown`, 2026-09-02;
`outcome_metrics.repairs`, 2026-09-06; the `cost_rows` provenance and
`extra_usage_snapshots` meter columns, 2026-09-14; `jobs.issue_created_at` /
`jobs.first_spawn_at`, 2026-09-17, BH-482, the launch lead time's two stamps,
ALTERed in on both the claim and the DORA read) — keep that rule: the CREATE
carries the columns for a fresh DB, and `ensureColumns` in `src/lib/core.js` reads
`PRAGMA table_info` and ALTERs the gap on an existing DB before the first write
— so the deploy is still the whole migration, no hand-run SQL. One helper,
keyed by table, because a second copy of it is a second place for that sentence
to stop being true. Phase 6's rule seeds are `INSERT OR IGNORE`, so a cap raised by hand is
never reset by a re-apply — these rows exist to be edited, which is the whole
reason they are rows. **Additive only, forever** — no DROP, no rename, no
destructive migration: boxes run whatever `bin/` they last synced, so an old
client must keep working against a newer schema.

The secret is set once and lives only in Cloudflare:

```bash
printf '%s' "$HARNESS_SECRET" | npx wrangler secret put HARNESS_SECRET
```

## Exception reporting (BH-5618)

The default export is wrapped by `withHarnessSentry` (`src/lib/sentry.js`).

- **Secret:** `HARNESS_SENTRY_DSN` (set on harness-jobs). Unset = no reporting,
  and `@sentry/cloudflare` is never imported. The import is lazy, so the node
  tests of single route files still run without `npm ci`.
- **Scrubbed before send:** the request body, cookies and query string, and
  every header, `extra`, `contexts` and breadcrumb key matching
  `authorization|cookie|token|secret`. `sendDefaultPii` is false.
- **Cap:** at most `HARNESS_SENTRY_MAX_PER_FP_HOUR` events (plain var, default
  6) per exception type + message head per UTC hour, per isolate.
- **Kill switch:** the `pause_flags` row `lane-off-sentry-report` with
  `active = 1`. A failed read of that row sends (fail-open).
- **Tags:** `lane=harness-jobs`, `box=cloudflare`, `project=-`, `harness_sha`
  (`HARNESS_SHA`, which nothing binds yet, so `unknown`).
- **Deploy:** `wrangler.jsonc` sets `compatibility_flags: ["nodejs_compat"]`.
  `bin/harness-sync.sh` runs `npm ci --omit=dev` in the snapshot before
  `wrangler deploy` (`# >>> worker npm ci`). A failed install writes one
  ALERTS line and skips the deploy; the next run retries.

Details and the live probe: `docs/verification-map/worker-sentry.md`.

## Catalog sync (run this on hot-deploy)

`budget_catalog` mirrors `catalog/context-budgets.json`. It is what makes lane
caps reach a fly builder at all — fly-sync tars `bin/prompts/rules/fleet.conf`
and never `catalog/`, so on the very machines that run build lanes the manifest
is absent, and every stage fell through to the hardcoded tier and budget-stopped
mid-run (TK-109, $424). Push the file after any change to it:

```bash
/root/harness/bin/jobs-client.sh catalog-sync              # finds the checkout copy
/root/harness/bin/jobs-client.sh catalog-sync /path/to/context-budgets.json
```

The worker does the derivation, so every box reads numbers computed one way:
each manifest lane becomes the key `<stage>/<project|*>/<runner|*>`, valued with
`bin/agent-call.sh`'s own formula (input at $15/M plus an output allowance of
15% of the ceiling at $75/M), floored at its STAGE FAMILY's fuse. A
`runner_ceilings` override gets its own key, because the xAI 200K cliff is a
fact about the executor, not the job. Lookup walks the same specificity ladder agent-call uses — project
outweighs runner, most specific wins — and answers `source:"tier"` when nothing
matches, which the client deliberately reports as a miss so an unbudgeted lane
still reaches the existing UNBUDGETED LANE alert.

### The floor is the tier: max cost, not target cost

`stageFloor()` in `src/index.js` is the one definition of both, per stage family:

| family | stages | floor / tier |
| --- | --- | --- |
| build | `plan` `execute` `review` `fix` `revise` `takeover` | **$50** |
| product | `ideate` `prd` `mockup` `signals` `synth` `preplan` `map` | **$20** |
| misc | everything else, incl. `probe` | **$10** |

The build number was $10.50 until 2026-08-30 (the operator: "lets change our max cost
per PR it's too low"). Honest build jobs now run ~$15-25 — project-2 TK-206 spent
$16.46 doing everything right and still read as over budget in the watchdog line
and on the console, which was a measurement bug rather than a cost problem. $50
is roughly 2x the top of the honest range, so meeting it is evidence of a
runaway, not of a big ticket.

The floor applies at BOTH ends — `PUT /api/catalog` derivation and
`resolveLane` read — so a row written by an older sync, or pushed as a raw
`{entries:[…]}` pair, still funds today's work at today's policy. The stored
number rides along in the response as `derived_usd`, so a floored row stays
explainable from the DB.

Two things skip the floor and bind VERBATIM, because both are a human saying
"this exact number, on purpose": an `AGENT_CALL_BUDGET_USD*` env override on the
file side, and a `budget_cap_flags` row marked `explicit=1` here. Note that
`bin/agent-call.sh` keeps its own, HIGHER per-stage fuse (150 / 50 / 25) for the
runner CLI's `--max-budget-usd` and floors whatever it reads from here, so these
numbers can never lower that bound. Real spend control is the daily burn ceiling
and the token ceilings — never this.

One known cosmetic difference: the shell side rounds a `x.xx5` tie with awk's
`%.2f` and the worker rounds half away from zero, so a lane can differ by one
cent (`execute/*/*`: 13.12 file, 13.13 DB). Same policy number either way.

## API

All endpoints Bearer-authed, JSON in/out.

| Method | Path | Notes |
|---|---|---|
| POST | `/api/jobs` | register/claim. `409` + the existing row when an open job for the same project+ticket+kind is held by ANOTHER box — the double-build guard. Same box gets `200 {resumed:true}` so RESUME_BUILD stays idempotent. Ticketless jobs (triage ticks) are not guarded. |
| PATCH | `/api/jobs/:id` | stage / status / `spend_delta` (the worker sums) or `spent_usd` / `budget_usd` / `meta` |
| GET | `/api/jobs?project=&status=&box=&limit=` | in-flight query |
| POST | `/api/jobs/:id/events` | append a stage_event (`actor` required) |
| PUT | `/api/catalog` | bulk upsert; accepts the raw manifest (`{lanes:[…]}`) or `{entries:[{lane,budget_usd}]}` |
| GET | `/api/catalog/<stage>/<project>/<runner>` | cap lookup |
| GET | `/api/ledger?kind=&key=` | phase 2 done-ledger (merge-sweep, migration-autopilot). With `key`: the row, or `404` when absent — a real answer the client maps to rc=2, not an outage. Without `key`: list by kind, newest first (`updated_at DESC, key DESC`). Page with the last row's `before=<updated_at>&before_key=<key>` (BH-2450); `before` alone is the legacy strict `updated_at<before` cursor and skips rows sharing that second; `before_key` without `before` is a `400`. |
| PUT | `/api/ledger` | upsert `{kind,key,status,actor,job_id?,detail?}`, idempotent on `(kind,key)` |
| POST | `/api/pr-state-events` | BH-1025.1. One sighting of one PR: `{repo,number,state,since,head?,reviewed?,reason?,url?,alerted?,actor?}`. THE INSERT IS THE DEDUPE — `ON CONFLICT DO NOTHING` on `(repo,number,state,since,alerted)` — so a repeat is `200 {duplicate:true}` and a first sighting is `201 {recorded:true}`, never an error. `alerted` defaults to `'-'`: a NULL never collides in a SQLite UNIQUE index. A non-integer `number` is a `400`, never a truncated PR. |
| GET | `/api/pr-state-events?repo=&number=&state=&since=&limit=` | BH-1025.1. The event LOG, `{rows:[…]}` newest first (`id DESC`), `limit` ≤ 1000 (default 200, floor 1, BOUND not interpolated; a sent non-integer `limit` is a `400`, never a SQLite 500). `since` filters the `at` column — when we saw it, not the PR's own state timestamp. An empty log is a `200` with `rows:[]`, which the client maps to its own rc 2. |
| GET | `/api/pr-state?repo=&limit=&before=` | BH-1025.1. The CURRENT state of each PR from the `pr_state` view (the `MAX(id)` event per PR), `{rows:[…]}` newest first. `before` is an id CURSOR, not a timestamp; a non-integer `before` or `limit` is a `400`. Same `limit` rule as the log above. An empty page is `404 {error:"no rows"}` — a real answer the client maps to rc 2, not an outage. |
| PUT | `/api/pr-attempts` | BH-1025.1. "We have already tried this": `{repo,number,kind,sha,actor?}`, `ON CONFLICT DO NOTHING` on the `(repo,number,kind,sha)` primary key, `201` first time and `200 {duplicate:true}` after. A duplicate never overwrites the first attempt. |
| GET | `/api/pr-attempts?repo=&number=&kind=&sha=` | BH-1025.1. With `sha` (and `kind`, which the primary key needs): the row, or `404 {error:"not found"}` — the real miss `mc_attempt_has` reads as "not attempted", which must never be confused with an outage. Without `sha`: `{attempts:[…],count:N}` with a measured `COUNT(*)`, always `200` — zero attempts is a fact, not a miss. |
| DELETE | `/api/pr-attempts?repo=&number=&kind=&sha=` | BH-1025.1. FORGET one attempt — the row half of `mc_attempt_clear`. `200 {deleted:true}` when a row went, `404` when there was none (also a forget). All four keys required; three of them is a `400`, never a wider delete. Ships in the same deploy as the PUT: a PUT with no DELETE answers the forget `404` while the row sits there, and the PR is skipped for ever. `docs/verification-map/pr-rows-contract.md`. |
| | *the six above ship DARK* | No caller until the `pr-state-rows` flag is up: the client verbs in `bin/lib/jobs/jobs.sh` are all gated on it. `ensureTable` runs at the top of every handler, so they answer even on a D1 that `bin/harness-sync.sh` has not applied `schema.sql` to yet. |
| POST | `/api/jobs/:id/heartbeat` | phase 3. The cheapest write here: one upsert into `job_heartbeats`, no body required. `404` when the job does not exist — a beat is evidence about an EXISTING claim, never a create. |
| GET | `/api/jobs/:id` | phase 3. One call for the console's drill-down: the row, its stage events, any ledger rows naming it, its artifacts, and the transcript INDEX (metadata only — never bodies; this endpoint is polled every 20s by an open drill-down). |
| GET | `/api/jobs/:id/live?since=` | BH-520. The POLLING read for a build in flight: the row, its phases, `spend_usd` (finite phase spends only — a null spend is never counted as 0), and the stage events with `id > since` ascending, capped at 200, plus the `cursor` to pass back next poll. A mangled `since` is a `400`, never a replay from 0. `docs/verification-map/build-live-events.md`. |
| GET | `/api/burn?days=` | phase 3. Per-day spend by project and lane, summed from the job rows. The coordinated share of spend, NOT the fleet's bill — a stage that ran without a claim never reaches it. |
| POST | `/api/jobs/:id/phases` | phase 5. Open a phase row on an existing claim (`{phase,runner?,model?,note?}`). It NEVER guards and never `409`s — the job already holds the claim, so a phase can never make a stage re-ask permission. `404` when the job does not exist. |
| GET | `/api/jobs/:id/phases` | phase 5. Every phase attempt on a job, oldest first. |
| PATCH | `/api/phases/:phase_id` | phase 5. Close (or correct) one phase: `{status,rc?,spend_usd?,runner?,model?,note?}`. Closing stamps `finished_at`; `status` is allowlisted (`running/done/failed/orphaned/budget_stopped`) so a typo cannot render forever as "unknown". |
| POST | `/api/jobs/:id/phases/close` | phase 5. Close EVERY phase still `running` on a job and RETURN their names — how `bin/jobs-watchdog.sh` names the phase a job died in without a second round trip. |
| GET/PUT | `/api/flags` | phase 3 pause flags. `PUT {name,active,actor?,reason?}`; `GET /api/flags/<name>` answers `404` when there is no row, which the client reads as "nothing to reconcile", never as "unpause". |
| GET | `/api/flags?scope=&prefix=&active=1` | BH-4153. Both stores merged, `ORDER BY name, scope`, capped at 500 with `truncated:true` when hit. A ported name (`paused-*`, `automerge-disabled*`, `lanedown-*`) comes from `harness_flags` only; any other name is its `pause_flags` row projected. Every row carries `scope,name,value,set_by,reason,set_at,cleared_at` plus the legacy `active,actor,updated_at`. A `scope` or `prefix` outside `[A-Za-z0-9._-]` is a `400`. |
| GET | `/api/flags/<name>?scope=` | BH-4153. A ported name is its `harness_flags` row at `scope` (default `fleet`), in the full shape; any other name is its `pause_flags` row in the same shape. `404` when there is no row. |
| PUT | `/api/flags` (ported names) | BH-4153. `{name,active,scope?,value?,reason?,actor?,expected_set_at?}`: one batch of the `harness_flags` upsert, the `pause_flags` mirror (fleet scope only) and a `flag` audit row when the row is new or `active`/`value` changed. `expected_set_at` that is not the row's `cleared_at ?? set_at` (`""` for no row) is a `409 {error:'flag moved', flag}` and writes nothing. A non-ported name keeps the phase 3 body above, unchanged. |
| DELETE | `/api/flags?name=&scope=&reason=&actor=` | BH-4153. A ported name is soft-cleared (`cleared_at`), its fleet mirror set `active=0` and one audit row written, in one batch; already cleared is a `200` that writes nothing. Any other name is `PUT {active:0}`. `404` when there is no row. |
| GET/PUT | `/api/routing` | BH-1369 builder routing rows, ordered by project, `LIMIT 500`. `PUT {project,builder,pool_app?,halted?}`: `builder` is exactly `local`, `fly1` or `pool`, `project`/`pool_app` match `[A-Za-z0-9._-]{1,64}` and are not `.` or `..`, anything else is a `400` that writes nothing; `halted` is `1` for `true`/`1`/`"1"`/`"true"`, else `0`; `pool_app` is stored only when `builder` is `pool` (NULL otherwise). |
| GET | `/api/routing/<project>` | exact match on `project` (`project-3` never answers `project-3`); `404` when there is no row; a malformed percent-escape is a `400`. |
| POST | `/api/jobs/:id/transcript` | **transcripts.** Store one ATTEMPT's rendered, scrubbed conversation: `{body, phase_id?, attempt?, stage?, runner?, model?, source?, truncated?, redactions?, actor?}`. `404` when the job does not exist. A body over 150KB is TAILED, never refused — the end of a session is where the failure is. Bearer-only, and the console's Pages proxy passes GET only, so nothing in a browser can author one. |
| GET | `/api/jobs/:id/transcripts` | The INDEX — every attempt on file, **without bodies**. |
| GET | `/api/jobs/:id/transcript?phase_id=&attempt=` | ONE body. `404` = this attempt pushed no transcript, which the console renders as its own empty state rather than as a load error. |
| POST | `/api/preplans` | **pre-plans** (BH-658). Publish the plan a box already paid for, so the HUB can hand it to the Fly machine that will build the ticket: `{project, ticket_key, base_sha, plan_md, planned_files?, ticket_fp?, box?}`. Upsert on `(project, ticket_key)` — a re-plan REPLACES, because the only plan anyone should adopt is the newest one. `400` on an empty `plan_md` or a `base_sha` that is not a git sha (a plan nothing can judge for staleness is never stored); **`413` over 200000 bytes, never truncated** — half a plan is worse than none, because a builder would execute it, and `413` over 100000 bytes of `planned_files` for the same reason in reverse (a list cut short fails OPEN on everything past the cut). Prunes rows older than 14 days on its way out. Answers the row WITHOUT `plan_md`. The table CREATES ITSELF here (`ensureTable`) — nothing in the fleet applies `schema.sql`, so a table that waited for the hand step would 500 on every call for as long as it took someone to notice. |
| GET | `/api/preplans?project=&key=` | ONE pre-plan, WITH its plan — `bin/fly-pool.sh:push_preplan`'s read. `404` = nothing published for this ticket, which the relay logs as `PREPLAN_MISS` rather than shipping a partial directory. |
| GET | `/api/preplans?project=` | The INDEX — newest first, `LIMIT 500`, **without plan bodies** but WITH `planned_files`: that list is what `bin/overlap-guard.sh` came for, and reading it from the hub is what lets the guard judge a Fly candidate at all. |
| POST | `/api/context-packs` | **child context packs** (BH-3493). A split parent publishes the map of the code its plan already read, once per child: `{project, ticket_key, parent_key, base_sha?, pack_md, box?}`. Upsert on `(project, ticket_key)`; `created_at` survives, and so does `box` when omitted. `400` on a key that fails `laneName`, on `parent_key == ticket_key`, or on an empty, whitespace or non-string `pack_md`; **`413` over 64000 bytes, never sliced**, and an existing pack for the key is left untouched. Every refusal happens before any D1 statement. `base_sha` is lowercased, not validated. Answers the row WITHOUT `pack_md`. The table creates itself (`ensureTable`). |
| GET | `/api/context-packs?project=&key=` | ONE pack, WITH its body: `bin/lib/context-pack.sh` `cp_fetch`'s read. `{context_pack:{project,ticket_key,parent_key,base_sha,pack_md,bytes,box,created_at,updated_at}, as_of}`, or `404` when nothing was published for the child (the child plans in full). `key` is required; there is no index read. Self-creates the table too, so a fresh D1 answers 404, not 500. |
| PUT | `/api/machines` | **Fly machine registry** (BH-1055). Register or correct one machine: `{project, app, machine_id, role, key?, ticket?, auth_account?, image?, state?, actor?}`. `project`/`app`/`machine_id`/`key` must match `[A-Za-z0-9._-]{1,64}`, `role` ∈ `{builder,pool}`, `state` ∈ the contract's machine states (default `spawned`) — anything else is a `400` that writes nothing. Upserts on `machine_id` (Fly's own id): `spawned_at` is COALESCEd so the FIRST register stays the birth, the optional fields COALESCE so a later call with fewer fields does not blank them, and `ended_at` clears when the new state is non-terminal (a reused machine is live again). Answers `{machine}`. |
| PUT | `/api/machines/observe` | Bulk refresh from a `fly machines list`: `{project, app, machines:[{machine_id,state}], actor?}`. Caps at **200 entries** — over it the call processes the first 200 and answers `capped:true`. One unknown state or malformed id refuses the WHOLE call with a `400` and writes nothing. A listed id with no row is REGISTERED (`role='pool'`, `key=NULL`, `spawned_at=NULL`), never ignored. Then ONE sweep statement marks the unlisted `gone`: because every listed row was just stamped `last_seen=t` in the same transaction, `last_seen < t` IS the set difference — **no `NOT IN (<ids>)` list**, which would pass D1's 100-parameter limit at 100 machines. A row never listed is judged on `spawned_at` with a **30-minute grace**, so a machine created after the caller read its listing is not called gone. A `capped` call sweeps NOTHING (a partial listing cannot prove absence) and answers `gone:0`. Answers `{seen, registered, gone, capped, as_of}`, where `registered` is measured from the row count on either side of the upserts. |
| PATCH | `/api/machines/<id>` | Close or correct one machine: `{project, app, state, detail?, actor?}`. An UPSERT, because the close most likely to arrive is for a machine nobody registered. `state` must be in the contract's set and `detail` over 300 chars is a `400`, never truncated. `ended_at` is stamped only when the state is TERMINAL (`destroyed`/`gone`); a `failed`, `stopped` or `destroy_failed` correction leaves it exactly as it was — `destroy_failed` means the machine is still there and the pool sweep will retry the destroy, so it is in the vocabulary and is NOT terminal. Answers `{machine}`. |
| GET | `/api/machines?project=&app=&key=&live=1` | The registry read. Every filter is optional; one that is PRESENT and malformed is a `400`, never a silently dropped filter. `live=1` excludes `destroyed` and `gone`. `ORDER BY updated_at DESC, machine_id ASC LIMIT 500`. Each row carries `age_s` (from `spawned_at`) and `seen_age_s` (from `last_seen`), **null and never 0** when the stamp is missing. Answers `{machines, as_of}`. |
| GET/PUT | `/api/rules` | phase 6 concurrency rules. `PUT {scope,selector,kind,max_concurrent,note?}` upserts on `(scope,selector,kind)`; `scope` is allowlisted (`ticket/repo/box/lane`) and `max_concurrent` must be an integer ≥ 0, because a non-numeric cap would silently read as "block everything". |
| GET/PUT | `/api/retry-policies` | phase 6 per-lane retry policy. `PUT {lane,max_attempts,backoff_seconds?,escalate_allowed?}`. `GET /api/retry-policies/<lane>` resolves on the SAME lane ladder as the budget catalog and answers `200 {policy:null}` when the lane has none — a real answer, not a `404` the client would read as a ledger miss. |
| GET/PUT | `/api/settings` | BH-283 operator knobs, one row per key. `PUT {key,value,note?,actor?}` upserts on `key`; the key must match `^[a-z0-9_.-]{1,64}$` and the value be a non-empty string ≤256 chars (a JSON number is stringified, anything else is a `400` — a threshold nobody chose is worse than no threshold). `GET /api/settings/<key>` answers `200 {setting:null}` when the row is absent — a real answer the client maps to rc 2, "use your documented fallback", never a `404`. Seeded with `gh_budget_min_remaining=800` and `fly_machines_rows=off` — the machine-registry knob, which the WORKER never reads: the routes above always answer, and `machines_rows_on` in `bin/jobs-client.sh` is what decides whether a caller writes. |
| DELETE | `/api/settings/<key>` | BH-4846: deletes a console custom theme. Only `ui.theme.custom.<slug>` (slug `[a-z0-9-]{1,40}`) is accepted, every other key is a `400`. The row delete and its `setting` config_changes row (before = the value, after = null) are one batch; `actor` and `reason` come from the query. A missing row answers `200 {key, deleted:false}`. On `PUT`, that prefix takes values up to 4096 chars and must be a JSON object. |
| GET/PUT | `/api/contracts` | phase 7 outcome contracts. `PUT {phase,artifact_kind,pattern?,note?}` upserts on `phase`. **Ships empty:** no row for a phase means no contract, which is phase-6 behaviour exactly. `pattern` is a SUBSTRING the ref must contain, never a regex — a regex in an operator-edited row is a way to put a catastrophic backtrack inside a worker that then times out every phase close in the fleet. |
| GET/PUT | `/api/jobs/:id/artifacts` | phase 7. `PUT {artifact_kind,artifact_ref,phase_id?,detail?}` upserts on `(job_id, artifact_kind)` — one PR url per job, one standing verdict, one `evidence` digest (SDLC item 2: `ref` is the build's one-line evidence digest, `detail` the same facts as JSON). An empty `artifact_ref` is a `400`: a blank artifact that satisfies a contract is worse than no contract, because it reads as evidence. **BH-1024:** a `verdict` PUT also appends to `verdict_history` when the `(verdict, reviewed_sha, tier, provenance)` tuple differs from the job's latest round, and the response carries `history_appended: true|false`. Idempotent by CONTENT: a lane that re-puts the same row every tick writes one round, a rebind onto a new head writes the next. The round is read off the STANDING ROW after the upsert, never off the request — a PUT that sends no `detail` keeps the old one (`COALESCE`), and a round taken from the request would record an approval that lost its sha. The standing verdict is still the `job_artifacts` row and is still what a merge acts on — the table self-creates (`CREATED_TABLES`) so the append does not wait for a hand-applied `schema.sql`, and a history append that fails anyway is reported as `history_appended:false` + `history_error` instead of failing the PUT: a 500 here is a failed `job_verdict_rebind`, an `mc_rebase` rc 5 and a rebased approved PR parked `rebind-failed`. |
| GET | `/api/verdict?pr=<url>` | phase 7. Joins a PR url to the job that produced it and returns verdict, tier, provenance, the reviewed sha the approval is bound to (SDLC item 1; `null` on rows written before it, which every merge gate reads as "no claim"), merge sha and every artifact in ONE round trip — `bin/merge-sweep.sh` runs every ten minutes over a directory of records and must not pay three calls per PR. `404` when no job recorded that PR: a REAL answer the sweep maps to scraping its own build record. **BH-1024:** the PR resolves through a RANKING of the `pr_url` artifacts, not the newest one alone — a `build` job first, then a `review-verdict` job, then newest. One `bin/review-prs.sh` tick writes `pr_url` on up to two jobs of its own (the `review` lane claim per (PR, sha), then the short-lived `review-verdict` row), so newest-wins would hand every reviewed PR to the lane claim: a harness PR's own settled verdict would become unreachable, and an external PR would answer from a row with no `source`. It is a tie-break, not a filter — each row is still the answer when it is the only one. |
| GET | `/api/verdict/history?pr=<url>` | BH-1024. Every round that PR's verdict went through, OLDEST FIRST — `{pr, job_id, rounds:[…], truncated, as_of}`. `job_id` is the STANDING owner, resolved exactly as `/api/verdict` resolves it (build job first), so a caller that can read the standing verdict can read how it got there without learning a second key. The ROUNDS are keyed on the PR, not on that one job: `review-prs` opens a fresh `review-verdict` job per reviewed (PR, sha), so a BLOCK → rebase → APPROVE cycle on one external PR lives on two jobs and a job-keyed read would answer "one round, APPROVE" while the table held the BLOCK. Every round names its own `job_id`, so a build's rounds are still tellable from a review lane's. Capped at 200 rounds and `truncated` says so, because a history silently missing its tail reads as a complete one. `404` when no job recorded that PR. |
| GET/PUT | `/api/cap-flags` | phase 7 explicit caps. `PUT {lane,explicit,reason?,actor?}`. Deliberately NOT part of `PUT /api/catalog`: that route is the deploy-time sync and rewrites every lane it carries, so a flag living on that row would be reset by the next hot-deploy — a config change nobody made. |
| POST | `/api/jobs/:id/retry` | phase 6. Judge a dead claim under policy and write the ONE terminal state it lands in: `queued_for_retry` (with `next_attempt_at` at the backoff), `parked` (attempts exhausted) or `orphaned` (no policy for the lane, or a `KILL_STOP`/`BUDGET_STOP` death, which is terminal regardless). Idempotent: a row that is no longer `running` returns the verdict already on it and writes nothing, so a repeated watchdog pass cannot reset a backoff or double-count an attempt. |

`GET /api/jobs` gained three derived fields in phase 3: `last_beat_at`,
`beat_age_s` (null when a claimant has never beaten) and `activity_age_s` — the
freshest evidence of life, falling back to the row's own `updated_at` so a box
whose `bin/` predates heartbeats is still watched, just more coarsely. Every age
is computed on the WORKER's clock: box clocks drift, and a fly builder's is
whatever its image booted with. `?stale_min=N` filters to open rows past N
minutes; the threshold belongs to the caller (`bin/jobs-watchdog.sh`), the clock
does not.

`GET /api/jobs` gained four more in phase 5, as correlated subselects rather
than an N+1 the console would pay across an ocean: `phase` and `phase_status`
(the current or last phase) with its `phase_rc`, and `failed_phase` — the last
phase that failed or was orphaned, which is what turns a red job row from "this
failed" into "this died in execute". `GET /api/jobs/:id` carries the full
`phases` array alongside its events and ledger rows.

`POST /api/jobs` gained two behaviours in phase 6, both of them BEFORE anything
is written. It checks `concurrency_rules` and answers `409 {refused:true, scope,
rule, reason, job}` when a scope is at its limit — the check is inside the claim,
so two boxes racing cannot both read "clear" and both write. **A scope with no
matching row is unlimited**, so an empty table is phase-5 behaviour exactly. And
it PICKS UP a due `queued_for_retry` row for the same work instead of starting
fresh (same job id, `attempts+1`, `200 {retry:true}`); a queued row whose backoff
has not elapsed refuses the claim rather than letting a retry arrive early.

`GET /api/jobs` gained the claim's own columns in phase 6, folded on from
`job_claims` so a reader sees them as facts about the job: `lane`, `attempts`,
`max_attempts`, `next_attempt_at`, `escalate_allowed` and `retry_reason`.

Phase 7 adds two checks and one downgrade, all inside routes that already
existed:

- **`POST /api/jobs` consults `pause_flags` FIRST** — before the double-build
  guard, before the concurrency rules, and before a due retry can be picked up,
  because a pause is "none of this runs here right now" and a backoff must not
  fire on a paused lane. It looks up `paused-all`, `paused-<project>`,
  `paused-box-<box>` and `paused-lane-<lane, slashes as dashes>`, broadest first,
  and answers `409 {refused:true, scope:"pause", flag, reason}`. An empty table,
  or every row at `active=0`, refuses nothing. The FILE stays the fallback:
  `flag_active` is untouched, so a worker outage leaves a box deciding exactly as
  it does today.
- **Status moves are checked against a transition graph** (`JOB_TRANSITIONS` /
  `PHASE_TRANSITIONS`, printed in `docs/DB-COORDINATION-SPEC.md`). `done` and
  `budget_stopped` are terminal; `parked -> done` is illegal. `abandoned` (BH-2406)
  is terminal too, and only `POST /api/jobs/:id/abandon` reaches it: PATCH refuses
  it, so every abandoned row carries an ABANDONED stage event naming who and why. An unknown TARGET
  status is a `409`; an unknown SOURCE status is allowed to move, so a row
  written by something the worker does not model can never become unfixable.
  Enforced on `PATCH /api/jobs/:id`, `PATCH /api/phases/:id`, and on
  `POST /api/jobs` when the caller supplies an `id` — that route upserts
  `ON CONFLICT(id) SET status='running'` and would otherwise resurrect a
  finished claim.
- **A phase with a contract cannot close `done` without its artifact.** It is
  not a refusal to write: the phase lands in `contract_unmet` with the reason on
  the row and the caller gets a `409` it logs. Refusing outright would leave the
  phase reading `running` forever, which is the exact silence `job_phases` was
  built to remove. `contract_unmet` is repairable — record the artifact, close
  again, and the check re-runs.

`GET /api/catalog/<lane>` gained `explicit` and `explicit_reason` in phase 7,
resolved for the EXACT key that answered and never inherited down the lane
ladder: "this exact number, on purpose" is a statement about one row.
`GET /api/jobs/:id` gained an `artifacts` array.

**No secrets in any row, `meta` included.** The DB is coordination truth, not
build truth: PRs, board comments and ALERTS.log remain the client-facing record.

## Wiring on the boxes (phase 1)

- `bin/agent-call.sh` — asks `job_cap` for the lane before a stage and uses the
  answer when the catalog has one; otherwise the `CB_DEFAULT`/catalog-file chain
  is untouched. After a stage it posts the spend delta and, on a budget stop, a
  `BUDGET_STOP` stage_event.
- `bin/run-build.sh` — claims at start; a 409 defers the build (`BUILD_DEFERRED`)
  rather than racing another box. An EXIT hook closes the row with the verdict
  from the build's own `RESULT` file.
- `bin/run-triage.sh` — claims each tick, closes it with the run's rc.

Every one of those calls is fail-open: worker unreachable, slow, unauthed or
wrong → the helper returns nonzero, nothing is printed, and the pipeline behaves
exactly as it did before. Proof lives in `tests/jobs-client-test.sh`, which
drives the real scripts with a stubbed curl.

## Wiring on the boxes (phase 2)

- `bin/merge-sweep.sh` — the done-ledger is `kind=merge` rows keyed by PR url;
  `state/merge-sweep-done.txt` stays as write-through fallback. The file is
  checked FIRST and a DB hit back-fills it, so a worker outage can never turn
  into a double merge.
- `bin/migration-autopilot.sh` — `kind=migration` ledger rows
  (`key="<project> <file>"`) plus a job row and APPLIED/FAILED/FLAGGED/SKIPPED
  stage_events at each terminal decision. It still never applies SQL anywhere
  except through the app's own `/api/internal/migrations/apply` endpoint.
- `bin/harness-sync.sh` — deploy pushes `catalog/context-budgets.json` through
  `jobs-client.sh catalog-sync`, gated on the file's tree sha so a routine
  deploy is not a PUT per tick; a failed push retries on the next deploy.

## Wiring on the boxes (phase 3)

- **Heartbeats.** `run-build.sh`, `run-triage.sh` and `bin/orc-job.sh` start a
  beater at claim time (`job_beat_start`, ~150s) and stop it when the row
  closes; `agent-call.sh` adds one beat at each end of a stage. Cost is per WALL
  CLOCK MINUTE of a claimed row, never per token. The beat loop watches the pid
  that started it and exits when that pid is gone — without that, a SIGKILLed
  parent would leave an immortal beater keeping a dead job's row fresh, which is
  a watchdog lied to by the exact failure it exists to catch.
- **`bin/jobs-watchdog.sh`** (hub cron, */5) asks for `?stale_min=10` and splits
  the answer in two: a row that WAS beating and stopped is marked `orphaned`
  (releasing the double-build guard, since the claim is gone) with one ALERTS
  line carrying project / lane / key / elapsed and the matching `logs/kills.log`
  row; a row that NEVER beat is only REPORTED, at 90 minutes, with its status
  left alone — its age is a lower bound on inactivity, and releasing a claim
  that might still be working is how one ticket gets built twice.
  DETECTION, NOT PREVENTION: nothing is retried here.
- **`bin/orc-job.sh`** wraps a hand-launched detached session
  (`setsid orc-job.sh --project X --key K --kind fix -- claude -p ...`) so it
  opens a row, beats, and closes with the command's real rc. It honours the same
  409 double-build guard the build pipeline does.
- **Pause flags.** `flag_active <name>` reconciles the file from the DB row and
  then tests the FILE, which is still what every reader tests. The contract
  (`schema.sql`, the `pause_flags` comment) is recency: a row newer than the
  file's mtime is applied, the row wins a tie, and an absent file applies the
  row. Today's `bin/lib/jobs/flags.sh` still records the applied `updated_at` in
  `state/flags-db/<name>` and skips a row it has already applied; the #1027
  child that rewrites it moves it onto the recency rule. `poll-commands.sh`
  writes both sides.
- **Builder routing (BH-1369, dark).** `bin/lib/jobs/routing.sh` derives
  `flags/builder-fly-<p>`, `fly-pool-<p>`, `fly-pool-app-<p>` and
  `pool-halt-<p>` from a `routing` row, only when the `routing_rows` setting is
  `on` (seeded `off`; `ROUTING_ROWS` in env overrides per box). Off, the only
  request is one settings GET for the knob (none with `ROUTING_ROWS=off`), no
  `/api/routing` request, and the readers answer from the files alone. On, rows are
  read from `/api/routing` and written with `routing-set`, files first.
  **Flipping it:** the knob is read once per process and cached (a failed read
  caches off), so a flip applies to each process that sources `jobs-client.sh`
  on its NEXT START. Restart long-lived callers after flipping it.

## The console's read path

`console-ui` reaches this worker through its own Pages Function,
`console-ui/functions/api/coord/[[path]].js`: `/api/coord/*` -> `/api/*` here.
The bearer is attached in the Pages runtime (`HARNESS_SECRET` must be set on the
Pages project) and never reaches the browser; the `dash` session is validated by
asking the console worker, so there is exactly one definition of "signed in".
Only `GET` passes, plus `PUT /api/coord/flags` — a job cannot be PATCHed from a
browser, because stage and status transitions belong to the box doing the work.

## Wiring on the boxes (phase 5)

- **`bin/agent-call.sh` owns the phase row.** Every stage in the fleet already
  goes through it, so ONE call site opens a phase at stage start and closes it
  on exit with the stage's REAL rc and its whole bill across the failover
  ladder. The close runs from an EXIT trap, not the last line: this script has
  four survival lanes, and a phase left reading `running` because one of them
  slipped is the same silence phase 3 removed one level up. `KILL_STOP` /
  `BUDGET_STOP` ride in the note, because "the vendor broke" and "the OS ended
  us" are different events with different responses.
- **`bin/run-build.sh` closes what a killed stage could not.** rc=137 runs no
  trap, so its EXIT hook closes any phase still open BEFORE it closes the job,
  and names it on the job's closing event. A job closed first would leave a
  running phase under a corpse.
- **`bin/jobs-watchdog.sh`** marks the open phase `orphaned` in the same breath
  as the job and NAMES it in the alert ("It died in phase: execute"). Still
  detection only — nothing is retried, released or relaunched.
- **Coordination stays per JOB.** One job, one claim, one double-build guard.
  Phases are child records describing what happened inside a claim that was
  already granted; nothing between plan, execute and review asks for it again.
  `tests/job-phases-test.sh` drives that, including the case where the ledger is
  unreachable and every stage must run exactly as it does today.

## Wiring on the boxes (phase 6)

- **The claim is where the rules bind.** `bin/jobs-client.sh` `job_open` maps a
  rule refusal to rc 9 with `REFUSED <scope> :: <reason>` on stdout and the same
  words in `JOB_REFUSED` (for `job_lane_open`, which sets variables and so can
  never be captured). The pre-phase-6 `IN_FLIGHT <box> <id>` shape is unchanged,
  so a box running an older `bin/` still parses what it always did.
- **A refusal is a clean skip.** `bin/run-triage.sh` logs `claim refused:
  <reason>` and exits 0. `bin/run-build.sh` writes `BUILD_DEFERRED` and exits 3 —
  its existing "not now, not a failure" — with the rule's own words in ALERTS.
  `bin/with-job.sh` refuses the same way it always has, now naming the rule.
  None of them bypasses the claim.
- **An outage is not a refusal.** rc 1 still means "say nothing, behave exactly
  like today". `tests/claim-rules-test.sh` drives the real claim blocks from both
  pipelines with the worker down, 500ing and unauthed, and checks the work runs.
- **`bin/jobs-watchdog.sh` asks, then writes.** One `job_retry_judge` call per
  dead row, and the status it writes is the DB's answer. It execs nothing: no
  work script, no claim. Its alert memory is per ATTEMPT now, because a retried
  row dies again under the same id.
- **The console** shows `ATTEMPTS` ("2/3" where a policy exists, a bare count
  where none does), tiles for QUEUED FOR RETRY and PARKED, and the DB's own
  reason on the pill.

## Wiring on the boxes (phase 7)

- **A stage declares its artifact; `agent-call.sh` records it.** `bin/run-build.sh`
  sets `CC_ARTIFACT_KIND`/`CC_ARTIFACT_FILE` before a `CC` call, `CC` passes them
  through as `AGENT_CALL_ARTIFACT_*`, and `bin/agent-call.sh`'s phase-close trap
  records the artifact BEFORE closing — **only if the file actually materialized
  and is non-empty.** That "only if" is the whole feature: a plan stage that
  exits 0 having written nothing records nothing, and the contract then refuses
  to call it done. `agent-call.sh` does not know what a plan or a verdict IS, and
  does not need to.
- **`run-build.sh` records `pr_url`** the moment the URL exists — before QA,
  before the tier settles — so a build that dies later is still findable by PR.
  It records `verdict` AFTER every tier demotion has run, so the tier on the row
  is the settled one and not a tier-1 that QA went on to demote. Since SDLC
  item 1 the verdict detail also carries `reviewed_sha` — the head the approval
  is bound to — so a merge path on another box can park a PR whose head moved
  after the review that approved it.
- **`merge-sweep.sh` reads the verdict from the ledger when there is one.** rc 2
  (no job recorded this PR) and rc 1 (worker unreachable) both fall through to
  today's scraping, unchanged — with an empty ledger the sweep is byte-identical
  to phase 6. A ledger verdict that CONTRADICTS the record parks the PR and
  pages: two copies of one judgement that disagree is a human's question. On a
  successful merge it records `merge_sha` on the BUILD's job, found through the
  same lookup that gave it the verdict.
- **`review-prs.sh` writes a verdict row too, behind `verdict_single_home`
  (BH-1024).** An EXTERNAL PR this lane reviews used to have its verdict in one
  file on one box, invisible to `job_verdict`. With the flag row at `1` the
  `# >>> review verdict ledger` block opens a short-lived job of kind
  `review-verdict` per reviewed (PR, sha), writes `pr_url` + `verdict`
  (`source:"review-prs"`, bound to the reviewed head) and closes it; the same
  flag makes `bin/review-autopilot.sh` and the conductor's autopilot-verdict
  consume read the ledger before their files. The flag ships `0`, which is
  today's behaviour byte for byte, and the files stay write-through caches.
  Both of this lane's job kinds — the `review` claim `review_claim` opens per
  (PR, sha) and the `review-verdict` row — are excluded from
  `/api/metrics/dora`: each is minutes old and built nothing, so attributing a
  merge to either would report a one-minute lead time for a week of work.
- **`job_cap_row` is new; `job_cap` is untouched.** `bin/` syncs per box and not
  atomically across the fleet, so a new client under an older `agent-call.sh`
  must keep answering the bare number that script parses. `_budget_for` prefers
  `job_cap_row`, falls back to `job_cap`, and only an `explicit=1` row skips the
  stage-family floor.
- **No client change was needed for pause refusals.** They arrive as
  `REFUSED pause :: …`, which `run-build.sh` (BUILD_DEFERRED, rc 3) and
  `run-triage.sh` (log, exit 0) already handle.
- `tests/outcome-contracts-test.sh` drives all of it against a stubbed curl —
  including the sweep with the worker down and `_budget_for` with no catalog on
  the box — and asserts `HARNESS_SECRET` never reaches a log.


## Job transcripts (2026-08-29)

Every row in this ledger is one headless agent session. Through phase 7 the
console could say what a stage COST, which runner served it and what rc it died
on, and could say nothing at all about what the model was doing — that lived
only in a session jsonl on one box's disk, behind ssh, on a machine that may
have been recycled since. Transcripts close that.

**The path.** `bin/agent-call.sh` calls `bin/transcript-push.sh` at the end of
EVERY attempt (not at phase close: the survival ladder can run one stage on five
vendors and each overwrites `$OUT`, so a single push at the end would keep only
the lane that happened to answer last). The pusher:

1. resolves the source — the claude session jsonl when `$OUT.json` carries a
   `session_id` that resolves under `~/.claude/projects/*/`, otherwise the
   stage's captured output;
2. renders it with `bin/transcript-render.sh` — **the console never parses raw
   jsonl.** Turns keep their text; tool calls and results become one line each;
   thinking blocks become a length marker;
3. caps to the **tail** at 150KB (`TRANSCRIPT_MAX_BYTES`, stated in both this
   worker and the pusher);
4. **scrubs** with `bin/transcript-scrub.sh` — every value assigned in
   `/root/harness/env/*` (dotfiles included), plus Bearer headers, `?s=` params,
   secret-shaped `KEY=VALUE`, and the vendor token prefixes;
5. pushes through `job_transcript_put`, which rides `--data-binary @file` because
   a 150KB argv element fails `execve` with E2BIG before curl runs.

**Fail-open, with one exception.** A transcript is a side channel on a stage
that has already done its work: an unreachable worker, a 500, a missing session
file or an unclaimed lane all leave one line in `logs/transcripts.log` and change
nothing about the stage's rc. The single place that fails CLOSED is the scrub —
if `transcript-scrub.sh` is missing or errors, **nothing is pushed at all**.

**The enrolment gap, stated plainly.** A job has a transcript only if a MODEL
SESSION ran under it. Coordination lanes — `merge-sweep`, the watchdog, a
migration apply — claim a row to serialise work, never call a model, and will
never have one. Non-claude runners (codex, grok, gemini, openrouter, fireworks)
keep their own session ledgers in their own formats, which this does not read;
those attempts land as `source=stage_output`, the stage's final answer only, and
the console says so on the row rather than implying a full session.

Tests: `tests/transcript-scrub-test.sh` (secret-shaped fixtures),
`tests/transcript-render-test.sh` (jsonl fixtures),
`tests/transcript-push-test.sh` (the wiring, driven through `agent-call.sh`),
`worker/jobs/test/index.test.js` (the endpoints),
`console-ui/tests/transcripts.test.js` (the lib and the rendered component).


## Metrics ledger (2026-08-29)

Four measurement series that only ever existed as CSVs on the hub's disk. the operator:
"move things to the database instead of files" — the readable copy of the
numbers, so a rebuilt hub does not lose the history and the console can ask for
them without ssh.

| table | producer | file it mirrors | key |
| --- | --- | --- | --- |
| `burn_days` | `bin/orchestrator-burn.sh` (hourly) | `logs/orchestrator-burn.csv` | `day` (UTC) |
| `pr_costs` | `bin/cost-rollup.sh` (04:45 + hourly window) | `state/cost/cost-per-pr.csv` | `pr_url` |
| `extra_usage_snapshots` | `bin/extra-usage-track.sh` (every 15 min, one row per LOGIN the box holds — `box` is the ACCOUNT label, see `catalog/cost-accounts.json`) | `logs/extra-usage[-<label>].csv` | `(box, ts)` |
| `cost_reconciliation` | `bin/cost-reconcile.sh` (hub: hourly 1h + daily 24h) | `logs/cost-reconcile.log` | `(account, window_key, window_end)` |
| `outcome_metrics` | `bin/outcome-metrics.sh` (Mondays) | `logs/outcome-metrics.csv` | `(repo, pr, outcome)` |
| `cost_rows` | `bin/cost-rows-push.sh` (every 10 min, per box) | each box's `logs/cost.csv` | `(box, row_hash)` |
| `cost_rows_live` | a running session's meter (`bin/lib/cost-live.sh`, BH-3481; stubbed until that ships) — one row per session, running total, settled once `cost_rows` carries its `session_id`, pruned after 14 days | — | `(box, row_hash)` |
| `cli_versions` | `bin/cli-update.sh` (daily, per box, source=update) + `bin/cli-version-check.sh` (hub sweep, source=check) | each box's `logs/cli-versions.csv`, hub's `state/cli-versions-fleet.tsv` | `(box, cli, at, source)` |
| `box_status` | upserted from every `cli_versions` push (current claude/codex version per box; the PR #195 fix-5 table, created here with its column names) | — | `box` |

```
POST /api/metrics/burn          {day, api_calls, fresh_in, output, cache_read, cache_write, usd_equiv, peak_cache_read, avg_cache_read, actor}
POST /api/metrics/pr-costs      {rows:[{pr_url, cost_usd, input_toks, output_toks, cache_read, cache_write, stage_breakdown, build_dirs, auth_account?, account_breakdown?}, ...]}   (<=2000)
POST /api/metrics/cost-rows     {box, rows:[{line_no, row_hash, ts, host, project, stage, runner, model, rc, duration_s, input_toks, output_toks, cache_read, cache_write, cost_usd, billing_mode, auth_fp, auth_account}, ...]}   (<=2000, ON CONFLICT DO NOTHING)
POST /api/metrics/extra-usage   {box, ts, session_pct, weekly_pct, weekly_resets_at, extra_enabled, extra_used_usd, spend_limit_reached, in_overage, extra_limit_usd?, extra_pct?, status?}
POST /api/metrics/reconcile     {rows:[{account, window_key, window_start, window_end, state, meter_start_usd, meter_end_usd, meter_delta_usd, rows_usd, jobs_usd, unattributed_usd, rows_count, jobs_count, gap_usd, gap_pct, weekly_pct_start, weekly_pct_end, span_start, span_end, alerted, note}, ...]}   (<=500)
GET  /api/metrics/reconcile?[account=][window_key=][state=][since=<iso>][limit=]
POST /api/metrics/outcomes      {rows:[{repo, pr, outcome, day, evidence, repairs?}, ...]}   (<=2000)
GET  /api/metrics/{burn,pr-costs,extra-usage,outcomes}
GET  /api/metrics/cost-rows?[box=][project=][auth_account=][stage=][since=<iso>][until=<iso>][limit=]
POST /api/cost/live             {box, rows:[{row_hash, session_id, run_id, ticket, project, stage, model, input_toks, output_toks, cache_read, cache_write, cost_usd, unpriced, started_at}, ...]}   (<=50, cost_usd never lowered, identical re-push a no-op, testproj dropped, updated_at = worker clock)
GET  /api/cost/live?[hours=24][stale_s=900][run_id=][project=]   {rows (<=500, each with state), in_flight_usd (null = running but unpriced), unsettled_usd, settled_sessions, unpriced_rows, truncated, as_of}
POST /api/metrics/cli-versions   {rows:[{box, cli (claude|codex), at, source (update|check), version_before, version_after, method, ok, path, note}, ...]}   (<=500, history DO NOTHING + box_status upsert that only moves forward in cli_checked_at)
GET  /api/metrics/cli-versions?[box=][cli=][source=][limit=]
GET  /api/boxes                  current box_status rows, one per box
```

Three things to keep true when touching this:

**The file is written first and the push is fail-open.** Every producer writes
its CSV, then pushes through `bin/jobs-client.sh`; an unreachable worker leaves
the CSV byte for byte what it would have been. Being able to SEE the numbers off
the hub must never be able to stop the MEASURING of them.

**Every write is an upsert on the measurement's own key, taken from the ROW.**
These producers all re-cover ground they have covered: the burn day is
re-pushed 24 times a day, `cost-rollup` rewrites all ~219 PR rows every run. A
re-run has to be a no-op. And the key is never re-derived from a clock at the
far end — reading "today" a second time, from a second clock, is precisely what
put six identical rows a day into `orchestrator-burn.csv` for as long as it
existed (producer on local time, dedupe on UTC, five hours of disagreement a
night on a UTC-5 box).

**`GET /api/burn` is a different question from `GET /api/metrics/burn`.** The
first is the coordination DB's view of CLAIMED job spend — a subset, since a
stage that ran with no claim never reaches `jobs`. The second is the
orchestrator's whole API-equivalent burn. Namespacing keeps a reader from
concluding the ledger is wrong when they have asked the wrong question.

The console reads all four through `console-ui/functions/api/outcomes/` and
renders them on `/outcomes`.

### `GET /api/metrics/dora?project=&days=` (2026-09-12)

The DERIVED read over those tables — nothing new is stored, and nothing is
written. Four DORA metrics plus the merge-lane split, per project, over a window
(`days` clamped 1-90, default 14), each with p50/p90, a sample size and an
`evidence` string naming the table it came from. `console-ui` renders it on
`/dora` through the existing `/api/coord/*` proxy.

| metric | computed from | honest today? |
|---|---|---|
| lead time | `jobs.created_at` (reached via `job_artifacts.artifact_kind='pr_url'`) → the verified deploy of that merge where one exists (`ledgers(kind='deploy', status='verified')`), else `ledgers(kind='merge').created_at`. A PR no job claims falls back to the conductor's `pr_state` row `created_at`, counted separately as `from_pr_seen_n` | ends at PRODUCTION for merges a deploy train carried (`to_deploy_n`), at the merge for the rest (`to_merge_n`) — every row carries `lead_end` |
| deployment frequency | `ledgers(kind='deploy', status='verified')` per day once a project has any, `ledgers(kind='merge', status='merged')` per day otherwise | verified departures where recorded (`deploy_verified: true`); merges otherwise, which **overcounts** because a train carries a batch |
| change-failure rate | `outcome_metrics` (`reverted`/`reopened`, DISTINCT PRs) ÷ merges in window. `merged_then_red` reported beside it, never inside it | yes |
| time to restore | `outcome_metrics.created_at` → the next merge into that repo | **upper bound** — the failure clock is a weekly detector's, not the incident's |
| approve → merged | `job_artifacts(artifact_kind='verdict', ref='APPROVE').updated_at` → the merge ledger | yes, but see below |

**The payload carries its own `gaps` array** and the screen renders it.

1. **A verified deploy — CLOSED for any project that runs a train (2026-09-12).**
   `bin/deploy-train.sh` proves production serves the merged sha — it polls the
   project's version endpoint until the live sha is the target or a descendant —
   and now writes that as a `deploy` ledger row on BOTH terminal branches:
   `kind='deploy'`, key `<owner/repo>@<sha production was verified to be serving>`,
   status `verified` or `failed`, detail
   `{project, sha, departure, verified_at|failed_at, prod_url, waited_s, merges, shas, prs}`.
   The write is fail-open — a worker outage costs the row and changes nothing
   about the train. A merge is attached to a departure by the PR urls the row
   names, or (for a merge-queue or self-sourced departure, which has no build dir
   to read a `PR_CREATED` line out of) by the earliest verified arrival for that
   repo AT OR AFTER the merge; an arrival BEFORE the merge is never either. What
   remains open: a project with no `VERSION_URL` never runs a train at all, so
   its lead time still ends at the merge, and the `gaps` entry names which
   projects are covered.
2. **`pr_state` transition history.** `ledgers` is keyed `(kind, key)`, so every
   conductor transition OVERWRITES the row: only the current state and its
   `since` survive, and READY→MERGED dwell cannot be read back. The
   approve→merged figure above asks the same question of the verdict artifact
   instead. Closing it properly is an additive `pr_state_hist` append from
   `mc_transition`.
3. **A restore clock.** Nothing links a revert or fix PR back to the merge it
   repaired; `restored_at` / `fix_pr` columns on `outcome_metrics` would.

## The review gate (SDLC item 2, 2026-08-29)

The tables above MEASURE. These two are the one place a measurement is allowed
to change what the fleet may DO, and only ever in the tighter direction.

| table | producer | what it is |
| --- | --- | --- |
| `review_gate` | `bin/review-tighten.sh` (hub, daily 05:45Z) | one row per repo, EVERY run: the trailing-window revert/reopen rate, the thresholds it was judged against, and the verdict |
| `review_gate_thresholds` | an operator (`bin/jobs-client.sh review-gate-threshold-set`) | `scope` = `*` or a repo slug; the four numbers that decide a park |

```
GET  /api/review-gate                 -> {gates:[...], thresholds:[...]}   (both, always, in one response)
PUT  /api/review-gate                 {repo, tightened, rate, bad, merges, window_days, tighten_rate, clear_rate, min_merges, threshold_scope, decision, evidence}
PUT  /api/review-gate/thresholds      {scope, window_days, min_merges, tighten_rate, clear_rate, note}
```

Three things to keep true when touching this:

**`review_gate` is not the switch.** The switch is a `pause_flags` row named
`review-tighten-<repo>` (`bin/jobs-client.sh` `review_tighten_flag_name`),
because that rail already write-throughs to a file on every box and
`bin/merge-sweep.sh` / `bin/merge-queue.sh` already read flags that way. So a
parked repo STAYS parked through a worker outage, and there is exactly one
answer to "is this repo tightened". These rows are the detector's record — the
evidence behind the switch, read by the console and by nothing that merges.

**The gates and their thresholds travel together.** `GET /api/review-gate`
returns both halves in one response on purpose: fetched separately they could
come from different seconds, and a rate rendered beside a threshold it was never
judged against is the one way the `/outcomes` screen could lie.

**Thresholds are validated at the write, not clamped.** An inverted pair
(`clear_rate > tighten_rate`) would flap a repo in and out of the park on
alternate runs; a `tighten_rate` of 0 would park the entire fleet on the first
run. Both are 400s. A threshold silently corrected is a threshold nobody knows
the value of. `bin/review-tighten.sh` carries the documented code fallback for
an empty table: 14 days, 5 merges, tighten at 20%, clear at 10%.

## Lane liveness (2026-08-30)

**The incident.** Project `project-7` on box `box-project-6-1` lost every
one of its crons at 05:17 (a daily crontab re-apply from a stale repo file) and
the lane was silent for **ten hours**. Nothing alerted, and nothing could have:

- the box kept pinging the watchdog — it still ran its *other* lane, so layer 1
  was right to stay quiet;
- the hub kept pushing fleet status, and `triage_log_age_min` went stale in a
  field nothing pages on;
- `bin/jobs-watchdog.sh` ages rows that exist, and a lane that never ticks never
  claims a job, so there was no row to age.

Every detector we had watched work that HAPPENED. The missing fact was an
**absence**: "this lane should tick six times an hour and did not tick at all."

**The fix is an expectation, not another detector.** `lanes` (see `schema.sql`)
holds one row per `(project, box)` — the unit `fleet.conf` declares and the unit
a crontab loses. Two writers, disjoint columns:

| writer | what it writes | where |
|---|---|---|
| hub, every 10 min | `cadence_min`, `offset_min`, `expected_since`, `retired_at` | `bin/fleet-status-push.sh` → `lanes_expect` → `PUT /api/lanes` |
| box, every tick | `last_tick_at`, `last_tick_kind` | `bin/run-triage.sh` → `lane_tick` → `POST /api/lanes/tick` |
| hub watchdog, every 5 min | `alerted_at` | `bin/jobs-watchdog.sh` → `lane_alert_set` → `PATCH /api/lanes/alert` |

A box therefore cannot enrol itself and a hub push cannot fake a heartbeat.

**A lane tick is NOT a job heartbeat.** `job_heartbeat` beats a *claim* that
exists, every ~150s while it works. `lane_tick` records that a *cron fired*,
once per tick, whether or not it claimed anything — including the gate `SKIP`
that is the normal shape of a quiet board and claims nothing and spends nothing.
That is precisely the fact the job ledger cannot carry.

**Staleness is derived, per lane:** three missed ticks, floored at 30 minutes
(`LANE_STALE_TICKS` / `LANE_STALE_FLOOR_S` in `src/index.js`). The threshold
rides on every row the API returns, so `bin/jobs-watchdog.sh` and Mission
Control judge a lane by the same number and cannot drift apart. A lane that has
**never** ticked is aged from `expected_since` instead — the incident's twin, a
box whose crons never landed at all — and its alert says which shape it is.

**It pages once.** `alerted_at` is the latch, in the DB rather than a file on the
hub, because a file could do the dedupe and never the recovery — and would
forget even the dedupe on a hub rebuild, which is exactly when a lane is most
likely to be missing its crons. Clearing the latch is what emits `LANE RESUMED`.

### API

```
GET   /api/lanes            -> { lanes: [ ...decorated ], as_of }
GET   /api/lanes?stale=1    -> only the lanes an alert would be about
PUT   /api/lanes            { lanes: [{project, box, cadence_min, offset_min}], actor }
                            -> { expected, retired }   (an EMPTY array is a 400)
POST  /api/lanes/tick       { project, box, kind }     -> { lane }
PATCH /api/lanes/alert      { project, box, alerted }  -> { lane }   (404 on no such lane)
```

Decorated fields: `state` (`live` | `stale` | `pending` | `unexpected` |
`retired`), `stale`, `tick_age_s` (null when never ticked), `silence_s`,
`stale_after_s`, `expected`, `never_ticked`.

`PUT` is idempotent by design — it runs every 10 minutes and must be a no-op
when nothing changed. Lanes dropped from `fleet.conf` are **retired, never
deleted**, and an empty expected set retires nothing: an unreadable or
mid-rsync `fleet.conf` must not be able to un-watch the fleet. (`lanes_expect`
refuses to send an empty array too, so that takes two independent failures.)

### Rollout

1. `npx wrangler d1 execute harness-jobs --remote --file=./schema.sql` — creates
   `lanes`; additive and re-runnable, no existing table touched.
2. `npx wrangler deploy` — the four routes above. Nothing calls them until the
   boxes sync, so the deploy is inert on its own.
3. `bin/update-runners.sh` on the hub and every watcher box (the usual bin sync):
   `bin/jobs-client.sh`, `bin/run-triage.sh`, `bin/fleet-status-push.sh`,
   `bin/jobs-watchdog.sh`. **No crontab change** — every piece rides a cron that
   already exists (`fleet-status-push` */10, `jobs-watchdog` */5, `run-triage`
   per lane).
4. Deploy the console (Pages) for the LANES table. The proxy needs no change:
   `/api/coord/lanes` is a GET, which `functions/api/coord/[[path]].js` already
   allows.

**What the first hour looks like.** The hub's first push declares the expected
set; lanes read `pending` until their first tick lands (up to 10 minutes) and
would only page after the 30-minute threshold — so a box that is synced but
whose crons are genuinely missing pages roughly half an hour in, which is the
intended behaviour and worth watching for on rollout day. Boxes not yet synced
tick nothing: expect `pending` → `stale` for those until step 3 reaches them, so
sync the boxes in the same window as the worker deploy.

## The pre-claim build queue (2026-09-10)

Every table above models a job from the moment a box **claims** it. The wait
before that — "this ticket is buildable, somebody run it" — was a directory:
`state/build-queue/<project>/<KEY>.json`, written by `bin/run-build.sh`'s
QUEUED_FLY branch and pulled to the hub by `bin/fly-dispatch.sh` **over tailnet
ssh**. Three costs came out of that, and `build_queue` removes all three:

- the hub needs ssh into every box for the fly pool to see any work at all;
- a queued build is invisible to Mission Control until it is claimed, so "why
  has TK-109 not started" is answerable only by ssh;
- two things called "waiting" — the file queue and the jobs table — with nothing
  reconciling them.

**Keyed on `(project, ticket_key)`, which is exactly the file queue's identity.**
`ticket_key` is the board KEY (`TK-109`) — the filename, the argument
`run-build.sh` is invoked with, and the thing a human reads in a log line. The
board's internal `ticket_id` rides along because the launch needs it; it is not
identity.

### API

```
POST  /api/queue        { project, key, ticket_id, target, attempt, requested_by, meta }
                        -> 201 { queued, duplicate:false }
                        -> 200 { queued, duplicate:true, reason }   (already queued OR claimed)
GET   /api/queue?project=&status=&target=&key=&limit=   -> { queue: [ ... ], as_of }
      ?stale_min=N         rows CLAIMED longer ago than N minutes
      ?reason_deferred=1   rows whose reason says the build STOOD DOWN
POST  /api/queue/claim  { project, box, target?, key? }
                        -> 200 { queued, claimed:true }
                        -> 404 { error:"nothing queued" }           (a REAL answer)
                        -> 409 { refused:true, scope:"queue" }      (lost the race)
PATCH /api/queue        { project, key, status, reason }  -> { queued }   (404 on no such row)
```

Statuses: `queued | claimed | done | failed`, checked against `QUEUE_TRANSITIONS`
the same way jobs and phases are — an unknown TARGET status is a 409, an unknown
SOURCE may still move.

**The claim is a compare-and-swap.** The read picks a candidate; the `UPDATE`
only lands `WHERE ... AND status='queued'`, and SQLite reports what it actually
changed, so the second dispatcher ticking in the same second learns it lost
instead of building the same ticket. `mv` gave the file queue this on one box
and never across two — which is precisely why the hub had to hold the queue.

**An empty queue is a 404, not an error.** `bin/jobs-client.sh` turns it into
rc 2 and does not burn the daily unreachable-worker alert on it. "Nothing to
build" is the normal shape of a quiet project every single tick, and a caller
must be able to tell it from "the coordination DB is down" (rc 1), which is the
one case that should fall back to reading a directory.

**`?reason_deferred=1` is the deferral class, defined in one place** (added
2026-09-11). `bin/run-build.sh` writes `BUILD_DEFERRED` and exits 3 for "not
now, not a failure", and a concurrency rule's `REFUSED <scope> ::` arrives
BEFORE any job row exists — so a row closed carrying one of those describes a
build that never ran, and nothing in the jobs table can see it. `bin/fly-pool.sh`
used to file exactly those as `done` (project-5 TK-268/TK-270, project-4 TK-1515/
1566/1571/1576, project-3 TK-131/TK-139, project-2 TK-232), and the ticket was never
offered again. `bin/jobs-watchdog.sh` sweeps this filter and re-queues them; it
matches `reason LIKE 'BUILD_DEFERRED%' OR reason LIKE '%REFUSED%'`. The filter
exists because this page is oldest-first and capped: once the table holds a page
of finished builds, an unfiltered scan would never reach today's deferral.

**Enqueue is idempotent on the pair, including while CLAIMED.** `run-build.sh`,
the fly requeue and a triage relaunch all enqueue the same key; a second entry
is a second build. Re-enqueueing a key that is `queued` or `claimed` writes
nothing. Re-queueing a `done`/`failed` row is a real new attempt and continues
the attempt counter rather than restarting it.

### Client

`bin/jobs-client.sh`: `queue_put`, `queue_list`, `queue_claim`, `queue_done`,
`queue_release` (verbs `queue-put`, `queue-list`, `queue-claim`, `queue-done`,
`queue-release`). All fail-open: nonzero and silent on an outage.
`queue_list [project] [status] [target] [deferred]` prints ten tab-separated
columns — project, key, ticket_id, status, target, attempt, claimed_by,
enqueued_at, reason, meta — with the reason and meta flattened to one line.
Columns 9 and 10 were APPENDED, never inserted: every existing reader indexes
1-8 positionally. `meta` is where a fly requeue keeps `deferrals`, the
stand-down count, which is deliberately NOT `attempt`: `attempt` counts DEATHS
(`bin/fly-pool.sh` parks a machine that died twice on it), and spending it on
stand-downs parked tickets that had never failed.

### Rollout

1. `npx wrangler d1 execute harness-jobs --remote --file=./schema.sql` — creates
   `build_queue`; additive and re-runnable, no existing table touched.
2. `npx wrangler deploy` — the four routes above. **Inert on its own**: nothing
   calls them until the boxes sync, and the table ships empty.
3. `bin/update-runners.sh` for `bin/jobs-client.sh`. No crontab change.
4. The console needs no proxy change to READ it: `functions/api/coord/[[path]].js`
   already allows any GET, so `/api/coord/queue` works the moment the worker is
   deployed.

**The file stays the queue** until the producers and readers move (a separate
change). This one adds rows nobody reads yet, on purpose.

## The artifact feed (2026-09-10)

```
GET /api/artifacts?kind=&project=&job_kind=&since=&limit=
   -> { artifacts: [ { job_id, artifact_kind, artifact_ref, detail, actor,
                       updated_at, project, ticket_id, job_kind, box, status } ], as_of }
```

The reverse of `GET /api/jobs/:id/artifacts`: not "what did this job produce"
but "which builds of this project produced an artifact of this kind, anywhere in
the fleet". It is what replaces a RESULT arriving by scp — the owning box asks
for the results rather than waiting to be handed them.

`since` is an EXCLUSIVE watermark (`a.updated_at > ?`), so a sweep passing back
the newest `updated_at` it saw does not re-read that row on every tick. The
CLOCK is the server's, the only one every box agrees on.

**The `box` column is load-bearing**, not decoration: `bin/run-build.sh` records
a `result` artifact on EVERY box, so a sweep that did not skip its own would
stage a second copy of a close-out it has already posted. Client-visible.

Client: `bin/jobs-client.sh job_artifact_feed <kind> <project> [since] [limit]`
(verb `artifact-feed`), TSV `job_id, ref, box, ticket_id, updated_at, detail` —
`detail` last because it is the only field that can be long.

## The merge queue (2026-09-10)

```
POST  /api/merge-queue   { project, pr, repo, reason, enqueued_by }
                         -> 201 { merge, duplicate:false }
                         -> 200 { merge, duplicate:true }    (already `queued`)
GET   /api/merge-queue?project=&status=&limit=  -> { merge_queue: [...], as_of }
PATCH /api/merge-queue   { project, pr, status, reason }  -> { merge }   (404 if absent)
```

Statuses: `queued | blocked | landed | dropped`, checked against
`MERGE_TRANSITIONS`. `dropped` is the fourth beyond the three the brief named —
a PR dequeued because it is no longer OPEN has not landed and nothing is
blocking it, and recording that as `landed` would put a lie in the one ledger a
merge decision reads. `blocked` is re-queueable, which is fidelity to
`bin/tier2-merge-sweep.sh` (it tests `<num>`, never `<num>.blocked`).

List order is FIFO by `enqueued_at` — the order `ls -tr` gave the directory. A
queue that reorders landings is a different queue.

**NOT A DONE-LIST.** "Has this PR already merged" stays the `ledgers` row
(`kind=merge`) and nothing else; `status=landed` is a queue state, not a merge
fact. A second copy would drift, and the copy that drifts is the one that merges
something twice.

Client: `merge_queue_put` / `merge_queue_list` / `merge_queue_set` (verbs
`mq-put`, `mq-list`, `mq-set`).

## The wake feed (2026-09-12)

`docs/EVENTS.md` is the whole story — this is the API surface only.

| Route | Auth | What |
|---|---|---|
| `POST /webhooks/github` | `X-Hub-Signature-256` HMAC over the RAW body, keyed on `GITHUB_WEBHOOK_SECRET` | Records that something changed on a repo: `{repo, kind, key}` and nothing else from the payload. Idempotent on `(repo, kind, key, minute)`; answers `duplicate: true` when the unique index held. `ping` -> 200 and no row. An event nobody owns -> 202 and no row. No secret configured -> **503**, never an open door. |
| `GET /api/wakes?since=&repo=&kind=&limit=` | bearer | With `since` (a row id) everything newer than that watermark, acked or not; without it, the unacked backlog. `ORDER BY id ASC`. |
| `POST /api/wakes/ack` `{ids:[…]}` | bearer | Marks the named unacked rows acked. Housekeeping for the backlog view — the loop's real guard is its own local watermark, so a failed ack can never make a lane run twice. |
| `POST /api/wakes/prune` `{days, limit?}` | bearer | Retention (BH-1267). Deletes rows with `at` older than `days`, oldest first, at most `limit` (1..5000, default 5000) per call; answers `{deleted, before, days, limit, capped, as_of}`. `days` is an integer 1..3650 with **no default** — absent, `0`, negative, fractional, a string or out of range is a 400 that deletes nothing. `capped: true` means the cap was hit and the backlog is not drained; the next daily call continues. |
| `POST /api/wakes/nudge` `{repo, key, reason, dedupe}` | bearer | The producer for a ticket GitHub never rings about (BH-2754), called by `bin/untriaged-wake.sh`. `INSERT OR IGNORE` one `kind=issue` row with `key` stored as TEXT, event `nudge:<reason>` and minute `nudge:<dedupe>`; answers `{inserted: 0\|1, as_of}`. `repo` is `owner/name`, `key` a JSON integer 1..1e9 (a string is refused), `reason` `untriaged` or `unblocked`, `dedupe` 1..64 chars of `[a-z0-9:#-]`. Anything else is a 400 that writes nothing. |

Client: `bin/jobs-client.sh wakes [since] [repo]`, `… wakes-ack <id>…` and
`… wakes-prune <days>`.
Consumer: `bin/wake-loop.sh` on the hub. **The cron lines stay the heartbeat** —
with no webhook, no secret, or this worker unreachable, no row is ever written
and every lane ticks on its clock exactly as it did before this shipped.

Extra secret for this feature, set once and never committed:

```bash
npx wrangler secret put GITHUB_WEBHOOK_SECRET    # paste at the prompt
```

## Alerts table (2026-09-19)

Incident-aware alert state lives in `alerts`. This slice only ships the table,
its worker self-create mirror, and the thin client wrappers; the lanes that
actually read and write it are siblings. With the box-level `flags/alerts-db`
file absent, nothing calls any of this.

Table `alerts`:
- `id TEXT PRIMARY KEY` — the alert-state id: explicit `--id`, else `alert_state_key(line)`; identity, never `family`.
- `family TEXT` — `bin/alert_family.py family <line>`, a grouping key.
- `box TEXT` — box that produced the latest sighting.
- `project TEXT` — `''` = fleet-wide.
- `line TEXT` — latest line, stamp-stripped, `<= 2000` chars.
- `severity TEXT` — `info | warn | critical`.
- `first_seen TEXT NOT NULL`, `last_seen TEXT NOT NULL`.
- `count INTEGER NOT NULL DEFAULT 1`.
- `state TEXT NOT NULL DEFAULT 'new'` — `new | quarantined | triaged | parked | resolved`.
- `claimed_by TEXT` — `<lane>@<box>`, `NULL` = unclaimed.
- `claimed_at TEXT`, `notified_at TEXT` (last send anywhere, `NULL` = never).
- `component TEXT` (BH-6971) — the component that owns the alert, from `catalog/components.tsv` through `bin/component-of.sh`, or `unowned`. `NULL` = not stamped yet. An ADDED column (`ADDED_COLUMNS.alerts` in `src/lib/core.js`), never backfilled by the worker; `bin/alerts-groom.sh` stamps it.

Indexes: `idx_alerts_state (state, claimed_at, first_seen)`, `idx_alerts_family (family, last_seen)`, and `idx_alerts_component (component, last_seen)` (BH-6971, `ADDED_INDEXES.alerts`, created right after the column; it serves `component=` and `unstamped=1` below).

Allowed state edges (PATCH `/api/alerts/state` rejects everything else with `409`):
- `new -> quarantined`
- `new | quarantined -> triaged`
- `new | quarantined | triaged -> parked`
- `quarantined -> new` (a flush delivered; this edge sets `notified_at`)

`resolved` is reached only through `POST /api/alerts/resolve`; a note on a resolved
row starts a **new** incident (`count = 1`).

Settings rows (read by the worker with the code fallback next to the read):
- `alert_flush_ttl_s` = 2700
- `alert_claim_lease_s` = 900

### API (bearer `HARNESS_SECRET`; every response carries `as_of`)

| Route | What |
|---|---|
| `POST /api/alerts/note` `{id, family, box, project, line, severity, state?, reminder_s?, close_s?}` | 200 `{alert, decision: fire\|remind\|suppress, as_of}`. `id` `/^[A-Za-z0-9_.-]{1,120}$/`, `family` `/^[0-9a-f]{12}$/` or `''`, `severity` in `info\|warn\|critical`, `reminder_s`/`close_s` ints `60..604800` (default 21600), `state` in `new\|quarantined`. Compare-and-swap. |
| `PATCH /api/alerts/state` `{id, state, actor}` | 200 `{alert}` or 409 on a disallowed edge. |
| `POST /api/alerts/resolve` `{ids:[...]}` | 200 `{resolved:int, rows:[{id,count,severity,first_seen}], as_of}` — rows that MOVED, from the same `UPDATE ... RETURNING`, sorted by id; an unknown or already-resolved id counts 0, is not in `rows` and is not an error. No actor is recorded (the table has no column for one). |
| `POST /api/alerts/claim` `{lane, box?, state, min_age_s?, limit?, ids?}` | 200 `{alerts:[...], truncated:bool, as_of}`. `claimed_by` is `<lane>@<box>` when `box` is sent (`/^[A-Za-z0-9._-]{1,64}$/`, else 400) and the bare `lane` when it is not — send the box, or `GET /api/alerts/families?lane=` can never match the claim. `limit` defaults to 50 and clamps to 200; oldest first (`first_seen ASC`); `ids` at most 99. |
| `POST /api/alerts/flush` `{box?}` | 200 `{alerts:[...], truncated:bool, as_of}` — at most 200, oldest first. |
| `GET /api/alerts?id=&state=&family=&box=&older_than=&since=&limit=&component=&unstamped=` | 200 `{alerts:[...], truncated:bool, as_of}`. `limit` defaults to 200 and clamps to 500; most recently seen first (`last_seen DESC, id ASC`). BH-7802: `?id=<id>` (`/^[A-Za-z0-9_.-]{1,120}$/`, else 400; empty is no filter) returns that one row in any state, by primary key. BH-6971: `component=<name>` (`/^[a-z][a-z0-9-]{0,63}$/`, else 400) returns only that component's rows; `unstamped=1` returns only rows with no component (any other value is 400); both together is 400. `group=family` and `/api/alerts/families` take the same filter. |
| `POST /api/alerts/component` `{stamps:[{id, component}]}` | BH-6971. 200 `{stamped:int, as_of}`: `stamped` is the rows that CHANGED. 1..200 stamps, else 400 (refused, never sliced); an id twice is 400. Writes `component` only `WHERE id=? AND component IS NULL`, so a set component is never overwritten and no other column is touched. |
| `GET /api/alerts/families?lane=&claimed_since_s=` | 200 `{families:[{family,last_claimed_at,n}], as_of}`. |

### Client (`bin/jobs-client.sh`)

- `alert-note <id> <family> <box> <project> <severity> <line> [reminder_s] [close_s] [state]` — prints `<decision> <count>`.
- `alert-state <id> <state> [actor]` — prints `1` when the row came back in the state that was asked for, `0` otherwise. A 404 or a disallowed edge is an rc (2 / 9), never a printed `0`.
- `alert-resolve <id>...` — one request, prints the worker's `resolved` count. `0` is a real answer, never an error.
- `alert-claim <lane> <state> [min_age_s] [limit] [id...]` — sends `box: $JOBS_BOX`, so a bare `<lane>` is claimed as `<lane>@<box>`; a `<lane>` that already carries an `@` is sent as-is (the worker composes only what it is given, so sending both would double the box).
- `alert-flush [box]`
- `alerts [--state s] [--family f] [--box b] [--older-than s] [--since s] [--limit n] [--component c | --unstamped]`
- `alert_components_stamp` (sourced function, BH-6971) — stdin `<id>\t<component>` lines (`bin/component-of.sh --batch` output); POSTs `/api/alerts/component` in chunks of 200 and prints the sum of the worker's `stamped` counts. A failed chunk returns its rc and prints what the chunks before it stamped.
- `alert-families <lane> <claimed_since_s>`

List outputs one TSV row per alert: `id family box project state count first_seen last_seen claimed_by claimed_at notified_at severity line`, with `line` LAST. A final line `#truncated` is printed when the worker says `truncated:true`. `box` defaults to `$JOBS_BOX`. `actor` has NO default: `alert-state` sends it only when the caller passes one, and `alert-resolve` never sends one — a sibling that wants attribution passes `<lane>@$JOBS_BOX` itself.

`alert_families` prints TSV: `family last_claimed_at n`.

`alerts_db_on()` in `bin/lib/alert-state.sh` is the one gate every script tests
before making any `/api/alerts*` call.

### Rollout

1. `npx wrangler deploy` (the `CREATED_TABLES.alerts` mirror makes the manual `d1 execute` step optional).
2. After every child of this split has merged, flip the box flag: `bin/jobs-client.sh flag-set alerts-db on`.
   `flag-set` writes the D1 row and touches `flags/alerts-db` **on the box it runs on**; every other box
   materializes that file only when something there calls `flag_active alerts-db`. BH-1070 adds that call to
   `bin/poll-commands.sh`, so once it has landed the fleet picks the flag up within a poll — until then run
   step 2 on each box, or beat/flush/digest stay on the file path there with nothing to say so.

## conductor_held_pages — the merge conductor's held pages (BH-1201, contract chunk BH-1381)

One row per HOLD, not per PR: the key is `(repo, number, state, head, kind)`, so a
PR whose head moved or whose state changed is a new hold with its own age, and a
PR held for two reasons carries two rows. `first_held_at` is the age and never
moves on re-sighting; `last_seen_at` is the liveness. `mode` records the conductor
MODE word in force when the hold was taken, so a reader can tell a hold taken
under `kill-switch` from one taken under `merge`.

The table self-creates through `ensureTable` (`CREATED_TABLES.conductor_held_pages`)
and is also in `schema.sql`, which `bin/harness-sync.sh` applies statement by
statement before `wrangler deploy`. Nothing writes it yet — the conductor child of
BH-1201 is what starts publishing.

Settings rows this contract publishes (written by `conductor_mode_publish`, absent
until the conductor child ships — readers see `unknown`, which HOLDS):
- `merge-conductor.mode` — one of `merge|actions|observe|kill-switch`
- `merge-conductor.held_pages` — the tick's summary, e.g. `12 STUCK=5 BUDGET=7`, or `0`

### API (bearer `HARNESS_SECRET`; none of these is in `OPEN_ROUTES`)

| Route | What |
|---|---|
| `PUT /api/conductor/held` `{repo, number, state, head, kind, text, mark?, mode}` | 200 `{ok:true}`. Upserts on the PK: a re-sighting refreshes `text`/`mark`/`mode` and bumps `last_seen_at`, and **never** moves `first_held_at`. 400 on a malformed field: `repo` `/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/`, `number` a positive integer (a string or a fraction is refused, not truncated), `state` one of the 14 `MC_STATES` words, `head` 1..64 chars, `kind` `STUCK\|BUDGET`, `text` 1..2000 chars, `mode` `merge\|actions\|observe\|kill-switch`. An absent or empty `mark` stores NULL. |
| `GET /api/conductor/held?limit=N` | 200 `{rows:[...], n_total}` ordered `first_held_at ASC, repo, number` — oldest hold first, the one a human is asked about first. `limit` is the documented default of 100 when the parameter is ABSENT; an integer out of range clamps into 1..500 (`0` and `-3` read as 1, `9999` as 500); a present-but-non-integer value (`limit=abc`, `limit=1.5`, a blank `limit=`) is a **400**, not a silent default (D11 — a reader with a bug must not be handed a 100-row page that reads as the whole table). `n_total` counts the WHOLE table, not the page. |
| `POST /api/conductor/held/release` `{repo, number, state, head, kind, why}` | 200 `{released: 0\|1}`. Deletes exactly that one row. `why` is **required** (a string, 1..2000) and is validated but not persisted: a release is the one destructive verb here, so the reason is demanded from the caller that already knows it. An absent or empty `why` is a 400 that deletes nothing. A release of an absent row is `{released:0}`, never a 404 — a 404 reads as "not deployed" to a fail-open client. |

### Client (`bin/jobs-client.sh`)

- `conductor-mode-publish <mode> <held-summary>` — writes the two settings rows above; the summary is truncated to the settings 256-char limit.
- `held-page-put <repo> <num> <state> <head> <kind> <text> <mark> <mode>`
- `held-pages-list [limit]` — TSV `repo num state head kind text mark mode first_held_at last_seen_at`, oldest first, `text` tab/newline-escaped.
- `held-page-release <repo> <num> <state> <head> <kind> <why>` — prints the `released` count. An empty `<why>` is refused by the client itself (rc 1, no request), so the caller gets a refusal rather than a 400 the fail-open contract would flatten into "the worker is down".

Every verb returns `_jobs_req`'s rc verbatim (the fail-open contract in `bin/lib/jobs/req.sh`).

### The reader helper (`bin/lib/conductor-mode.sh`)

`conductor_mode` prints exactly one of `merge|actions|observe|kill-switch|unknown`,
read from the `merge-conductor.mode` settings row through the existing 60 s cache.
It never tests a flag file. `unknown` HOLDS: fail closed on spend, and a hold is
not a drop — the line is re-offered next tick.

## reconcile-prs owner + memory (BH-1595, contract chunk BH-1607)

Two tables in `schema.sql`, applied by `bin/harness-sync.sh` before deploy like
every other worker table: `reconcile_owner_beat` (one row per lane, seeded with
`lane='reconcile-prs'` and `beat_at` NULL) and `reconcile_memory` (the lane's
per-kind watermarks, `kind` one of `terminal|open|gone`, keyed `(kind, name)`).
`reconcile_memory` is read and written by the two memory routes below (BH-1610).

### reconcile-prs owner + memory (BH-1595)

Bearer `HARNESS_SECRET`; none of these is in `OPEN_ROUTES`.

| Route | Answer |
|---|---|
| `POST /api/reconcile-prs/beat` | stub: 501 `{error:"not implemented"}` until its BH-1595 sibling lands |
| `GET /api/reconcile-prs/owner` | stub: 501 `{error:"not implemented"}` until its BH-1595 sibling lands |
| `PATCH /api/reconcile-prs/owner/alert` | stub: 501 `{error:"not implemented"}` until its BH-1595 sibling lands |
| `GET /api/reconcile-prs/memory` | 200 `{rows:[{kind,name,value,updated_at}], truncated, as_of}`, ordered by `kind,name`, at most 5000 rows; `truncated` is true only when a 5001st row exists |
| `PUT /api/reconcile-prs/memory` | body `{upserts:[{kind,name,value}], deletes:[{kind,name}]}`, both optional; at most 500 entries. `kind` is `terminal\|open\|gone`, `name` is `[A-Za-z0-9._-]{1,128}` and not dots only, `value` a non-empty string of at most 4096 chars. Any bad entry is 400 for the whole body, nothing written. Otherwise ONE `DB.batch` (deletes, then upserts): `open` only ever moves forward (`WHERE excluded.value > value`), `terminal`/`gone` overwrite. 200 `{ok, upserts, deletes}` |

On the box, `bin/reconcile-prs.sh` calls `rcr_owner_beat`
(`bin/lib/reconcile-owner-beat.sh`) once per tick after it takes the reconcile
flock, and `rcr_memory_flush` (`bin/lib/reconcile-read.sh`) once per tick;
`rcr_tick_begin` calls `rcr_memory_hydrate` (GET) at tick start. Both memory
calls fail open: a failed GET or PUT is one line in `logs/reconcile.log` and
the tick runs on the box's own files.
