/**
 * Warm-standby failover (BH-401, issue #1922). Runs as step 4 of `scheduled`,
 * inside its own try/catch. Promotes the one healthy standby when the lease
 * holder is dead on BOTH clocks: its ping is older than cfg:failover_ping_min
 * (watchdog clock) and its lease has gone cfg:failover_lease_min unrenewed
 * (jobs server clock). At most one promote per lease epoch: the failover:<epoch>
 * marker is written before the call and never re-armed.
 *
 * OFF by default. Armed only by cfg:failover = "on" AND a declared hub
 * self-fence, cfg:failover_hub_fence_s, that trips at least FENCE_MARGIN_S
 * before the lease window. That knob has to match HUB_LEASE_FENCE_S on the
 * hub: this watchdog reaches the jobs worker from Cloudflare's side, so it can
 * promote while the hub cannot hear the worker, and bin/hub-lease.sh fails OPEN
 * on the configured hub until its fence ends that (BH-1000, BH-1922).
 * The promote itself goes through the guarded POST /api/hub/promote, so the
 * jobs worker's hub.promote_enabled setting (default '0') is a second, D1-side
 * arming key, and every attempt leaves a hub_lease_changes audit row.
 *
 * KV knobs: cfg:failover ("on" arms it), cfg:failover_hub_fence_s (no default),
 * cfg:failover_ping_min (16), cfg:failover_lease_min (10). Needs env.JOBS_URL;
 * unset = failover off.
 */
import { listStandbys, failoverKey } from "./standby.js";

// tg and the two windows below mirror index.js (tg, PING_STALE_MIN,
// STATUS_STALE_MIN, REALERT_MIN). They are copied rather than imported because
// index.js does not export them and this ticket may not edit it.
const STANDBY_PING_FRESH_MIN = 15;
const STANDBY_REPORT_MAX_MIN = 45;
const REALERT_MIN = 60;
const MARKER_TTL_S = 30 * 86400;
// Defaults: "dead" is three missed */5 pings and ten missed 1-minute renews,
// not one blip.
const PING_MIN_DEFAULT = 16;
const LEASE_MIN_DEFAULT = 10;
// The hub's fence must trip this long before the lease window: its unreachable
// clock starts at its last ANSWERED call, which can be up to one renew
// interval (60 s) after the lease's updated_at, plus 60 s for clock skew.
const FENCE_MARGIN_S = 120;

async function tg(env, text) {
  await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      chat_id: env.TELEGRAM_CHAT_ID,
      text,
      ...(env.TELEGRAM_THREAD_ID ? { message_thread_id: Number(env.TELEGRAM_THREAD_ID) } : {}),
    }),
  }).catch(() => {});
}

// Positive integer KV knob. Absent = default, silently; anything else that is
// not a positive integer = default, with a warning.
async function knob(env, key, dflt) {
  const v = await env.KV.get(key);
  if (v === null || v === undefined) return dflt;
  if (/^\d+$/.test(v) && Number(v) > 0) return Number(v);
  console.warn(`failover: ${key}=${JSON.stringify(v)} is not a positive integer, using ${dflt}`);
  return dflt;
}

async function pingAgeMs(env, box, t) {
  try {
    const v = JSON.parse(await env.KV.get(`ping:${box}`));
    const age = t - v.ts;
    return Number.isFinite(age) ? age : null;
  } catch {
    return null;
  }
}

const mins = (ms) => Math.round(ms / 60000);

// The guarded route's terminal refusals (worker/jobs/src/routes/hub-recovery.js),
// keyed "<status>:<error>". Each is recorded as refused:<error> on the marker
// and paged with its own text; anything else is failed:<status>.
const REFUSALS = {
  "403:promote-disabled": (s) => `hub.promote_enabled is off in D1, the jobs-side kill switch, so nothing was promoted: promote ${s} by hand for this outage (Mission Control /hub PROMOTE, which needs the switch at 1 while you do it); leave it at 1 only if future outages should promote automatically`,
  "409:stale_epoch": (_s, e) => `the lease is no longer at epoch ${e}; another promote or claim landed first, check GET /api/hub/recovery`,
  "409:lease_live": () => "the jobs worker says the holder's lease is live, so the holder renewed and is not dead",
  "400:unknown_box": (s) => `the jobs worker has no box_status row for ${s}`,
};

export async function failoverTick(env, t) {
  // 1. Armed only by an explicit "on", and only when configured.
  if ((await env.KV.get("cfg:failover")) !== "on") return;
  if (!env.JOBS_URL) return;
  const leaseMin = await knob(env, "cfg:failover_lease_min", LEASE_MIN_DEFAULT);
  const pingMin = await knob(env, "cfg:failover_ping_min", PING_MIN_DEFAULT);
  // 1b. No promote over a hub that could still be failing open.
  const fenceS = await knob(env, "cfg:failover_hub_fence_s", 0);
  if (!(fenceS > 0 && fenceS + FENCE_MARGIN_S <= leaseMin * 60)) {
    const dk = "alerted:failover-unfenced";
    const last = await env.KV.get(dk);
    if (last && t - Number(last) < REALERT_MIN * 60000) return;
    await env.KV.put(dk, String(t));
    await tg(env, `🚨 HUB FAILOVER armed but not safe, so it will not promote: cfg:failover_hub_fence_s=${fenceS || "unset"} must be set to the hub's HUB_LEASE_FENCE_S and be at most ${leaseMin * 60 - FENCE_MARGIN_S} s (cfg:failover_lease_min ${leaseMin} min − ${FENCE_MARGIN_S} s)`);
    return;
  }
  const auth = { Authorization: `Bearer ${env.HARNESS_SECRET}` };

  // 2. Read the lease. Anything unreadable means we cannot judge.
  let body;
  try {
    const res = await fetch(`${env.JOBS_URL}/api/hub/lease`, { headers: auth });
    if (!res.ok) return;
    body = await res.json();
  } catch {
    return;
  }
  const lease = body?.lease;
  if (!lease) return;

  // 3. Lease staleness, server clock only.
  const leaseStale = Date.parse(body.as_of) - Date.parse(lease.updated_at);
  if (!Number.isFinite(leaseStale) || leaseStale < leaseMin * 60000) return;

  // 4. Holder ping staleness, watchdog clock. Fresh = hub-lease.sh's own page.
  const holder = lease.holder;
  const pingAge = await pingAgeMs(env, holder, t);
  if (pingAge === null || pingAge <= pingMin * 60000) return;

  // 5. Never twice for one outage.
  if (await env.KV.get(failoverKey(lease.epoch))) return;

  // 6. Exactly one eligible standby.
  const eligible = [];
  for (const r of await listStandbys(env, t)) {
    // `of` is the hub the standby follows: a replica of some other box is not
    // a copy of this hub's state.
    if (r.box === holder || r.ok !== true || r.of !== holder) continue;
    if (!Number.isFinite(r.report_age_min) || r.report_age_min < 0 || r.report_age_min > STANDBY_REPORT_MAX_MIN) continue;
    // A recently repeated report of the same old snapshot is not fresh state.
    if (!Number.isFinite(r.stream_age_min) || r.stream_age_min < 0 || r.stream_age_min > STANDBY_REPORT_MAX_MIN) continue;
    const age = await pingAgeMs(env, r.box, t);
    if (age === null || age < 0 || age > STANDBY_PING_FRESH_MIN * 60000) continue;
    eligible.push(r.box);
  }
  if (eligible.length !== 1) {
    const why = eligible.length === 0 ? "no eligible standby" : `${eligible.length} eligible standbys (${eligible.join(", ")})`;
    const dk = `alerted:failover-impossible:${lease.epoch}`;
    const last = await env.KV.get(dk);
    if (last && t - Number(last) < REALERT_MIN * 60000) return;
    await env.KV.put(dk, String(t));
    await tg(env, `🚨 HUB FAILOVER not possible: ${why} — ${holder} down ${mins(pingAge)} min`);
    return;
  }
  const standby = eligible[0];

  // 7. Marker BEFORE the call. A failed put throws and no promote is made.
  const marker = { ts: t, from: holder, to: standby, result: "pending" };
  await env.KV.put(failoverKey(lease.epoch), JSON.stringify(marker), { expirationTtl: MARKER_TTL_S });

  // 8. Promote through the guarded route (BH-1943): hub.promote_enabled in D1
  // is the second arming key, expected_epoch is the CAS, and the jobs worker
  // writes the hub_lease_changes audit row. No override_live_lease: a lease
  // the worker still calls live is not a dead hub.
  let ok = false;
  let status;
  let refused;
  let promoted;
  try {
    const res = await fetch(`${env.JOBS_URL}/api/hub/promote`, {
      method: "POST",
      headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify({
        target: standby,
        expected_epoch: lease.epoch,
        actor: "watchdog",
        reason: `BH-401 failover: ${holder} ping ${mins(pingAge)} min old, lease ${mins(leaseStale)} min unrenewed`,
        confirm: true,
      }),
    });
    status = String(res.status);
    try { promoted = await res.json(); } catch { promoted = null; }
    ok = res.ok && promoted?.ok === true && promoted?.lease?.holder === standby;
    if (res.ok && !ok) status = `${res.status}-mismatch`;
    if (!res.ok && REFUSALS[`${res.status}:${promoted?.error}`]) refused = promoted.error;
  } catch {
    status = "throw";
  }

  // 9. Record the outcome, then one page. No retry: the marker blocks this epoch.
  const result = ok ? "promoted" : refused ? `refused:${refused}` : `failed:${status}`;
  await env.KV.put(failoverKey(lease.epoch), JSON.stringify({ ...marker, result }), { expirationTtl: MARKER_TTL_S });
  await tg(env, ok
    ? `🔀 HUB FAILOVER → ${standby} (was ${holder}: ping ${mins(pingAge)} min old, lease ${mins(leaseStale)} min unrenewed; epoch ${lease.epoch}→${promoted.lease.epoch}). ${holder} stays demoted until a human runs: bin/hub-lease.sh promote --holder ${holder}`
    : refused
      ? `🚨 HUB FAILOVER → ${standby} REFUSED (${refused}): ${REFUSALS[`${status}:${refused}`](standby, lease.epoch)} — ${holder} down ${mins(pingAge)} min, not retried for epoch ${lease.epoch}`
      : `🚨 HUB FAILOVER → ${standby} FAILED (${status}) — needs you`);
}
