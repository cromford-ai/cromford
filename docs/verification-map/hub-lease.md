# Hub lease (who is the hub)

**What it is:** one D1 row — `hub_lease`, `id=1` by CHECK constraint — that says
which box currently holds hub-ness, until when, and at which `epoch`. Hub-ness
used to be a hostname in a conf file; after the hub wipe of 2026-09-15 it is a
lease a box has to keep renewing. `epoch` is the fencing token: every change of
ownership bumps it inside the same statement that writes `holder`, so a box
holding a cached epoch it has already lost gets a 409 instead of a renewal.
Expiry is judged by the SERVER's clock only — fleet boxes ran 66-464 s slow on
2026-09-14, so `expired` is computed against the worker's `t`, never a box's.

**How a user reaches it:** there is **no UI route** — no console screen renders
the lease. Two ways in, both bearer-gated:

- from a box, the merged client: `bin/hub-lease.sh renew|check|promote`
  (it calls the `/api/hub-lease*` spellings, which these routes also answer)
- directly:
  `curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/hub/lease"`

**The primary lane** is `cron/hub.cron`: one ungated line,
`* * * * * /root/harness/bin/hub-lease.sh renew >/dev/null 2>&1`, is the only
cron lane anywhere in the fleet that writes the lease (the other writer is a
human running `promote`), and it bootstraps an empty table on its first tick
(rung 3, the `INSERT` — no human promote at rollout). The hub-only lines in
that file sit inside `# BEGIN hub-lanes` / `# END hub-lanes`
blocks and are rendered with `/root/harness/bin/hub-lease.sh check && ` in front
of their commands, so they fire only on the box that currently holds it. A box
that lost the lease — or lost its own `bin/`, where the missing script fails the
`&&` with rc 127 — runs zero hub lanes on its next tick.

**Key routes/screens:**
- `GET /api/hub/lease` (alias `/api/hub-lease`, any query string ignored) —
  ALWAYS `200 {lease, as_of}`. `lease` is `null` when no row exists, else
  `{holder, epoch, expires_at, updated_at, expired, remaining_s}`. Never a `404`
  for "no row": a `404` must uniquely mean "the worker is not deployed yet",
  which the client reads as unreachable. `expired` is `expires_at <= t` and
  `remaining_s` floors at 0.
- `POST /api/hub/lease/renew` (alias `POST /api/hub-lease`) —
  `{holder, epoch, ttl_s?}`. `holder` must match `[A-Za-z0-9._-]{1,64}`, `epoch`
  must be a non-negative integer, else `400`. `ttl_s` is clamped to [60, 900]
  and defaults to 180 s (the client renews once a minute, so two missed renews
  expire it). Four rungs, each ONE statement judged by `meta.changes` — no
  read-then-write, so two boxes racing cannot both be told they won:
  1. `UPDATE hub_lease SET expires_at=?1, updated_at=?2 WHERE id=1 AND holder=?3 AND epoch=?4 AND expires_at > ?2` → `200 {lease, renewed:true, as_of}`
  2. `UPDATE hub_lease SET holder=?1, epoch=epoch+1, expires_at=?2, updated_at=?3 WHERE id=1 AND expires_at <= ?3` → `200 {lease, taken:true, as_of}` (an expired lease is taken and the epoch bumps even for the same holder)
  3. `INSERT INTO hub_lease (id, holder, epoch, expires_at, updated_at) VALUES (1, ?1, 1, ?2, ?3) ON CONFLICT(id) DO NOTHING` → `200 {lease, taken:true, as_of}` (first lease ever: self-bootstrap, no human promote at rollout)
  4. else `409 {error:"lease held", lease, as_of}` and nothing was written.
- `POST /api/hub/lease/promote` (alias `POST /api/hub-lease/promote`) —
  RETIRED (BH-2272): `410 {error:"gone", use:"/api/hub/promote", detail, as_of}`
  on both spellings, before any D1 statement. It was an unguarded upsert (no
  setting, confirm, epoch, live-lease check or audit), and `bin/hub-lease.sh
  promote --holder X` sent it `{"holder":"--holder"}`. Moving the hub is
  `POST /api/hub/promote` (below); `bin/hub-lease.sh promote` calls it, and
  refuses a holder that is not the hub or a fleet.conf `# @standby` box.
  The epoch bump on that route is what fences the box being moved off: its
  next renew answers 409.

Every success re-reads the row after the write, so the response is what the
table holds rather than what the caller asked for.

**Selectors:** not applicable — no rendered screen. The observable surfaces are
the HTTP status and the response keys: `renewed` / `taken` / `promoted` /
`error:"lease held"`, and `lease.expired`, which is what
`bin/hub-lease.sh`'s `_is_held` decides on.

**How `check` decides, and the knob (BH-1023).** `check` has two modes, resolved
by `_epoch_check_on` without a request of its own: `HUB_LEASE_EPOCH_CHECK=1|0`
wins both ways — from the process environment first, then read out of `global.env`
in the harness env dir by `_epoch_check_env_file` (one anchored `sed` for that one
variable, never a `set -a` source of the file) — else the file
`flags/hub-lease-epoch-check`, else OFF. It ships OFF. The env-file read is what
makes the box-local kill switch real: every consumer is a bare crontab line that
sources no env file, so a variable read only by a CLI would never be seen on the
hub. It therefore accepts the spellings a hand-edited env file actually carries
during an incident — an `export ` prefix, leading indentation, a trailing
`# comment`, a trailing tab, a CRLF line ending — and resolves a variable
written twice to its LAST assignment, the way sourcing the file would, because
an incident edit is an append and a switch that READS as set and is not is worse
than no switch. A commented line, and any value that is neither `1` nor `0`, is
still not an override — the file decides, the same as unset — but a value that
cannot be resolved is LOGGED
(`knob: HUB_LEASE_EPOCH_CHECK=<v> ignored — neither 1 nor 0`) rather than
dropped in silence, including when a later source resolves the knob anyway. That
line is once per incident, not once per invocation: it is gated by
`flags/alerted-hub-lease-knob` the same way the unreachable ALERT is gated, and
the flag is removed as soon as the knob resolves cleanly, so the next bad value
is loud again. Ungated it would be one line per gated lane per minute (~53/min
on the hub) for as long as the typo stood.

- **OFF (dark, today's behaviour):** a cache younger than `HUB_LEASE_CACHE_S`
  (60 s) answers straight from `state/hub-lease.json`, no request. So a
  `promote` is invisible to the box that just lost the lease until its next
  `renew` gets a 409 — up to a minute of two boxes both running hub lanes.
- **ON:** a fresh cache that says `held=1` no longer short-circuits. `check`
  reads the row, and `held` additionally requires the row's `epoch` to still
  equal the CACHED one. Both sides normalize through the same
  `jq '(.epoch|tonumber?) // empty'`, so a `"1"` on the wire equals a cached
  `1`, and a row with no `epoch` is never equal. The cache is then written with
  the ROW's epoch, so the next `renew` sends the right fence.

Unchanged in both modes: a fresh cache that says `held=0` exits 1 with no
request (a non-holder never pays), and every unreachable-worker path keeps the
600 s grace for the CURRENT holder followed by one ALERT behind
`flags/alerted-hub-lease-unreachable` — a re-validation cannot compare against a
row it cannot read.

The flag FILE is driven by the `pause_flags` row of the same name: the ungated
`renew` line calls `_sync_epoch_flag` → `flag_sync hub-lease-epoch-check` before
each of its two ANSWERED exits (200 and 409), so it is the only lane that pays
for the knob (one GET a minute, hub only) and a console flip lands within a
minute. An unreachable renew skips the sync — that GET goes to the same worker
and can only fail too — and the next answered renew reconciles within a
minute. Fleet switch:
`bin/jobs-client.sh flag-set hub-lease-epoch-check on|off "BH-1023"` — turning
it off means setting the row inactive, never deleting it, because a 404 is
"nothing to reconcile" and leaves the file alone. `renew` caches the epoch the
server GRANTED, never the one it asked for.

**Preconditions / seed needs:** ONE step since BH-1000, and it is automatic.
`bin/harness-sync.sh` deploys a worker whose tree sha moved, and the block
marked `# >>> d1 schema apply` now applies that worker's `schema.sql` to its D1
database BEFORE `wrangler deploy` — statement by statement, sourcing
`env/cloudflare.env`, and it SKIPS the deploy (leaving the stamp untouched, so
the next `update-runners.sh` run retries) if any statement fails — and also if
the file is present but reads as zero statements, which is a broken read, not
an empty schema. Code cannot reach production ahead of its table.

The apply is paid ONCE PER SCHEMA, not once per deploy: `state/worker-schema-applied-<name>`
holds the sha of the `schema.sql` blob that last applied cleanly, written only
after every statement went through, and an unchanged blob logs
`schema.sql unchanged (<sha>) — apply skipped, deploying` and goes straight to
the deploy. That matters because `bin/fleet-propagate.sh` runs `harness-sync.sh`
under `timeout 300` on the `*/5` path: ~70 statements x one remote wrangler
round trip, re-run on every `index.js` change, is a live chance of being killed
mid-apply — which leaves the worker undeployed AND unstamped, writes no ALERTS
line (that one fires only on a FAILED statement) and restarts at statement 1
five minutes later, forever. Every statement is `IF NOT EXISTS` / `INSERT OR
IGNORE`, so a re-apply is a no-op and a half-applied schema still repairs itself.

**Since BH-1555 that kill does not start over.** A SECOND file,
`state/worker-schema-progress-<name>`, holds `<blob sha> <database> <baseline
blob sha|none> <statements done>` and is rewritten after every round trip that
D1 accepted — after the call returns 0, never before, so a kill in between
re-sends one idempotent statement rather than skipping one that never landed.
The next pass with the same key skips that many and logs `schema apply:
resuming at statement <k>/<m> (progress from a run that did not finish)`; a
progress file whose key does NOT match (the schema was edited again, another
database, another baseline) or whose count is out of range is deleted and the
apply starts from the top. It is removed on completion, immediately before the
stamp is written, so the two can never both claim to be the truth. Nothing to
do by hand either way.

**An edited definition of an object D1 already has pages (BH-1555).** In delta
mode a changed statement whose CREATE target (table / index / view / trigger)
also appears in the previous blob is an EDIT to a live object, and `CREATE ...
IF NOT EXISTS` is a silent no-op on D1 in that case: it is sent, it succeeds
and it changes nothing. The apply still sends it and still deploys — the schema
is additive by contract — and writes ONE ALERTS line per apply naming the
worker, the object(s) and each statement's ordinal in the whole file
(`schema.sql edits the definition of an EXISTING object`). A real change to an
existing object needs a new object or an explicit migration.

**Since BH-1538 an edit sends only what changed, several statements per round
trip, and never under the deploy lock.** With a stamp for the same database the
previous blob is read back out of git and only statements whose text is new are
sent (no stamp, another database, or a blob git no longer has: the full file).
They travel in chunks (`d1_chunk_bounds` in `bin/lib/d1-schema.sh`: under 60,000
bytes and 40 statements); a chunk that fails is re-sent one statement at a time
so the ALERTS line still names `statement N/M`, and a chunk refused where every
statement passes alone switches the rest of the apply to one per round trip and
logs `batched --command failed where every statement of it passed alone`.
Progress is logged per round trip (`schema apply: statement N/M on, R round
trip(s), Ss`), and an apply past `lane.fleet-propagate.harness_sync_schema_alert_s`
seconds (default 180, under fleet-propagate's `timeout 300`; checked after every round trip) writes one ALERTS line. The worker phase runs after
`locks/harness-sync.lock` is released, under `locks/harness-sync-workers.lock`:
a run that finds it busy deploys bin/ prompts/ catalog/ and leaves
`state/harness-sync-workers-pending` for the holder, which re-checks it after
releasing. Because that phase no longer excludes `git pull`, it works from an
immutable snapshot: each pass pins `HEAD`, `git archive`s that commit's
`worker/`, `catalog/` and lane composer into `state/worker-snap.*`, applies the
schema from it, deploys from it, and stamps that commit's key. A pull that
lands mid-deploy cannot put code live ahead of its schema (#1548 review C1,
pinned by B8 in `tests/harness-sync-d1-batch.bh-1538-test.sh`); the next pass
sees the new key and applies before it deploys. The snapshot also carries
`agent-core/`, which worker/jobs's staff routes import, and a worker that
imports it adds `-core-<sha>` to its key (BH-6687, pinned by
`tests/harness-sync-snapshot-agent-core.bh-6687-test.sh`). A failed
`wrangler deploy` ALERTs on the first failure, then at most once per
`lane.fleet-propagate.harness_sync_deploy_alert_repeat_s` seconds (default
3600) per worker per box while it keeps failing, with the failure count in the
line; a held failure is one `alert held` line in `update-runners.log`. The success line reads
`schema.sql applied (<n> statements; <r> round trip(s); full apply|delta vs <sha>) to <db>`.

`--command`, not `--file`, and that is not a style choice: under the hub's
OAuth credentials `wrangler d1 execute --file` answers
`Authentication error [code: 10000]`, while `--command` works. By hand on the
hub, the same shape:

```bash
set -a; . /root/harness/env/cloudflare.env; set +a
cd /root/harness-checkout/worker/jobs
npx --yes wrangler d1 execute harness-jobs --remote --yes --command "<one statement>"
```

If the table is nevertheless missing — a worker deployed before BH-1000, a
database reset — the routes no longer throw into a bodiless Cloudflare 500.
(The schema stamp is `<blob sha> <database name>`, so an edited schema and a
re-pointed binding re-apply by themselves; a D1 RESET under the same name does
not, because nothing the stamp can see changed. Recovery is one hand step on
the hub — `rm /root/harness/state/worker-schema-applied-jobs` — and the next
deploy-mode `harness-sync.sh` run re-applies every statement.)
They answer `503 {"error":"hub_lease schema not applied","detail":"<the D1
message, 200 chars>"}`, and the `/api/settings*` routes answer the same shape
for `settings`. A D1 failure that is NOT a missing table (a lock, a syntax
error) answers `503 {"error":"hub_lease unavailable"}` — the two are never
conflated, because "apply the schema" is the wrong instruction for a lock.
`bin/jobs-client.sh` still maps both to rc 1, but `_jobs_req` (in
`bin/lib/jobs/req.sh`, the module the shim sources) now hands the payload back in
`JOBS_BODY`, and `bin/hub-lease.sh` logs it verbatim (`http=503 {...}`) instead
of "worker unreachable". The table ships with no seed row on purpose: the first
renew bootstraps it. No new env var; `HARNESS_SECRET` and `JOBS_URL` are the
ones every box already holds, and `env/cloudflare.env` on the hub is the one the
deploy already used — its token must carry **D1 Edit**, or the apply fails and
the ALERTS line names the statement.

**Fail-open on the configured hub (BH-1000):** on 2026-09-19 `hub_lease` was
never applied, the worker 500'd, and `check` exited 1 with no cache — so every
gated lane on the hub skipped for 29 minutes in silence. Now, when `check` gets a worker
ERROR (rc 1: a 5xx or a transport failure — never rc 2, a 404, which means "not
deployed yet") and the asking box IS the configured hub (`hub_box_name`, i.e.
`HUB_BOX_NAME`, default `box-hub`) and no cached row says another box
holds the lease, it exits 0 and the lanes keep running. `HUB_LEASE_FAIL_OPEN=0`
restores the old behaviour.

The split-brain trade-off, stated in `bin/hub-lease.sh`'s header and here: a
single configured hub whose worker is unreachable keeps running its own lanes,
so the fleet does not stop; a second box could only become hub by renewing or
being promoted through that SAME unreachable worker, so no second hub can appear
during the outage; the cost is that a `promote` issued during the outage is not
seen until the worker answers again. That cost is why the condition is loud
rather than quiet: once the failure has lasted `HUB_LEASE_PAGE_S` (600 s) the
script calls `bin/lane-alert.sh --critical --id hub-lease-check-failing`, and
hands it to the alerter again at most once per `HUB_LEASE_ALERT_REPEAT_S`
(3600 s) — which is the FLOOR, not the rate: on a box that has
`bin/lane-alert.sh`, lane-alert suppresses repeats on an open `--id` and sends
one "still firing" reminder per `ALERT_REMINDER_S` (6 h), so one loud line an
hour is what the no-lane-alert fallback does. Two per-box files carry the
state: `state/hub-lease-failing-since` (the outage's start epoch, back-dated to
the cache's `fetched_at` so an outage that already burned its grace pages on the
first tick; a file that exists but cannot be read as a number is re-stamped with
NOW **on disk**, so a corrupt clock delays the page by one threshold instead of
silencing it forever) and `flags/alerted-hub-lease-unreachable` (the epoch of
the last page; an EMPTY file, which an older fail-closed outage left behind,
reads as "never paged"). The first 2xx clears both and sends one `--resolve`.

**A rotated secret is an outage, and it pages as one.** A `401`/`403` is an rc 1
like any other, so the configured hub fails OPEN on it and pages at 10 minutes
with `http=401 {"error":"unauthorized"}` in the message. That is deliberate: the
alternative — treating an auth failure as "you are not the hub" — stops all 52
gated lanes on the one box that is supposed to run them, silently, for as long
as nobody notices the secret. The status is in the page, so the operator is sent
to `HARNESS_SECRET` and not to the network. These four knobs are env + code default on purpose: the `settings`
table they would otherwise live in is in the same database that is down when
they matter.

**The snapshot says it out loud too:** `bin/fleet-status-push.sh` pushes
`.hub.lease_alert` — `null` when the cache is fresh and held, otherwise a plain
string (`holder null`, `lease stale (age <n>s, holder <h>)`,
`lease age unknown (holder <h>)`). A renderer that showed a blank `holder` as
"fine" now has text to show, and the script raises a `warn` lane-alert
(`--id hub-lease-fleet-status`) while it is non-null, resolving it when it
clears. Warn, not critical: the page for this outage belongs to `check`, and a
second DM for one incident is noise.

**Verify it works:** `cd worker/jobs && npm test` — W1-W9 in
`test/index.test.js` drive all three routes through the worker's real `fetch`
against a `hub_lease` fixture whose compare-and-swaps are evaluated for real
(stale epoch, wrong holder, expired takeover, bootstrap, promote fence, the
client's path spellings, the ttl clamp, and that `/api/hub/lease/nope` is still
`404 unknown endpoint`). `test/d1-guarded.bh-1000.test.js` drives the same
routes, plus all three `/api/settings*` routes, with a DB that THROWS, and pins
the 503 bodies, the `unavailable`-vs-`schema not applied` split, and that a 400
still answers 400 without touching D1.

The shell side, all runnable from a checkout with no live harness:

```bash
HARNESS_TEST_SANDBOX=1 bash tests/hub-lease.bh-1000-test.sh        # fail-open, the page, its repeat floor, the corrupt clock, and every negative
HARNESS_TEST_SANDBOX=1 bash tests/hub-lease-test.sh                # the renew/check/promote contract
HARNESS_TEST_SANDBOX=1 bash tests/jobs-client-body.bh-1000-test.sh # JOBS_BODY carries the worker's reason
HARNESS_TEST_SANDBOX=1 bash tests/fleet-status-lease-alert.bh-1000-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/harness-sync-d1.bh-1000-test.sh  # the apply runs before the deploy, and a failure skips it
HARNESS_TEST_SANDBOX=1 bash tests/harness-sync-d1-batch.bh-1538-test.sh  # delta + batched apply, per-statement fallback, lock released, slow-apply alert
bash tests/d1-schema-split.bh-1000-test.sh                         # the real schema.sql, applied statement by statement, twice
bash tests/schema-additive.bh-1000-test.sh                         # every statement is IF NOT EXISTS / OR IGNORE
```

On a worker that is deployed AND whose D1 has had `schema.sql` applied (see
Preconditions — the apply is what makes this a 200 instead of a 503):
`curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/hub/lease"`
answers `200 {"lease":null,...}` until something starts renewing.

The client half of BH-1023 is pinned by `tests/hub-lease-epoch.bh-1023-test.sh`,
which drives the real `bin/hub-lease.sh` CLI against a stubbed curl on a pinned
clock and asserts exit codes, the cache JSON, the ALERTS count and the request
sink: E0 the dark path (no request at all), E1 the ticket's case (fresh cache
says held, row says epoch+1 → exit 1), E2 the holder moving, E3/E3b that the
unreachable paths are unchanged and silent inside grace, E4 that a matching
epoch refreshes `fetched_at`, E5 that a non-holder makes no request, E6 no
cache, E7 the granted epoch, E8 the row→file sync through `renew`, E9 the
env-over-file precedence, E9b-E9f the `global.env` kill switch driven the way
cron runs it (the variable absent from the process, present only in the file),
its precedence under an exported value, and that a commented or junk value is no
override, E9g that the runner's own `HARNESS_ENV_DIR` cannot decide those cases,
E9h-E9k that a trailing `# comment`, an `export ` prefix, a CRLF ending and a
leading indent each still kill the re-validation (rc 0, no GET) while a
COMMENTED line still does not, E9m that the LAST assignment wins both ways so an
appended kill switch is honoured, E9n the trailing tab, E9l that an unresolvable
value is logged by name — including one masked by a later source — and a dark
box logs nothing, E9o that the line is once per incident and re-arms when the
knob resolves, E10 string and absent epochs. Point
`HUB_LEASE_SCRIPT` at another copy of the script (`git show
main:bin/hub-lease.sh`) to run the same suite against it.

The crontab half is pinned by `tests/hub-cron-gated-test.sh` (the renew line is
present exactly once, verbatim and outside every block; in-block job lines ==
prefixed lines, both > 0; the named box-local lines are present and unprefixed;
every gated command still parses as bash) and by
`tests/cron-fleet-parity-test.sh` (the checked-in `cron/hub.cron` IS
`bin/render-crontab.sh hub`, and rendering the render changes nothing). On the
HUB itself, after a merge and the next `fleet-propagate.sh` tick:

```bash
diff <(crontab -l) /root/harness-checkout/cron/hub.cron   # empty = live crontab IS the repo file
crontab -l | grep 'watchdog-ping'               # still unprefixed (box lane)
cat /root/harness/state/hub-lease.json          # held=1, fresh fetched_at, holder box-hub
tail -3 /root/harness/logs/hub-lease.log        # SILENCE is the healthy state — see below
ls /root/harness/state/hub-lease-failing-since  # ABSENT is healthy: no outage clock is running
grep 'schema.sql applied' /root/harness/logs/update-runners.log   # precedes "worker jobs deployed"
```

`logs/hub-lease.log` is a FAILURE log, not a heartbeat: `bin/hub-lease.sh` calls
`_log` from a failing `renew`, `check`'s unexpected-rc branch, a failed
`promote`, each page `check` sends (since BH-1000), and `_epoch_check_on` when
`HUB_LEASE_EPOCH_CHECK` is set to something that is neither `1` nor `0` (the
value is named; the knob falls through to the next source). A working lease with
a knob that is unset or sane writes nothing there; the ignored-knob line is
itself once per incident behind `flags/alerted-hub-lease-knob`, and an outage
writes to `logs/ALERTS.log` through `bin/lane-alert.sh`. The once-a-minute
evidence that renew is running is `fetched_at` in `state/hub-lease.json` moving,
and `expires_at` in the `GET` response moving with it. Read the log for the
failure line — which now carries the worker's own words
(`http=503 {"error":"hub_lease schema not applied",...}`) rather than a flat
"worker unreachable" — not for proof of life.

**Manual-only / not automatable:** the schema apply runs inside
`bin/harness-sync.sh` on the hub, which is the only box holding a Cloudflare
credential; a build box never touches production D1, so a builder cannot verify
the apply from its own session — the evidence is `schema.sql applied` in
`logs/update-runners.log` on the hub after the first deploy-mode run following a
merge. Driving `promote` against the live worker moves hub-ness for the whole
fleet, so it is not a probe to run casually; `GET` is the read-only check.

Re-pointing `/root/harness-checkout` at `main` is NOT a hand step in the general
case: since BH-1099 the fleet branch guard owns it, and its contract is
`docs/verification-map/fleet-propagate-branch-guard.md`. `bin/fleet-propagate.sh`
(`*/5`) forces a CLEAN, not-in-use checkout back to `main` and logs the branch it
moved off; a dirty or in-use checkout is refused with `hub=fail` and a
`hub_reason` naming the branch and the cause. `bin/harness-sync.sh` is the
preflight on top: it refuses a non-main checkout with rc 30 (`refused
branch=<name>`) before any fetch and deploys `main` and only `main`. The HAND
recipe in `docs/notes/2026-09-19-BH-1023-hub-lease-epoch.md` is for that refusal
case only. Independently, `bin/pipeline-health.sh` check 8 compares the
checkout's HEAD to `origin/main` every 10 minutes, tries `harness-sync.sh deploy`
as an auto-heal, and pages `driftfail:local` while HEAD is still not
`origin/main`; flipping the epoch knob on the hub is pointless until HEAD is on
main and that sync has run.

**Sibling slices:** all four children of #398 have landed — the worker table and
routes (#429), the `hub-lanes` marker pass in `bin/render-crontab.sh` (#431), the
client `bin/hub-lease.sh` (#430, merged in #494), and the regenerated
`cron/hub.cron` plus the leadership section of `docs/HUB-THINNING-PLAN.md`
(#432, this entry's primary lane).

## Hub recovery routes (BH-1943)

Two bearer-gated worker routes in `worker/jobs/src/routes/hub-recovery.js`,
built on the BH-1942 contract (`docs/HUB-RECOVERY-MCP.md`). The `/hub` console
screen does not call them yet (#1945), and the coord proxy forwards the GET only.

- `GET /api/hub/recovery`: always 200 unless D1 throws. It returns `lease`
  (`readLease` plus `live`, `null` when the table is empty), `role`
  (`active`, `active_expired_holder`, `standby` = the `standby_status` box
  names, and `standby_note`, which is null when any standby has sent a
  heartbeat and "no standby has reported a heartbeat yet" otherwise),
  `standbys` (the `standby_status` rows by box, fed by
  `POST /api/hub/standby/heartbeat`, BH-2639), `backups` (one row per `box_status` row with
  `state` off/ok/stale/unknown/unconfigured/missing and `age_min`, `null` when
  there is no real stamp), `stale_min` + `stale_min_source` (the
  `backup_stale_min` settings row when it is all digits, else 30),
  `recent_changes` (last 20 `hub_lease_changes` rows, newest first) with
  `truncated`, and `as_of`. A missing table answers 503
  `hub_lease schema not applied`.
- `POST /api/hub/promote` body `{target, expected_epoch, actor, reason, confirm:true}`
  (`holder`/`expect_epoch` accepted as aliases). In check order it refuses:
  400 `actor_required` (no audit row), 400 `confirm_required`, 400 `unknown_box`
  (not a lane name, or no `box_status` row), 400 `expected_epoch_invalid` (not a
  JSON integer ≥ 0), 409 `no_lease`, 409 `stale_epoch` (with the live lease).
  Each refusal after the actor check writes one `promote_refused` row to
  `hub_lease_changes` and nothing to `hub_lease`. Success bumps the epoch under
  an `epoch=?` fence and writes the `promote` audit row in the same
  `env.DB.batch`, then answers 200 `{ok, before, after, lease, promoted, audit_id, as_of}`.
  The old holder's next renew gets 409 `lease held`.

**Verify it works (read-only):**
`curl -s -H "Authorization: Bearer $HARNESS_SECRET" https://harness-jobs.operator.workers.dev/api/hub/recovery | jq '.lease.epoch, (.backups|length)'`
prints the live epoch and the number of `box_status` rows. Before
`bin/harness-sync.sh` has applied `hub_lease_changes`, both routes answer 503
`hub_lease schema not applied`.

**Manual-only:** QA never drives `POST /api/hub/promote` against production. It
moves hub-ness for the whole fleet. `worker/jobs/test/routes/hub-recovery.bh-1943.test.js`
drives it against a node:sqlite D1 built from the real `schema.sql`.

**The split-brain guard (BH-2198).** The promote is off until the
`hub.promote_enabled` settings row is `1` (seeded `0`; off is 403
`promote-disabled`, audited). A live lease is 409 `lease_live` with no write
unless the body carries `override_live_lease: true` (audited as
`ok:override_live_lease`). Stop the old hub, or cut its lane gate, BEFORE
promoting: `bin/hub-lease.sh` fails open while the worker is unreachable
(BH-1000). Cases G1–G9 in the same test file drive it.
Check the setting (read-only):
`curl -s -H "Authorization: Bearer $HARNESS_SECRET" https://harness-jobs.operator.workers.dev/api/settings/hub.promote_enabled | jq .`
