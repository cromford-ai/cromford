/**
 * harness-watchdog — external dead-man's switch + status + command queue for
 * the box fleet (docs/watchdog-spec.md; the operator go 2026-08-13).
 *
 * Deliberately a SEPARATE worker from harness-console: zero risk to the live
 * dashboard/Telegram relay, and no AI anywhere in this path. Boxes push pings
 * and status; this worker judges staleness on a cron and talks to Telegram
 * directly. The hub polls /api/commands for the worker->hub direction.
 *
 * KV layout:
 *   ping:<box>            {ts, metrics?}          last ping per box
 *   status:fleet          {ts, body}              hub-pushed fleet status JSON
 *   alerted:<key>         ts                      last alert time (damping)
 *   cmd:<id>              {id, ts, type, arg}     queued commands (hub consumes)
 *   cfg:orgo_restart      "on"|"off"              resurrection kill switch (default off)
 *   cfg:orgo_computer_id  <id>                    hub's Orgo computer id
 *   standby:<box>         {ts, of, snapshot, ok}  warm-standby report (standby.js)
 *   progress:snap / progress:cfg / progress:cfg_rejects / stamp:<name>
 *   pseen:<key> / pinc:<key> / pcool:<key>
 *                         K2 outside dead-man (progress.js)
 */

import { failoverTick } from "./failover.js";
import { standbyKey, listStandbys } from "./standby.js";
import { tg } from "./telegram.js";
import {
  NAME_RE, PROGRESS_CFG_KEY, STAMP_PREFIX, acceptPush, dryRun, progressTick, progressView,
} from "./progress.js";

// Every box that pings lives in ./boxes.json (BH-1957: config, not a code
// array). A box missing there is invisible to the watchdog AND to Mission
// Control's machine tiles — it is not "unmonitored but fine", it is a box whose
// death nobody would notice. tests/watchdog-boxes-test.sh asserts that list and
// the committed cron ping lines are the same set, in both directions, and a ping
// from a name the list does not know alerts (see /api/ping below).
// box-project-10-1 is PARKED (box stopped 2026-08-25 by the operator).
// Re-add it to boxes.json AND restore the ping line in cron/project-10.cron together.
//
// The set of boxes that must ping comes from the registry first: the hub's
// fleet-status snapshot (bin/fleet-status-push.sh) carries `expected_boxes`,
// the registry boxes whose role is not gate-only or retired. boxes.json is the
// fallback when that list is absent, empty, not a list of valid names, or the
// snapshot cannot be read. So the set is never empty, and a broken snapshot
// falls back to today's list instead of silencing every page.
import BOXES from "./boxes.json" with { type: "json" };
const HUB = "box-hub";
const PING_STALE_MIN = 15;
const HUB_DEAD_MIN = 30;
const STATUS_STALE_MIN = 45;
const REALERT_MIN = 60;

const now = () => Date.now();
const min = (ms) => Math.round(ms / 60000);

// The ping route's own name rule (/api/ping/<name>).
const PING_NAME_RE = /^[a-z0-9-]+$/;

// expected_boxes from KV status:fleet ({ts, body}, body = the pushed JSON
// text), filtered to valid names; BOXES when nothing valid is left.
async function expectedBoxes(env) {
  try {
    const raw = await env.KV.get("status:fleet");
    if (!raw) return BOXES;
    const list = JSON.parse(JSON.parse(raw).body)?.expected_boxes;
    if (!Array.isArray(list)) return BOXES;
    const names = [...new Set(list.filter((b) => typeof b === "string" && PING_NAME_RE.test(b)))];
    return names.length ? names : BOXES;
  } catch {
    return BOXES;
  }
}

function authed(url, env) {
  return url.searchParams.get("s") === env.HARNESS_SECRET;
}

// Alert with damping: fire if never alerted or REALERT_MIN elapsed. Returns
// whether it fired so callers can pair a recovery notice via clearAlert.
async function maybeAlert(env, key, text) {
  const last = await env.KV.get(`alerted:${key}`);
  if (last && now() - Number(last) < REALERT_MIN * 60000) return false;
  await env.KV.put(`alerted:${key}`, String(now()));
  await tg(env, text);
  return true;
}
async function clearAlert(env, key, recoveryText) {
  const was = await env.KV.get(`alerted:${key}`);
  if (was) {
    await env.KV.delete(`alerted:${key}`);
    if (recoveryText) await tg(env, recoveryText);
  }
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const p = url.pathname;

    // All-boards ticket snapshot: the hub pushes a rendered snapshot every 10min
    // (bin/tickets-snapshot-push.sh) so Mission Control can show truthful client
    // ticket statuses without any board token reaching Cloudflare. Store is KV
    // key `tickets-snapshot`; the console proxies the GET behind the dash cookie.
    if (p === "/api/tickets-snapshot") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      if (req.method === "POST") {
        const body = await req.text();
        if (body.length > 512e3) return new Response("too big", { status: 413 });
        await env.KV.put("tickets-snapshot", body);
        return new Response("ok");
      }
      const v = await env.KV.get("tickets-snapshot");
      return new Response(v || "{}", { headers: { "content-type": "application/json" } });
    }

    // All-projects cost rollup: the hub pushes state/cost/summary.json here each
    // cost-rollup cycle (per-project cost_7d/30d, per-stage USD, cost-per-merged-PR,
    // unpriced-call counts) so Mission Control shows real spend, not just run/ticket
    // volume. Same KV-snapshot shape as tickets-snapshot; console proxies the GET.
    if (p === "/api/cost-snapshot") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      if (req.method === "POST") {
        const body = await req.text();
        if (body.length > 512e3) return new Response("too big", { status: 413 });
        await env.KV.put("cost-snapshot", body);
        return new Response("ok");
      }
      const v = await env.KV.get("cost-snapshot");
      return new Response(v || "{}", { headers: { "content-type": "application/json" } });
    }

    // Mac-side burn snapshot (2026-08-24): the operator's Mac is the fleet's single
    // biggest token burner (~$9-10K/wk list) and was tracked NOWHERE — the
    // audit found it by hand-scanning ~/.claude session ledgers. The Mac can't
    // be a box (no tailnet ssh from the hub) but it can push here like the hub
    // does: bin/mac/mac-burn-push.sh scans the local ledgers and POSTs a daily
    // rollup. Same auth + size cap as the other snapshots.
    if (p === "/api/mac-burn") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      if (req.method === "POST") {
        const body = await req.text();
        if (body.length > 512e3) return new Response("too big", { status: 413 });
        await env.KV.put("mac-burn", body);
        return new Response("ok");
      }
      const v = await env.KV.get("mac-burn");
      return new Response(v || "{}", { headers: { "content-type": "application/json" } });
    }

    // Liveness ping: crontab curl from each box. Optional JSON body = metrics.
    let m = p.match(/^\/api\/ping\/([a-z0-9-]+)$/);
    if (m) {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      let metrics = null;
      if (req.method === "POST") { try { metrics = await req.json(); } catch {} }
      await env.KV.put(`ping:${m[1]}`, JSON.stringify({ ts: now(), metrics }));
      // A name outside the expected set is never walked by `scheduled`, so its
      // silence could never page. Say so (damped hourly) instead of storing it
      // and moving on. Still stored and still "ok": the ping script is
      // fail-quiet, so a 4xx would change nothing on the box.
      if (!(await expectedBoxes(env)).includes(m[1])) {
        await maybeAlert(env, `unknown:${m[1]}`,
          `🚨 WATCHDOG: ping from unknown box ${m[1]} — it is not in the registry's expected_boxes or worker/watchdog/src/boxes.json, so its silence would never page. Add it to the registry (and its cron ping line) or stop its ping.`);
      }
      return new Response("ok");
    }

    // Hub pushes its compact fleet-status JSON here each cycle.
    if (p === "/api/status" && req.method === "POST") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      const body = await req.text();
      if (body.length > 64000) return new Response("too big", { status: 413 });
      await env.KV.put("status:fleet", JSON.stringify({ ts: now(), body }));
      return new Response("ok");
    }

    // Read-only status view (works while the hub is down; age labeled).
    if (p === "/api/status" || p === "/status") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      const raw = await env.KV.get("status:fleet");
      const pings = {};
      for (const b of await expectedBoxes(env)) {
        const v = await env.KV.get(`ping:${b}`);
        pings[b] = v ? `${min(now() - JSON.parse(v).ts)}m ago` : "never";
      }
      const s = raw ? JSON.parse(raw) : null;
      // Own try/catch: this view must keep answering while anything else is broken.
      let standby = null;
      try { standby = await listStandbys(env, now()); } catch {}
      return Response.json({
        status_age_min: s ? min(now() - s.ts) : null,
        fleet: s ? JSON.parse(s.body) : "no status pushed yet",
        pings,
        standby,
      });
    }

    // Warm-standby report (BH-401): a standby POSTs {of, snapshot, ok}; the
    // watchdog stamps ts. Shape and reader live in standby.js.
    m = p.match(/^\/api\/standby\/([a-z0-9-]+)$/);
    if (m && req.method === "POST") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      if (!BOXES.includes(m[1])) return new Response("unknown box", { status: 400 });
      const body = await req.text();
      if (body.length > 2048) return new Response("too big", { status: 400 });
      let v;
      try { v = JSON.parse(body); } catch { return new Response("bad json", { status: 400 }); }
      if (!v || typeof v !== "object" || Array.isArray(v)) return new Response("bad json", { status: 400 });
      await env.KV.put(standbyKey(m[1]), JSON.stringify({ ts: now(), of: v.of, snapshot: v.snapshot, ok: v.ok === true }));
      return new Response("ok");
    }
    if (p === "/api/standby" && req.method === "GET") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      return Response.json(await listStandbys(env, now()));
    }

    // Command queue: enqueue (worker cron / future telegram buttons write here
    // through this same route with the shared secret).
    if (p === "/api/command" && req.method === "POST") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      const c = await req.json();
      const id = `${now()}-${crypto.randomUUID().slice(0, 8)}`;
      await env.KV.put(`cmd:${id}`, JSON.stringify({ id, ts: now(), type: c.type, arg: c.arg ?? null }), { expirationTtl: 86400 });
      return Response.json({ id });
    }
    // Hub poller: list pending commands. Consuming is explicit (ack) so a
    // crashed poller never loses a command.
    if (p === "/api/commands") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      const l = await env.KV.list({ prefix: "cmd:" });
      const out = [];
      for (const k of l.keys) { const v = await env.KV.get(k.name); if (v) out.push(JSON.parse(v)); }
      return Response.json(out.sort((a, b) => a.ts - b.ts));
    }
    m = p.match(/^\/api\/commands\/ack\/([0-9a-z-]+)$/);
    if (m && req.method === "POST") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      await env.KV.delete(`cmd:${m[1]}`);
      return new Response("ok");
    }

    // K2 — PROGRESS stamps (docs/OUTSIDE-DEADMAN.md). The hub pushes
    // per-(project, lane) progress and each detector's last run
    // (bin/progress-push.sh); step 5 of `scheduled` judges them. The payload's
    // cfg is the thresholds (the hub's settings rows): clamped, stored only when
    // valid, and a change pages once with the diff (progress.js acceptPush).
    const readBodyObj = async () => {
      const body = await req.text();
      if (body.length > 200000) return { err: new Response("too big", { status: 413 }) };
      let v;
      try { v = JSON.parse(body); } catch { return { err: new Response("bad json", { status: 400 }) }; }
      if (!v || typeof v !== "object" || Array.isArray(v)) return { err: new Response("bad json", { status: 400 }) };
      return { v };
    };
    if (p === "/api/progress/dry-run" && req.method === "POST") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      const { v, err } = await readBodyObj();
      if (err) return err;
      return Response.json(await dryRun(env, v, now(), BOXES));
    }
    if (p === "/api/progress") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      if (req.method === "POST") {
        const { v, err } = await readBodyObj();
        if (err) return err;
        return new Response(await acceptPush(env, v, now()));
      }
      return Response.json(await progressView(env, now()));
    }
    // A stamp from OUTSIDE the fleet (the share-mirror workflow runs on GitHub,
    // where no box can see it finish). Its OWN credential, STAMP_SECRET, which
    // opens nothing else — HARNESS_SECRET does not open this route, and with no
    // STAMP_SECRET set it is closed. Only a detector the stored config names can
    // be stamped, so a leaked stamp secret cannot invent keys. The worker's
    // clock, never the caller's.
    m = p.match(/^\/api\/stamp\/([^/]+)$/);
    if (m && req.method === "POST") {
      const s = url.searchParams.get("s");
      if (!env.STAMP_SECRET || !s || s !== env.STAMP_SECRET) return new Response("no", { status: 403 });
      let cfg = null;
      try { cfg = JSON.parse(await env.KV.get(PROGRESS_CFG_KEY)); } catch {}
      if (!NAME_RE.test(m[1]) || !cfg || !cfg.detectors || !Object.hasOwn(cfg.detectors, m[1])) {
        return new Response("not a configured detector", { status: 404 });
      }
      await env.KV.put(`${STAMP_PREFIX}${m[1]}`, JSON.stringify({ ts: now() }));
      return new Response("ok");
    }

    // Authed end-to-end alert test — proves the worker's OWN Telegram secrets
    // work (a typo'd secret would otherwise fail silently until a real alert).
    if (p === "/api/test-alert" && req.method === "POST") {
      if (!authed(url, env)) return new Response("no", { status: 403 });
      await tg(env, "🐶 harness-watchdog: test alert — Telegram path verified.");
      return new Response("ok");
    }

    return new Response("harness-watchdog", { status: p === "/" ? 200 : 404 });
  },

  async scheduled(_ev, env) {
    // 1. Per-box liveness.
    for (const b of await expectedBoxes(env)) {
      const v = await env.KV.get(`ping:${b}`);
      if (!v) continue; // never pinged: not armed for this box yet
      const age = now() - JSON.parse(v).ts;
      if (age > PING_STALE_MIN * 60000) {
        await maybeAlert(env, `ping:${b}`, `🚨 WATCHDOG: ${b} silent for ${min(age)} min (no ping).`);
      } else {
        await clearAlert(env, `ping:${b}`, `✅ WATCHDOG: ${b} pinging again.`);
      }
    }

    // 2. Hub lanes: hub pings fine but stopped pushing status = harness dead
    //    inside (e.g. API key down) — exactly the case the operator named.
    const hubPing = await env.KV.get(`ping:${HUB}`);
    const st = await env.KV.get("status:fleet");
    if (hubPing && st) {
      const hubFresh = now() - JSON.parse(hubPing).ts < PING_STALE_MIN * 60000;
      const stAge = now() - JSON.parse(st).ts;
      if (hubFresh && stAge > STATUS_STALE_MIN * 60000) {
        const fired = await maybeAlert(env, "hub-lanes",
          `🚨 WATCHDOG: hub box is alive but pushed no fleet status for ${min(stAge)} min — harness lanes look dead (check Claude auth / cron on the hub).`);
        if (fired) {
          // Self-heal first: queue a medic wake for the hub's command poller.
          const id = `${now()}-medic`;
          await env.KV.put(`cmd:${id}`, JSON.stringify({ id, ts: now(), type: "medic", arg: "lanes-stale" }), { expirationTtl: 86400 });
        }
      } else if (stAge <= STATUS_STALE_MIN * 60000) {
        await clearAlert(env, "hub-lanes", `✅ WATCHDOG: hub fleet status flowing again.`);
      }
      // 2b. Wedged build lane: a queued job aging while its pool is enabled
      //     means spawns are failing silently (the 08-12 project-3 churn signature).
      try {
        const fleet = JSON.parse(JSON.parse(st).body);
        for (const [proj, d] of Object.entries(fleet.projects ?? {})) {
          if (d.pool && (d.oldest_queued_min ?? 0) > 40) {
            await maybeAlert(env, `queue:${proj}`, `🚨 WATCHDOG: ${proj} has a build queued ${d.oldest_queued_min} min without starting — pool lane looks wedged.`);
          } else {
            await clearAlert(env, `queue:${proj}`, null);
          }
        }
        // 2c. Stale owed tickets PERSISTING: the hub's hourly sweep force-wakes
        //     triage on these; if a count survives 3+ hours of that self-heal,
        //     the audit lane itself is broken — page (TK-49 sat 20h unowned).
        for (const [proj, n] of Object.entries(fleet.stale_owed ?? {})) {
          const key = `stale:${proj}`;
          if ((n ?? 0) > 0) {
            const firstSeen = await env.KV.get(`firstseen:${key}`);
            if (!firstSeen) { await env.KV.put(`firstseen:${key}`, String(now())); continue; }
            if (now() - Number(firstSeen) > 3 * 3600000) {
              await maybeAlert(env, key, `🚨 WATCHDOG: ${proj} has ${n} ticket(s) our side owes action on, stale despite 3h+ of forced triage — the audit lane isn't clearing them.`);
            }
          } else {
            await env.KV.delete(`firstseen:${key}`);
            await clearAlert(env, key, null);
          }
        }
      } catch {}
    }

    // 3. Dead-hub resurrection — SHIPS DISABLED (cfg:orgo_restart != "on")
    //    until the restart endpoint is verified against a non-hub box.
    if (hubPing) {
      const age = now() - JSON.parse(hubPing).ts;
      if (age > HUB_DEAD_MIN * 60000) {
        const enabled = (await env.KV.get("cfg:orgo_restart")) === "on";
        const cid = await env.KV.get("cfg:orgo_computer_id");
        const lastR = await env.KV.get("alerted:orgo-restart");
        if (enabled && cid && env.ORGO_API_KEY && (!lastR || now() - Number(lastR) > 6 * 3600000)) {
          await env.KV.put("alerted:orgo-restart", String(now()));
          const r = await fetch(`https://www.orgo.ai/api/computers/${cid}/restart`, {
            method: "POST", headers: { Authorization: `Bearer ${env.ORGO_API_KEY}` },
          }).catch(() => null);
          await tg(env, r && r.ok
            ? `🔁 WATCHDOG: hub silent ${min(age)} min — issued Orgo restart, watch for recovery.`
            : `🚨 WATCHDOG: hub silent ${min(age)} min and Orgo restart FAILED — box likely wedged, needs you.`);
        } else {
          await maybeAlert(env, "hub-dead", `🚨🚨 WATCHDOG: HUB silent for ${min(age)} min. Everything is blind until it returns.`);
        }
      } else {
        await clearAlert(env, "hub-dead", `✅ WATCHDOG: hub back.`);
      }
    }

    // 4. Warm-standby failover (BH-401). Own try/catch: a failover bug must never break steps 1-3.
    try { await failoverTick(env, now()); } catch (e) { console.error("failoverTick", e); }

    // 5. K2 progress (progress.js). LAST and in its own try/catch: nothing in
    //    it may cost steps 1-4, which are the liveness signal.
    try { await progressTick(env, now(), BOXES); } catch (e) { console.error("progressTick", e); }
  },
};
