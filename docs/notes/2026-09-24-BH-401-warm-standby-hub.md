# Watchdog hub failover: failoverTick promotes the one healthy standby

Doc: watchdog-spec, HUB-THINNING-PLAN

## What changed

BH-1922, order 3 of 5 under #401 (warm-standby hub). The `failoverTick(env, t)`
stub from BH-1920 now has a body. It runs as step 4 of the watchdog's
`scheduled` cron, inside its own try/catch, so a bug in it can't block the
liveness steps before it. `worker/watchdog/src/index.js`, `standby.js`, the jobs
worker are unchanged. `bin/hub-lease.sh` gains the self-fence the failover
depends on (below).

- `worker/watchdog/src/failover.js`: the tick itself.
- `bin/hub-lease.sh`: `HUB_LEASE_FENCE_S` (environment, then `global.env`;
  unset = off). Past that many seconds without an answered call, the configured
  hub's fail-open ends: `check` exits 1 and pages `--critical --id
  hub-lease-fenced`, and the held=1 grace is capped at it. Pinned by case P in
  `tests/hub-lease.bh-1000-test.sh`.
- `worker/watchdog/wrangler.jsonc`: the secrets comment names `JOBS_URL` and the
  four `cfg:failover*` knobs. The change is comments only, with no new binding.
- `worker/watchdog/test/failover.bh-401.test.js`: drives `worker.scheduled`
  against an in-memory KV and a stubbed jobs worker and Telegram.

## The failover rule

The watchdog promotes when the lease holder is dead on both clocks. Its ping has
to be more than `cfg:failover_ping_min` old (default 16 min, watchdog clock), and
its lease has to have gone more than `cfg:failover_lease_min` unrenewed (default
10 min, measured as `as_of - updated_at` on the jobs server's clock). It is OFF
unless KV `cfg:failover` is `on` AND `cfg:failover_hub_fence_s` declares a hub
fence at least 120 s under the lease window. The fence is what stops a hub
that is partitioned from `*.workers.dev`: its renews fail as unreachable, so the
epoch bump never reaches it, and without the fence it fails open (BH-1000) for
as long as the partition lasts. There must
also be exactly one standby that reports `ok: true`, with a report no more than
45 min old and a ping no more than 15 min old. The watchdog writes
`failover:<epoch>` as `pending` before the guarded `POST /api/hub/promote`
(`expected_epoch` CAS, `actor: watchdog`, `confirm: true`; refused 403 unless
D1 `hub.promote_enabled` is on), then rewrites it as `promoted`,
`refused:<error>` or `failed:<status>` and sends one Telegram. It never
promotes twice for the same epoch and never retries a failed promote. With zero
or two-plus candidates it sends one "HUB FAILOVER not possible" page per hour
per epoch instead. The full rule is in `docs/watchdog-spec.md` § Hub failover.

A fresh holder ping with a stale lease does nothing here. That's a live box that
can't renew, and it is `hub-lease.sh`'s own page.

## Operator steps

These need the other slices of #401. The standby report routes (#1921) and
`bin/standby-install.sh` are not in this change.

1. Place the age identity on the standby box.
2. Run `bin/standby-install.sh box-small --apply`.
3. Set `JOBS_URL` on the watchdog (`wrangler secret put JOBS_URL`), using the
   harness-jobs worker's base URL. `HARNESS_SECRET` is already set and doubles
   as the jobs bearer.
4. Deploy the watchdog.
5. On the hub, set `HUB_LEASE_FENCE_S=480` in `global.env` (at most the lease
   window minus 120 s).
6. Only then arm it: KV `cfg:failover_hub_fence_s` = `480` and `cfg:failover`
   = `on`.

Until step 6, the tick does nothing. To disarm it without a deploy, delete KV
`cfg:failover` or set it to anything but `on`.

## Promote back

After a failover the old hub stays demoted. Once it is healthy, run:

    bin/hub-lease.sh promote --holder <old hub>
