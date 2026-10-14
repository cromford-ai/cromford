# A missing D1 table is an answer now, the configured hub fails open, and the schema applies before the deploy

Doc: HUB-THINNING-PLAN

On 2026-09-19 the hub ran no cron lane at all between 18:31 and 19:00Z, and
nothing paged. The chain: #785 rendered 52 hub-only lanes behind
`bin/hub-lease.sh check && `, and shipped the `hub_lease` table in
`worker/jobs/schema.sql` — which nothing applies. The worker deployed in
minutes. Every lease read threw `no such table: hub_lease`, Cloudflare turned
the uncaught throw into a bodiless HTTP 500 (error 1101), `bin/jobs-client.sh`
mapped a bodiless 500 to rc 1 ("unreachable"), and `cmd_check` exited 1 — with
no cache, so no grace, and with no alert either, because the old code alerted
only when a cache existed ("no cache = no claim to alert about"). Twenty-nine
minutes of 52 lanes skipping, reported nowhere. The console showed
`hub: holder null, epoch null`, which reads as a blank, not as an alarm.

The same hand-step gap had been running longer on a second table: `GET
/api/settings/<key>` had answered 500 for three weeks, so every knob reader in
the fleet was silently on its code default (the operator, 2026-09-19 20:11Z).

## What changed

**`worker/jobs/src/lib/http.js` — `d1Guarded(table, fn)`.** The three
`/api/hub/lease*` routes and the three `/api/settings*` routes have their whole
bodies wrapped. A throw matching `no such table` answers
`503 {"error":"<table> schema not applied", detail}`; any other D1 throw answers
`503 {"error":"<table> unavailable", detail}`. The split is narrow on purpose:
telling an operator to apply a schema that is already there, because the real
problem was a lock, costs them the whole search. The validation 400s sit above
the first statement and still answer 400 without touching D1.

**`bin/lib/jobs/req.sh` — `JOBS_BODY`.** `_jobs_req` and `_jobs_req_file` now
hand the payload back beside `JOBS_HTTP`, both cleared at the top of every
request so an empty `JOBS_HTTP` still means "never answered" and can never be
the previous call's status. rcs are untouched: 0 / 9 / 2 / 1 as before.

**`bin/hub-lease.sh` — the reason, and fail-open.** `renew` and `check` run
`_jobs_req` through a temp file instead of `$(...)`, because a command
substitution is a subshell and was discarding both variables; the failure line
now reads `http=503 {"error":"hub_lease schema not applied",...}` instead of
"worker unreachable". And `cmd_check` fails OPEN when all of these hold: rc 1
(never rc 2, a 404 — that means the worker is not deployed and that box has no
business running hub lanes), this box is the configured hub (`hub_box_name`),
`HUB_LEASE_FAIL_OPEN` is not 0, and no cached row says another box holds the
lease. Past `HUB_LEASE_PAGE_S` (600 s) it calls
`bin/lane-alert.sh --critical --id hub-lease-check-failing`, repeating at most
once per `HUB_LEASE_ALERT_REPEAT_S` (3600 s), and resolves that id on the first
2xx. Two per-box files carry the state: `state/hub-lease-failing-since` (the
outage's start, back-dated to the cache's `fetched_at` so an outage that already
burned its grace pages on the first tick rather than ten minutes later) and
`flags/alerted-hub-lease-unreachable`, which now holds the epoch of the last
page — an EMPTY file, which an older fail-closed outage left behind, reads as 0
and therefore as "never paged", never as "already handled".

The split-brain trade-off, which is the reason this is loud rather than quiet: a
single configured hub whose worker is unreachable keeps running its own lanes,
so the fleet does not stop; a second box could only become hub by renewing or
being promoted through that same unreachable worker, so no second hub can appear
during the outage; the cost is that a `promote` issued during the outage is not
seen until the worker answers again.

**`bin/fleet-status-push.sh` — `.hub.lease_alert`.** The snapshot's `hub` block
gains a ninth key, `null` when the lease cache is fresh and held, otherwise a
plain string (`holder null`, `lease stale (age <n>s, holder <h>)`,
`lease age unknown (holder <h>)`). A renderer that showed a blank holder as
"fine" now has text. While it is non-null the script raises a `warn` lane-alert
(`--id hub-lease-fleet-status`) and resolves it when it clears — warn, not
critical, because the page for this outage belongs to `check` and a second DM
for one incident is noise.

**`bin/harness-sync.sh` + `bin/lib/d1-schema.sh` — the apply stops being a hand
step.** The `# >>> d1 schema apply` block applies each worker's `schema.sql` to
its D1 database before `wrangler deploy`, statement by statement, sourcing
`env/cloudflare.env`. `--command`, not `--file`: under the hub's OAuth
credentials `--file` answers `Authentication error [code: 10000]` while
`--command` works. The first failing statement writes ONE ALERTS line naming it
and SKIPS that worker's deploy with its stamp untouched, so the next
`update-runners.sh` run retries and code never runs ahead of its schema. Every
statement in the file is independently `IF NOT EXISTS` / `INSERT OR IGNORE`, so
a partial apply is consistent and re-applying is free —
`tests/schema-additive.bh-1000-test.sh` keeps it that way.

The apply is paid once per SCHEMA, not once per deploy: `state/worker-schema-applied-<name>`
holds the sha of the `schema.sql` blob that last applied cleanly, and an
unchanged blob logs `schema.sql unchanged (<sha>) — apply skipped, deploying`.
`bin/fleet-propagate.sh` runs `harness-sync.sh` under `timeout 300` on the `*/5`
path, and ~70 statements x one remote wrangler round trip re-run on every
`index.js` change is a live chance of being killed mid-apply — which would
leave the worker undeployed AND unstamped, write no ALERTS line (that one fires
only on a FAILED statement) and restart at statement 1 five minutes later,
forever. A `schema.sql` that is present but reads as zero statements is treated
as a broken read: ALERTS line, no deploy, no stamp.

**`rules/CLAUDE.md`** gains a dated pair of rules: a PR that adds an `&&` gate
in front of a lane proves the dependency live in production BEFORE merge, with
the probe in the PR body; and schema and knobs never ride a deploy as a hand
step.

## What this does NOT do

`hub_lease` and `settings` are deliberately not registered in the worker's
`CREATED_TABLES` self-create map (BH-658). That would also cure the symptom, but
the ticket chose the deploy-time apply as the mechanism, and putting `CREATE
TABLE` statements in front of the lease routes would send unmodelled statements
into `test/index.test.js`'s `hub_lease` fixture, which throws on them by design.

The four `hub-lease.sh` knobs are env + code default rather than `settings`
rows. That is a documented exception to the DB-driven-config rule: the database
the settings table lives in is the thing that is down when those knobs matter.

Verification of the apply itself is a HUB observation, not a builder one — a
build box holds no Cloudflare credential. The evidence is `schema.sql applied
(<n> statements)` in `logs/update-runners.log` immediately before `worker jobs
deployed`, on the first deploy-mode run after this merges.
