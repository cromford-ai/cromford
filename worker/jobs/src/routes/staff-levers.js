// staff lever routes — BH-9187 (C0): the outcome ledger of the staff agent
// contract (schema.d/202611100721-bh-9187-staff-contract.sql). Every staff
// agent owns one metric; every lever action it takes is a row, and a later
// metric sample decides whether the metric moved.
//
// POST /api/staff/levers/actions {agent, lever, target, dryRun, metric,
//   metricBefore, key, detail?} records one action. agent is on the roster
//   (404 else). metricBefore is a finite number (400 else, never a default).
//   action_key = sha256(agent|lever|key): the same key and the same payload is
//   200 existing:true; the same key with another target, dryRun, metric or
//   metricBefore is 409 key_mismatch.
// POST /api/staff/levers/metric {agent, metric, value, detail?} stores one
//   sample, then settles in ONE statement every open, non-dry-run action of
//   that agent and metric that is at least staff.settle_hours old (row
//   staff.settle_hours; fallback 24 when the row is absent, not a number or
//   not positive, and then the answer says settle_hours_fallback: true).
//   moved = 1 when the sample is lower than metric_before: every contract
//   metric is lower-is-better. A settled action is never settled again.
// GET /api/staff/levers/scorecard?agent=<a>[&days=1..staff.scorecard_days_max
//   (30)][&metric=m]; no days= is staff.scorecard_days (7)
//   the agent's metric (the staff.<agent>.metric row unless metric= is given),
//   its target row, its level (the staff_level rule), the latest sample (metric_now), the latest
//   sample at or before now - days (metric_then), and over the window: actions
//   (not dry run), dry_runs, settled, moved and precision = moved / settled
//   (null when 0 settled, never 0). The three reads run in parallel.
// Note: docs/notes/2026-11-06-BH-9187-staff-contract.md.

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const METRIC_RE = /^[a-z][a-z0-9_]{0,63}$/;
const TEXT_MAX = 200;
const DETAIL_MAX = 2000;
// Fallback of the settings row staff.settle_hours (seeded 24).
const SETTLE_HOURS_DEFAULT = 24;
// Fallbacks of the settings rows staff.scorecard_days (seeded 7, the window
// when days= is absent) and staff.scorecard_days_max (seeded 30).
const DAYS_DEFAULT = 7;
const DAYS_MAX = 30;

const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
const textOf = (v) => (typeof v === "string" && v.trim() !== "" && v.trim().length <= TEXT_MAX ? v.trim() : null);
const metricOf = (v) => (typeof v === "string" && METRIC_RE.test(v.trim()) ? v.trim() : null);
const numberOf = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
// detail is optional: absent is null, a string up to DETAIL_MAX is kept, any
// other value is a 400 (undefined in the answer).
const detailOf = (v) => (v === undefined || v === null ? null : typeof v === "string" && v.length <= DETAIL_MAX ? v : undefined);
const isoSeconds = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const sha256 = async (s) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))]
  .map((b) => b.toString(16).padStart(2, "0")).join("");

const onRoster = (env, name) => env.DB.prepare(`SELECT name FROM staff_agents WHERE name=?1`).bind(name).first();
const actionOut = (r) => ({
  id: r.id, action_key: r.action_key, agent: r.agent, lever: r.lever, target: r.target, dry_run: r.dry_run === 1,
  metric: r.metric, metric_before: r.metric_before, acted_at: r.acted_at, settled_at: r.settled_at,
  metric_after: r.metric_after, moved: r.moved,
});
// THE level rule, the same as bin/lib/staff-contract.sh staff_level: trimmed
// and lowercased, observe | file | act; anything else is observe.
const levelOf = (v) => {
  const l = typeof v === "string" ? v.trim().toLowerCase() : "";
  return l === "file" || l === "act" ? l : "observe";
};
const sampleOut = (r) => (r ? { value: r.value, sampled_at: r.sampled_at } : null);

// The statements the scorecard and the settle run, exported for the EXPLAIN test.
export const SQL = {
  now: `SELECT value, sampled_at FROM staff_metric_samples WHERE agent=?1 AND metric=?2
         ORDER BY sampled_at DESC LIMIT 1`,
  then: `SELECT value, sampled_at FROM staff_metric_samples WHERE agent=?1 AND metric=?2 AND sampled_at <= ?3
          ORDER BY sampled_at DESC LIMIT 1`,
  counts: `SELECT count(*) AS n,
                  coalesce(sum(dry_run = 1), 0) AS dry_runs,
                  coalesce(sum(dry_run = 0 AND settled_at IS NOT NULL), 0) AS settled,
                  coalesce(sum(dry_run = 0 AND moved = 1), 0) AS moved
             FROM staff_lever_actions WHERE agent=?1 AND acted_at >= ?2`,
  settle: `UPDATE staff_lever_actions
              SET settled_at=?1, metric_after=?2, moved=CASE WHEN ?2 < metric_before THEN 1 ELSE 0 END
            WHERE agent=?3 AND metric=?4 AND settled_at IS NULL AND dry_run = 0 AND acted_at <= ?5`,
};

// A positive integer row, else the fallback.
const intRow = (byKey, k, def) => {
  const row = byKey.get(k);
  const v = row ? String(row.value).trim() : "";
  return /^\d+$/.test(v) && Number(v) > 0 ? Number(v) : def;
};

// staff.settle_hours: a positive number, else the fallback (and fallback: true).
const settleHours = (byKey) => {
  const row = byKey.get("staff.settle_hours");
  const v = row ? String(row.value).trim() : "";
  if (/^\d+(\.\d+)?$/.test(v) && Number(v) > 0) return { hours: Number(v), fallback: false };
  return { hours: SETTLE_HOURS_DEFAULT, fallback: true };
};

export const routes = [
  // ── POST /api/staff/levers/actions — one lever action, idempotent per key ──
  [
    "POST", "/api/staff/levers/actions",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const name = agentOf(b.agent);
      if (name === null) return bad("agent");
      const lever = textOf(b.lever);
      if (lever === null) return bad("lever");
      const target = textOf(b.target);
      if (target === null) return bad("target");
      if (typeof b.dryRun !== "boolean") return bad("dryRun");
      const metric = metricOf(b.metric);
      if (metric === null) return bad("metric");
      const before = numberOf(b.metricBefore);
      if (before === null) return bad("metricBefore");
      const key = textOf(b.key);
      if (key === null) return bad("key");
      const detail = detailOf(b.detail);
      if (detail === undefined) return bad("detail");
      const actionKey = await sha256(`${name}|${lever}|${key}`);
      const dry = b.dryRun ? 1 : 0;

      return d1Guarded("staff_lever_actions", async () => {
        if (!(await onRoster(env, name))) return json(404, { error: "agent not found" });
        const res = await env.DB.prepare(
          `INSERT OR IGNORE INTO staff_lever_actions
             (action_key, agent, lever, target, dry_run, metric, metric_before, detail, acted_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`
        ).bind(actionKey, name, lever, target, dry, metric, before, detail, t).run();
        const row = await env.DB.prepare(`SELECT * FROM staff_lever_actions WHERE action_key=?1`).bind(actionKey).first();
        if (!row) return json(500, { error: "action_unresolved", action_key: actionKey });
        if (changesOf(res) === 1) return json(200, { ok: true, action: actionOut(row) });
        const same = row.target === target && row.dry_run === dry && row.metric === metric && row.metric_before === before;
        if (!same) return json(409, { error: "key_mismatch", action: actionOut(row) });
        return json(200, { ok: true, existing: true, action: actionOut(row) });
      });
    },
  ],

  // ── POST /api/staff/levers/metric — one sample; settles the due actions ────
  [
    "POST", "/api/staff/levers/metric",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const name = agentOf(b.agent);
      if (name === null) return bad("agent");
      const metric = metricOf(b.metric);
      if (metric === null) return bad("metric");
      const value = numberOf(b.value);
      if (value === null) return bad("value");
      const detail = detailOf(b.detail);
      if (detail === undefined) return bad("detail");

      return d1Guarded("staff_metric_samples", async () => {
        const [agent, { byKey }] = await Promise.all([onRoster(env, name), settingsRows(env)]);
        if (!agent) return json(404, { error: "agent not found" });
        const sh = settleHours(byKey);
        const cutoff = isoSeconds(Date.parse(t) - sh.hours * 3600e3);
        // One batch: the sample and the settle land together, so a retry after
        // a failed settle never stores the sample twice.
        const [ins, upd] = await env.DB.batch([
          env.DB.prepare(
            `INSERT INTO staff_metric_samples (agent, metric, value, detail, sampled_at) VALUES (?1, ?2, ?3, ?4, ?5)`
          ).bind(name, metric, value, detail, t),
          env.DB.prepare(SQL.settle).bind(t, value, name, metric, cutoff),
        ]);
        const sampleId = ins && ins.meta ? ins.meta.last_row_id : null;
        return json(200, {
          ok: true, sample_id: sampleId, settled: changesOf(upd), settle_hours: sh.hours,
          ...(sh.fallback ? { settle_hours_fallback: true } : {}),
        });
      });
    },
  ],

  // ── GET /api/staff/levers/scorecard — metric now vs then, precision ────────
  [
    "GET", "/api/staff/levers/scorecard",
    async ({ env, t, url }) => {
      const name = agentOf(url.searchParams.get("agent"));
      if (name === null) return bad("agent");
      const dq = url.searchParams.get("days");
      if (dq !== null && !/^\d+$/.test(dq)) return bad("days");
      const mq = url.searchParams.get("metric");
      if (mq !== null && metricOf(mq) === null) return bad("metric");

      return d1Guarded("staff_lever_actions", async () => {
        const [agent, { byKey }] = await Promise.all([onRoster(env, name), settingsRows(env)]);
        if (!agent) return json(404, { error: "agent not found" });
        const daysMax = intRow(byKey, "staff.scorecard_days_max", DAYS_MAX);
        const days = dq !== null ? Number(dq) : Math.min(intRow(byKey, "staff.scorecard_days", DAYS_DEFAULT), daysMax);
        if (days < 1 || days > daysMax) return bad("days");
        const row = (k) => (byKey.has(k) ? String(byKey.get(k).value) : null);
        const metric = mq !== null ? mq.trim() : metricOf(row(`staff.${name}.metric`));
        const targetRaw = row(`staff.${name}.target`);
        const target = targetRaw !== null && /^-?\d+(\.\d+)?$/.test(targetRaw.trim()) ? Number(targetRaw) : null;
        const since = isoSeconds(Date.parse(t) - days * 86400e3);
        const [now, then, c] = await Promise.all([
          metric ? env.DB.prepare(SQL.now).bind(name, metric).first() : null,
          metric ? env.DB.prepare(SQL.then).bind(name, metric, since).first() : null,
          env.DB.prepare(SQL.counts).bind(name, since).first(),
        ]);
        const n = Number(c.n), dryRuns = Number(c.dry_runs), settled = Number(c.settled), moved = Number(c.moved);
        return json(200, {
          ok: true, agent: name, days, metric: metric || null, target, level: levelOf(row(`staff.${name}.level`)),
          metric_now: sampleOut(now), metric_then: sampleOut(then),
          actions: n - dryRuns, dry_runs: dryRuns, settled, moved,
          precision: settled === 0 ? null : moved / settled,
        });
      });
    },
  ],
];
