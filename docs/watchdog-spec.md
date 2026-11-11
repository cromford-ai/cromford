# External watchdog / dead-man's switch — spec for the console worker

Asked by the operator (Telegram, 2026-08-13): something core and NOT AI-model dependent
that monitors the hub and each harness box, so failures surface even when a
Claude key / the Anthropic API / the whole hub is down. Implement in the
harness-console Cloudflare worker (it is already the one trust point OUTSIDE
the fleet, already receives beats, and can reach Telegram on its own).

## Why the worker
- Different failure domain from every box (Cloudflare, not Orgo/Fly).
- Boxes already push to it (`beat.sh` → `POST $CONSOLE_URL/api/beat`,
  HARNESS_SECRET auth) — layer 2 needs zero new box-side plumbing.
- It can hold the Telegram bot token and message the operator directly — the alert
  path shares nothing with the thing being monitored.

## Layer 1 — liveness ping (pure cron + curl, no harness code)
1. Worker: `GET/POST /api/ping/<box>` with `Authorization: Bearer <WATCHDOG_SECRET>` → KV
   `ping:<box> = now`. Boxes: box-hub (hub), box-project-2-1,
   box-project-3-2, box-project-4-1, box-project-10-1.
2. Each box gets ONE crontab line (deliberately not a harness script — it must
   survive harness bugs/reverts):
   `*/5 * * * * bin/watchdog-ping.sh <box>` (the secret is in env/.watchdog-secret, not in the
   crontab line; see "Auth" below)
3. Worker Cron Trigger (every 5 min): any box with `now - ping > 15 min` →
   Telegram to the operator: "WATCHDOG: <box> silent for N min (last ping HH:MMZ)".
   Re-alert at most hourly per box (KV `alerted:<box>`); send an all-clear
   when the ping returns.

## Auth (BH-9264, phase 1)
`worker/watchdog/src/auth.js` holds every auth check. `src/index.js` calls
`fleetAuth` on each fleet route and `stampAuth` on `POST /api/stamp/<name>`.

- **Transport.** A caller sends `Authorization: Bearer <secret>`. The legacy
  `?s=<secret>` query is still accepted in phase 1. A header that is present
  decides alone: a wrong or malformed header is `403`, and the worker does not
  try `?s=` after it.
- **Fleet secret.** Fleet routes take `WATCHDOG_SECRET`. `HARNESS_SECRET` is the
  phase 1 fallback, on both transports. The worker keeps `HARNESS_SECRET` set in
  any case, because failover (`src/failover.js`) uses it as the jobs bearer.
- **Equal secrets.** If `WATCHDOG_SECRET` equals `HARNESS_SECRET`, every fleet
  route answers `500` with the body
  `watchdog misconfigured: WATCHDOG_SECRET must differ from HARNESS_SECRET`, and
  writes one `console.error` line. No secret is compared.
- **Stamp secret.** `POST /api/stamp/<name>` takes `STAMP_SECRET` only, on the
  same two transports. The fleet secrets do not open it, and with
  `STAMP_SECRET` unset it is closed. The equal-secrets rule does not apply to it.
- **Log lines.** Each request that passes on `?s=` writes ONE line
  `watchdog query-auth route=<path> box=<name|->`. A header match on
  `HARNESS_SECRET` while `WATCHDOG_SECRET` is set writes ONE line
  `watchdog fallback-auth route=<path> box=<name|->`. The box name is the path
  segment of `/api/ping/<box>` and `/api/standby/<box>`; other routes log
  `box=-`, and the route names the caller. A line never holds a secret, a header
  value or the query string. `wrangler.jsonc` turns on `observability`, so
  Workers Logs keep these lines.
- **Callers.** Every `bin/` caller gets its secret from `watchdog_secret` and
  sends it with `watchdog_curl` (`bin/lib/watchdog-url.sh`). The lookup order is
  `env/.watchdog-secret`, then `$WATCHDOG_SECRET`, then `$HARNESS_SECRET`. curl
  reads the header from a config on a file descriptor, so the secret is in no
  argv and in no URL. The Mac (`bin/mac/mac-burn-push.sh`) reads
  `~/.orgo/.watchdog-secret`, else `~/.orgo/.harness-secret`. The stamp step of
  `.github/workflows/publish-cromford.yml` pipes the header to `curl -K -`.
- **Console proxy.** The harness-console watchdog pass-through
  (`docs/DASH-TICKETS-SNAPSHOT.md`) lives in a separate repository. It must
  send the header too. Until it does, its GETs show as `query-auth` lines for
  `/api/tickets-snapshot`, `/api/cost-snapshot` and `/api/mac-burn`.

**Phase 2** (a later PR) removes `?s=` and the `HARNESS_SECRET` fallback, and a
refused request answers `401`. Its condition: 24 h with 0 `watchdog query-auth`
lines and 0 `watchdog fallback-auth` lines in Workers Logs after the phase 1
deploy.

**Provisioning `WATCHDOG_SECRET`.** The order is free, because phase 1 accepts
both secrets on both transports.
1. Make a new value: `openssl rand -hex 32`. It must differ from the worker's
   `HARNESS_SECRET` binding.
2. Put it on the worker: `printf '%s' "$WATCHDOG_SECRET" | npx wrangler secret put WATCHDOG_SECRET`.
3. Put it on every box: `env/.watchdog-secret`, mode 600.
4. Put it on the Mac: `~/.orgo/.watchdog-secret`, mode 600.
5. Change the console proxy to send `Authorization: Bearer <WATCHDOG_SECRET>`.
6. After 24 h, count the `watchdog query-auth` and `watchdog fallback-auth`
   lines in Workers Logs.

## Layer 2 — semantic staleness (the "hub is up but dead inside" case)
Same cron trigger, over data the worker already stores:
- No triage/run beat for a project in > 45 min during its cron cadence →
  "lanes stale" alert naming the project. This catches exactly the
  API-key-down case: layer-1 ping stays green, beats stop.
- Optional: surface `fleet_alert` beats with akey prefix `watchdog:` verbatim.

## Non-goals
- No AI calls anywhere in the watchdog path.
- No inbound probing of boxes (hub runs no sshd; boxes push, worker judges).
- Not a replacement for medic/the lane-liveness reaper — those are richer but live
  INSIDE the failure domain this watches.

## Hub-side part (orchestrator does this once the endpoint exists)
- Add the crontab line on all five boxes (hub ssh's to watchers; hub's own
  line added directly).
- Store nothing new in env files — the ping URL+secret lives in the crontab
  line itself (chmod-irrelevant; it only allows *pinging*).

Stopgap if the worker patch waits: healthchecks.io free tier gives per-box
ping URLs + native Telegram — same box-side cron lines, zero code. The worker
version is still preferred (one fewer vendor, layer 2 comes free).

---

## v2 — beyond the watchdog (the operator, 2026-08-13: "status, wake ups, other ideas")
Same worker, same trust model (Cloudflare = outside every fleet failure
domain, no AI in any path). Build in this order; each layer stands alone.

### 1. Instant status over Telegram (read-only, zero tokens)
The worker already holds beats; the hub additionally pushes its compact
fleet-status JSON (deploy snapshot, last triage per project, open alerts,
build-queue depths — all files it already maintains) to `POST /api/status`
each snapshot cycle. Telegram `/status` (or a dashboard section) answers
from KV instantly — no model call, no hub round-trip, works while the hub
is DOWN (served stale with its age labeled: "as of 14:32Z, hub silent 22m").

**Snapshot fields added 2026-09-14** (`bin/fleet-status-push.sh`, top level
beside `projects` / `fly` / `alerts_24h` / `deploys` / `pause_flags` /
`stale_owed`). Each answers a question that still needed an ssh to the hub.
Every one is fail-open — an absent source degrades the field, never the push.

| Field | Shape | Source | Absent / broken |
|---|---|---|---|
| `quota` | `[{account, vendor, five_hour_pct, weekly_pct, state, resets:{five_hour,weekly}}]` | `bin/quota-status.sh --json`, trimmed to these fields | `null` + `quota_error` one of `missing` \| `failed` \| `nonjson` |
| `lanes_down` | `{"<box>": ["<lane>", …]}` | `flags/lanedown-<box>-<lane>-<YYYYMMDD>`, **today (UTC) only** — older flags are history, not state | `{}` |
| `lanes_down_detail` | `{"<box>": {"<lane>": {since, age_s, last_probe, last_error, standing}}}` — epochs and seconds, `last_error` capped at 120 chars, `standing` a boolean (`standing_at` set) (BH-1674) | `state/lane-down/<box>-<lane>` records written by `bin/lib/lane-down.sh`, read with no lock; `ld_clear` deletes a record on recovery, so this can name a lane `lanes_down` does not (down since yesterday, flag not yet re-touched today) | `{}`. A record that is malformed (non-epoch or future `since`, non-epoch `last_probe`, box-lane not matching its file name, including in-flight `.tmp.` writes) is skipped, never zero-filled. Shed with the other 2026-09-14 fields over 60000 bytes |
| `alert_backlog` | `{deferred_lines, deferred_families}` | `state/alert-triage-deferred.tsv` plus every `state/alert-triage/<project>/deferred.tsv` (BH-5942); families via the shared `bin/alert_family.py` | zeros when no spool exists; a missing spool is skipped; both `-1` when a spool path exists but cannot be read; `deferred_families: -1` when it cannot be computed |
| `rules` | `[{scope, selector, kind, max_concurrent}]`, ≤50 rows | `bin/jobs-client.sh rules` — the one-glance "is anything capping the fleet" | `[]` when genuinely uncapped; `null` when the client is absent/unreachable |
| `remote_results_pending` | `{"<project>": <int>}` | `state/remote-results/<project>/*.json` older than 30m with no `builds/(pool-)<project>-<KEY>-*/RELAYED` sibling (same test as `bin/pipeline-health.sh`) | `0` per project — zero everywhere is the healthy answer |
| `hub` | `{load1, disk_pct, mem_used_mb, mem_total_mb, uptime_s}` | `/proc/loadavg`, `df -P /`, `/proc/meminfo`, `/proc/uptime` (Linux only) | each field `null` |
| `backups` | `{"<box>": {state, backup_age_min?}}`, `state` one of `ok` \| `off` \| `unconfigured` \| `missing` \| `unknown` (BH-399) | the hub's own row off `state/backup-last.json`; every other box's from `state/fleet-heartbeat/backup-<box>`, reported by `bin/state-backup.sh` on the box and written by `bin/backup-records-sync.sh` on the hub (BH-1031; before that, collected over `bin/fleet-heartbeat.sh`'s ssh hop). One reader: `bin/lib/backup-freshness.sh` | `{}`. **`backup_age_min` is present only when an age is knowable** — a fabricated `0` is the healthy value for the number the fleet alerts on, so it would read as "backed up just now" forever. A box never heard from — or no longer heard from: a record older than 35m, an `unreachable-<box>` marker, or a box `fleet.conf` no longer names — produces no entry at all |
| `backup_stale_min` | `<int>` — the threshold the alerts used on this tick (BH-399) | `bf_stale_min`: `setting_get backup_stale_min` → `BACKUP_STALE_MIN` → 30 | the key is **absent** when the library is not installed, never `null`: a consumer's `Number(null)` is `0`, which would mark every box stale |
| `ci_timeout_budget` | `[{repo, check, workflow, timeout_min, hit, of, p50_s, p90_s, prs, at}]` — `prs` an array of PR numbers, `at` the firing epoch; newest first, one row per (repo, check), ≤20 rows, with `ci_timeout_budget_truncated:<total>` beside it only when more qualified (BH-3788) | `state/merge-conductor/ci-timeout-firing.tsv` (`CIT_FIRING_TSV` in `bin/lib/mc-ci-timeout.sh`), lines from the last 24 h, newest line per (repo, check), read with no lock | `[]` when the file is missing or unreadable. A line without 11 fields or with a non-numeric epoch, T, X, Y, p50, p90 or PR number is skipped, never zero-filled. Shed with the other 2026-09-14 fields over 60000 bytes |
| `ci_advisory_red` | `[{repo, heads}]` — the distinct heads per repo that the merge conductor found red only by advisory failures (a failed run that holds no failed required check), most heads first (BH-9210) | `state/merge-conductor/ci-advisory-red.tsv` (`mca_note` in `bin/lib/mc-ci-advisory.sh`: `<epoch>\t<slug>\t<sha>\t<workflows>`), lines from the last 24 h, read with no lock (`mca_count_24h`) | `[]` when the file is missing or unreadable. A line without 4 fields or with a non-numeric epoch is skipped. A failure in this step keeps the snapshot without the field |

Size: the worker refuses a body over 64000 bytes with 413, and the push is
silent, so an oversized snapshot would fire the dead-man it exists to feed.
`quota` is trimmed and `rules` capped at 50 rows; above 60000 bytes
(`SNAP_CAP`) the push sheds the 2026-09-14 fields largest first, one at a time,
until the body fits (BH-9112). It adds `snapshot_trimmed:"size"` and
`snapshot_shed:[<dropped keys>]`. One oversized field (a 150 KB `rules`) costs
that field only; a pad in a field that cannot be shed still sheds them all.
Every fleet-sized value reaches jq through a file descriptor, never argv
(BH-9112). If the full snapshot still fails, the pre-2026-09-14 shape is
pushed, `logs/fleet-status-push.log` gets one `full snapshot fell back:
invalid=… largest=… env=… rc=…` line per run, and ALERTS.log gets one
`fleet-status-snap-fallback` warn line per UTC day.

### 2. Command queue + wake-ups (worker -> hub, the missing direction)
The hub already polls Telegram for the operator's messages; point the same poll (or
a second one) at `GET /api/commands?since=`. The worker enqueues:
- **Scheduled wake-ups**: "at 09:00Z start a session with prompt X" — cron
  triggers survive hub restarts and dead sessions, unlike in-session timers.
- **Watchdog escalation**: lane stale -> enqueue a medic wake BEFORE
  telegramming the operator; self-heal first, page second. If the hub never picks
  the command up, THAT is the page.
- **One-tap actions**: Telegram inline buttons on alerts ("Promote latest
  READY", "requeue build", "pause project") -> button press becomes a queued
  command executed by the hub as a the operator-issued console command (it IS one —
  the press is the operator acting), fully audit-logged. Today's stale-prod incident
  becomes: alert with a [Resume promotion] button, fixed from the phone in
  one tap.
Auth: commands are written ONLY by the worker itself (Telegram webhook from
the operator's chat id or its own cron); hub verifies HARNESS_SECRET + monotonic ids;
replay-safe (each command consumed once, journaled to KV for audit).

### 3. Dead-hub resurrection (optional, powerful)
Watchdog sees the hub silent 30+ min -> call the Orgo API (key as a worker
secret) to restart the hub box, telegram the operator either way ("restarted, watch
for recovery" / "restart failed, box wedged — needs you"). This is the
08-10 project-3 wedge scenario made self-healing. Guard: max 1 restart per 6h,
never restart a box that is pinging (semantic staleness alone = page only).

### 4. Small but free once 1–2 exist
- Ping payloads carry disk%, load, build-queue depth -> trends on the console.
- Command journal doubles as the durable audit trail of every phone-issued action.
- Per-box "maintenance mode" flag settable from Telegram (silences its alerts,
  visible on the dashboard) instead of the operator remembering a box is mid-rebuild.

### Order of work
watchdog L1 (pings) -> L2 (beat staleness) -> /api/status + /status command ->
command queue + scheduled wake-ups -> inline buttons -> Orgo resurrection.
Each step is small; the worker patch for L1+L2+status is one sitting on the
local CC session.

## Hub failover (BH-401)

Step 4 of `scheduled` is `failoverTick` (`worker/watchdog/src/failover.js`).
It moves hub-ness to a warm standby when the hub is dead, and it does that at
most once per lease epoch.

**The rule.** Each tick, in order:

1. `cfg:failover` is anything but `on` (absent included: failover ships OFF),
   or `JOBS_URL` is unset: do nothing. No call, no write, no page.
   Then the hub fence: `cfg:failover_hub_fence_s` must be a positive integer
   no larger than `cfg:failover_lease_min` × 60 − 120 s (480 s at the
   defaults). Otherwise it makes no jobs call and pages
   `🚨 HUB FAILOVER armed but not safe, so it will not promote: …`, damped to
   one per hour (`alerted:failover-unfenced`). The knob states the hub's
   `HUB_LEASE_FENCE_S`. The configured hub fails OPEN on an unreachable jobs
   worker (BH-1000), and the watchdog reaches that worker from Cloudflare's
   side, so without the fence a hub partitioned from `*.workers.dev` would keep
   acting after it is demoted. See `docs/HUB-THINNING-PLAN.md` § Residual
   split-brain window.
2. `GET $JOBS_URL/api/hub/lease` with `Authorization: Bearer $HARNESS_SECRET`.
   A non-2xx answer, a network error or `lease: null` means the tick can't
   judge, so it stops.
3. Lease staleness is `as_of - lease.updated_at`, both taken from the jobs
   server's clock. Under `cfg:failover_lease_min` (default 10 min), or not a
   number, stops the tick.
4. Holder ping staleness is `now - ping:<holder>.ts` on the watchdog's own
   clock. A missing ping, or one no older than `cfg:failover_ping_min`
   (default 16 min, three missed `*/5` pings), stops the tick silently. A live box that can't renew is
   `hub-lease.sh`'s own page, not this one.
5. `failover:<epoch>` already exists: stop. That is the once-per-outage rule.
6. Candidates are the `standby:<box>` rows with `box != holder`, `of == holder`, `ok: true`,
   a report no more than 45 min old, and `ping:<box>` no more than 15 min old.
   With zero or two-plus candidates it pages
   `🚨 HUB FAILOVER not possible: <why> — <holder> down <n> min`, damped to one
   per hour per epoch (`alerted:failover-impossible:<epoch>`), and stops. It
   writes no marker, so a standby that turns healthy later can still be
   promoted for the same outage.
7. It writes `failover:<epoch>` = `{ts, from, to, result: "pending"}` BEFORE
   the call. If that put fails, no promote is sent.
8. `POST $JOBS_URL/api/hub/promote {target: <standby>, expected_epoch: <epoch>,
   actor: "watchdog", reason, confirm: true}`, same bearer. That is the guarded
   route (BH-1943): it refuses unless D1 `settings.hub.promote_enabled` is on,
   CASes on the epoch, refuses a live lease, and writes a `hub_lease_changes`
   audit row. So `hub.promote_enabled` is the second arming key, next to
   `cfg:failover=on`. It never sends `override_live_lease`. Success means a 2xx
   with `ok: true` whose `lease.holder` is the standby.
9. It rewrites the marker's `result` as `promoted`, `refused:<error>` or
   `failed:<status>`, then sends one Telegram. `refused:` is one of the route's
   terminal refusals, each with its own page: 403 `promote-disabled`, 409
   `stale_epoch`, 409 `lease_live`, 400 `unknown_box`. `<status>` is the HTTP
   code for anything else, `<code>-mismatch` for a 2xx that is not `ok: true`
   or names the wrong holder, or `throw`. Nothing retries: the marker blocks
   every later tick for that epoch. The `promote-disabled` page tells the
   operator to promote the standby BY HAND for this outage. Mission Control's
   /hub PROMOTE also goes through the guarded route, so the switch has to be at
   1 while they do it. Leaving `hub.promote_enabled` at 1 afterwards is a
   separate choice: it arms automatic promotion for future outages.

The old hub stays demoted until a human runs
`bin/hub-lease.sh promote --holder <old>`.

**KV keys.**

| Key | Value |
|---|---|
| `standby:<box>` | `{ts, of, snapshot, ok}`, see `worker/watchdog/src/standby.js` |
| `failover:<epoch>` | `{ts, from, to, result}`, result `pending` / `promoted` / `refused:<error>` / `failed:<status>`, 30-day TTL |
| `alerted:failover-impossible:<epoch>` | last "not possible" page time |
| `cfg:failover` | `on` = armed. Anything else, or absent, = off |
| `cfg:failover_hub_fence_s` | the hub's `HUB_LEASE_FENCE_S`, positive integer ≤ lease window − 120 s. No default: unset = armed but not safe, no promote |
| `alerted:failover-unfenced` | last "armed but not safe" page time |
| `cfg:failover_ping_min` | positive integer, default 16. A bad value falls back with `console.warn` |
| `cfg:failover_lease_min` | positive integer, default 10. Same fallback |

**Standby routes.** A standby reports itself with `POST /api/standby/:box`
(body `{of, snapshot, ok}`, 2 KB cap, the box must be in `BOXES`). The
watchdog stamps `ts` and stores the row. `GET /api/standby` lists the rows and
`/api/status` carries them as a `standby` field. Those routes belong to a
sibling slice of #401 (#1921), not to the failover tick. Until they ship, no
`standby:` row exists. With `JOBS_URL` set, the tick then pages "no eligible
standby" when the hub dies.
