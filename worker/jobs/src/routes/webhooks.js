// webhooks routes — the three routes the bearer does not open.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195, verbatim. BH-4079 added the Jira and Linear routes
// and moved GitHub's INSERT into recordWake, which keeps every status code and
// response key GitHub answered and adds `vendor` plus per-delivery dedupe on
// X-GitHub-Delivery. BH-5667 runs the merge-queue intake (Mergify batch
// drafts) in the github receiver's batch. src/index.js holds the ordered table
// that decides which of these runs.

import { json } from "../lib/http.js";
import {
  WAKE_REPO_RE, hmacSha256Hex, hexEqual, wakeOf,
} from "../lib/core.js";
import {
  deliveryIdOf, verifyJira, verifyLinear, linearFresh, jiraKeyOf, linearKeyOf,
  keyPrefix, jiraWakeOf, linearWakeOf, readWebhookConfig,
} from "../lib/tracker-webhooks.js";
import { mapMergeQueueDelivery } from "../lib/merge-queue-intake.js";
import { recordGithubGate } from "../lib/pr-gate-intake.js";
import { recordPrRecord } from "../lib/pr-record-intake.js";

// recordWake — the one write every receiver makes (BH-4079). With a delivery
// id, the delivery row and the wake row go in ONE env.DB.batch (one D1
// transaction): the wake INSERT only runs `WHERE changes() = 1`, i.e. when the
// delivery row was new, so a vendor redelivery in a later minute is a duplicate
// and "delivery recorded, no wake" can never commit. A throw is the caller's
// 500, and nothing was committed for the retry to trip on. Without a delivery
// id it is the pre-BH-4079 single INSERT: minute dedupe only.
// After a commit, a bounded best-effort prune of delivery ids older than keepS.
// BH-5667: `extra` is the merge-queue intake's statements, run in the SAME
// batch after the wake row (the `changes() = 1` guard still reads the delivery
// row, because it runs right after it). Jira and Linear pass none, and with
// none every path below is the one it was. `queueRows` counts the rows they
// changed.
async function recordWake(env, t, { vendor, deliveryId, repo, kind, key, ev, keepS, extra = [] }) {
  const minute = t.slice(0, 16) + ":00Z";
  const wakeSql = (guard) => `INSERT INTO wakes (repo, kind, key, event, minute, at)
         ${guard ? "SELECT ?1,?2,?3,?4,?5,?6 WHERE changes() = 1" : "VALUES (?1,?2,?3,?4,?5,?6)"}
         ON CONFLICT(repo, kind, key, minute) DO NOTHING`;
  let duplicate, pruned, queueRows = 0;
  if (deliveryId) {
    const [d, w, ...q] = await env.DB.batch([
      deliveryStmt(env, vendor, deliveryId, t),
      env.DB.prepare(wakeSql(true)).bind(repo, kind, key, ev, minute, t),
      ...extra,
    ]);
    duplicate = changesOf(d) === 0 || changesOf(w) === 0;
    queueRows = q.reduce((n, r) => n + changesOf(r), 0);
    pruned = await pruneDeliveries(env, t, keepS);
  } else if (extra.length) {
    const [w, ...q] = await env.DB.batch([env.DB.prepare(wakeSql(false)).bind(repo, kind, key, ev, minute, t), ...extra]);
    duplicate = changesOf(w) === 0;
    queueRows = q.reduce((n, r) => n + changesOf(r), 0);
  } else {
    const ins = await env.DB.prepare(wakeSql(false)).bind(repo, kind, key, ev, minute, t).run();
    duplicate = ((ins.meta && ins.meta.changes) || 0) === 0;
  }
  const out = {
    ok: true, vendor, wake: { repo, kind, key, event: ev, minute, at: t },
    duplicate, as_of: t,
  };
  if (queueRows > 0) out.queue = { rows: queueRows };
  if (pruned === false) out.pruned = false;
  return out;
}

const changesOf = (r) => (r && r.meta && r.meta.changes) || 0;
const deliveryStmt = (env, vendor, deliveryId, t) =>
  env.DB.prepare(`INSERT OR IGNORE INTO webhook_deliveries (vendor, delivery_id, at) VALUES (?1,?2,?3)`)
    .bind(vendor, deliveryId, t);

// A bounded best-effort prune of delivery ids older than keepS, after a commit.
async function pruneDeliveries(env, t, keepS) {
  const cutoff = new Date(Date.parse(t) - keepS * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
  try {
    await env.DB.prepare(
      `DELETE FROM webhook_deliveries WHERE rowid IN
         (SELECT rowid FROM webhook_deliveries WHERE at < ?1 ORDER BY at LIMIT 100)`
    ).bind(cutoff).run();
    return true;
  } catch { return false; }
}

// BH-5667: a merge-queue delivery that wakes nothing (a check_run.created on a
// batch draft). The delivery row and the queue rows go in ONE batch, delivery
// first, so a throw commits neither and GitHub's redelivery finds no
// "already seen" row. `queue.rows` is the rows the statements changed: 0 on a
// replay of what is already stored.
async function recordQueueRows(env, t, { deliveryId, stmts, keepS }) {
  let duplicate = false, rows, pruned;
  if (deliveryId) {
    const [d, ...q] = await env.DB.batch([deliveryStmt(env, "github", deliveryId, t), ...stmts]);
    duplicate = changesOf(d) === 0;
    rows = q.reduce((n, r) => n + changesOf(r), 0);
    pruned = await pruneDeliveries(env, t, keepS);
  } else {
    rows = (await env.DB.batch(stmts)).reduce((n, r) => n + changesOf(r), 0);
  }
  const out = { ok: true, vendor: "github", queue: { rows }, duplicate, as_of: t };
  if (pruned === false) out.pruned = false;
  return out;
}

// The tail both tracker receivers share once a delivery is signed and parsed:
// read the settings rows, route, edge-filter, record.
async function trackerWake(env, t, vendor, payload, headers, key, mapper, fresh) {
  if (!key) return json(202, { ok: true, ignored: "no issue key" });
  const cfg = await readWebhookConfig(env, vendor, keyPrefix(key));
  if (fresh) {
    const stale = fresh(cfg);
    if (stale) return json(stale.status, { error: stale.error });
  }
  const w = mapper(payload, cfg);
  if (w.ignored) return json(202, { ok: true, ignored: w.ignored });
  if (cfg.routeMalformed) return json(202, { ok: true, ignored: "route row malformed" });
  if (!cfg.repo) return json(202, { ok: true, ignored: "unrouted" });
  try {
    return json(200, await recordWake(env, t, {
      vendor, deliveryId: deliveryIdOf(vendor, headers), repo: cfg.repo,
      kind: "issue", key: w.key, ev: w.event, keepS: cfg.keepS,
    }));
  } catch (e) {
    return json(500, { error: "wake not recorded", detail: String((e && e.message) || e).slice(0, 200) });
  }
}

const parseObj = (raw) => {
  try { const p = JSON.parse(raw); return p && typeof p === "object" && !Array.isArray(p) ? p : null; } catch { return null; }
};

export const routes = [
  // ── POST /webhooks/github — open to the bearer-less vendor, like jira/linear ─
  // It is handled BEFORE the HARNESS_SECRET check on purpose: GitHub cannot
  // send our bearer, so this route carries its own credential (an HMAC over
  // the raw body, keyed on GITHUB_WEBHOOK_SECRET) and everything below stays
  // bearer-only. Nothing here reads `body` — the raw TEXT is what the
  // signature covers, and re-serialising a parsed object would verify a
  // different string than the one that was signed.
  //
  // INERT UNTIL AN OPERATOR ARMS IT. No secret = 503, never "allow": a
  // receiver that accepts unsigned deliveries the moment its secret goes
  // missing is worse than no receiver, because it looks like one.
  [
    "*", "/webhooks/github",
    async ({ req, env, t }) => {
      if (req.method !== "POST") return json(405, { error: "POST only" });
      if (!env.GITHUB_WEBHOOK_SECRET) {
        return json(503, { error: "webhook receiver not configured (GITHUB_WEBHOOK_SECRET unset)" });
      }
      const sig = req.headers.get("x-hub-signature-256") || "";
      const raw = await req.text().catch(() => "");
      const want = "sha256=" + await hmacSha256Hex(env.GITHUB_WEBHOOK_SECRET, raw);
      if (!hexEqual(sig, want)) return json(401, { error: "bad signature" });

      const event = String(req.headers.get("x-github-event") || "").slice(0, 64);
      // GitHub's own "is this hook alive" delivery. A real, signed, correct
      // request that describes nothing — 200 with no row, or the hook shows as
      // failing in the repo settings forever.
      if (event === "ping") return json(200, { ok: true, pong: true });

      let payload = {};
      try { payload = JSON.parse(raw); } catch { payload = {}; }
      const repo = String((payload && payload.repository && payload.repository.full_name) || "");
      if (!WAKE_REPO_RE.test(repo)) return json(202, { ok: true, ignored: "no repository slug" });
      // BH-4954: the PR gate facts this delivery proves (head/draft/closed,
      // hotfix, CI green, a thread HOLD). Before wakeOf on purpose:
      // converted_to_draft and the hotfix label are deliveries wakeOf drops.
      // Keyed on the delivery id, so none means no row. Never throws, and the
      // response below is unchanged either way.
      await recordGithubGate(env, t, event, payload, deliveryIdOf("github", req.headers));
      // BH-8067 C2: the fleet's PR record (pr_records) from the payload. Before
      // wakeOf for the same reason: check_run.created is a delivery it drops.
      // Never throws; the response below is unchanged either way.
      await recordPrRecord(env, t, event, payload);
      const w = wakeOf(event, payload);
      const wakes = Boolean(w && w.key);
      try {
        // BH-5667: a Mergify batch draft's rows ride the same batch as the
        // delivery row. null for every other delivery, with no read.
        const mq = (await mapMergeQueueDelivery(env.DB, event, payload, { repo, at: t })) || [];
        // An event nobody owns is ACCEPTED and dropped. 202, not 400: a hook
        // subscribed a little too widely must not show up in GitHub's delivery
        // log as a wall of red, or the one real failure is invisible in it.
        if (!wakes && !mq.length) return json(202, { ok: true, ignored: event || "unknown" });
        // Only the retention row matters here; GitHub routes on the slug.
        const keepS = (await readWebhookConfig(env, "github", "")).keepS;
        const deliveryId = deliveryIdOf("github", req.headers);
        if (!wakes) return json(200, await recordQueueRows(env, t, { deliveryId, stmts: mq, keepS }));

        const pay = payload && typeof payload === "object" ? payload : {};
        const action = String(pay.action || "");
        const ev = w.event || (/^[a-z_]{1,32}$/.test(action) ? `${event}.${action}` : event);
        return json(200, await recordWake(env, t, {
          vendor: "github", deliveryId, repo, kind: w.kind, key: w.key, ev, keepS, extra: mq,
        }));
      } catch (e) {
        return json(500, { error: wakes ? "wake not recorded" : "queue rows not recorded", detail: String((e && e.message) || e).slice(0, 200) });
      }
    },
  ],

  // ── POST /webhooks/jira and /webhooks/linear (BH-4079) ──────────────────
  // The same contract as /webhooks/github: inert (503) until the vendor's
  // secret is set, 401 on a bad signature BEFORE any parse or settings read,
  // 405 for anything but POST. A delivery reaches a harness repo only through
  // a `webhook_route.<vendor>.<project|team, lowercased>` settings row holding
  // an owner/repo slug; no row is 202 `unrouted` with no write. The wake is an
  // ordinary kind=issue row keyed on the ticket key, so bin/wake-loop.sh and
  // the triage gate treat it exactly as they treat a GitHub issue wake.
  [
    "*", "/webhooks/jira",
    async ({ req, env, t }) => {
      if (req.method !== "POST") return json(405, { error: "POST only" });
      const raw = await req.text().catch(() => "");
      const bad = await verifyJira(env, req.headers, raw);
      if (bad) return json(bad.status, { error: bad.error });
      const payload = parseObj(raw);
      if (!payload) return json(202, { ok: true, ignored: "not a JSON object" });
      return trackerWake(env, t, "jira", payload, req.headers, jiraKeyOf(payload), jiraWakeOf, null);
    },
  ],
  [
    "*", "/webhooks/linear",
    async ({ req, env, t }) => {
      if (req.method !== "POST") return json(405, { error: "POST only" });
      const raw = await req.text().catch(() => "");
      const bad = await verifyLinear(env, req.headers, raw);
      if (bad) return json(bad.status, { error: bad.error });
      const payload = parseObj(raw);
      if (!payload) return json(202, { ok: true, ignored: "not a JSON object" });
      // The replay window is a settings row, so the freshness check runs inside
      // trackerWake right after the one settings read — and before anything is
      // decided or written.
      return trackerWake(env, t, "linear", payload, req.headers, linearKeyOf(payload), linearWakeOf,
        (cfg) => linearFresh(payload, t, cfg.maxAgeS));
    },
  ],
];
