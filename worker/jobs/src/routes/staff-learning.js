// staff learning routes — BH-6825 (Staff in Mission Control 4/4): the agent
// page's learning view over the BH-5563 loop tables
// (schema.d/202610170334-bh-6825-staff-learning.sql).
//
// GET /api/staff/learning?agent= is one agent's precision and noise over two
// windows (settings staff.learning.short_days and .long_days, default 7 and
// 30, measured on resolved_at, a row at the cutoff is in): merged, rejected,
// noise and total counts, agent-core precision() over the verdicts (merged =
// agree, rejected and noise = overrule) and noise / total. No outcome is null,
// never 0. With it: the pending promotion and its evidence (the applied
// outcomes since the agent's last level change, the history the loop's
// nextLevel() read, newest 20 with the true total), and the newest 5 human
// decisions with their reasons.
//
// GET /api/staff/learning/outcomes?agent=&days=&outcome=&before=&limit= is the
// rows behind one count, newest first, paged with the cursor
// before=<resolved_at>|<id>. limit is 1..staff.learning.page_max (default
// 100). A bad parameter is 400 naming it, never clamped.
//
// POST /api/staff/promotions/decide {id, decision, reason, actor} is the human
// decision on a pending staff_promotions row. approve raises the agent to
// to_level by the rules of POST /api/staff/agents/autonomy (never above the
// cap, an active agent, from the level the proposal was made at) and marks the
// promotion applied; void marks it void. Both record the reason in
// staff_promotion_decisions. Everything is one D1 batch, and every statement
// after the first needs the decision row the first one wrote, so a refusal
// writes nothing. archie or any staff agent as the actor is 403. A replay of
// the same decision is 200 existing:true; anything else on a decided row is
// 409 not_pending. A 200 carries the rows read back after the batch.

import { json, d1Guarded } from "../lib/http.js";
import { LEVELS, precision } from "../../../../agent-core/src/index.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const DAY_MS = 86400000;
const OUTCOMES = ["merged", "rejected", "noise"];
const EVIDENCE_MAX = 20;
const DECISIONS_MAX = 5;
const PAGE_HARD_MAX = 200;
// The documented fallbacks when a settings row is absent or junk.
const KNOBS = {
  short: { key: "staff.learning.short_days", def: 7, min: 1, max: 365 },
  long: { key: "staff.learning.long_days", def: 30, min: 1, max: 365 },
  page: { key: "staff.learning.page_max", def: 100, min: 1, max: PAGE_HARD_MAX },
  retention: { key: "retention.staff_outcomes.days", def: 180, min: 0, max: 3650 },
};
const BEFORE_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\|(\d{1,15})$/;
// A cursor past every row: the first page.
const FIRST_PAGE = ["9999-12-31T23:59:59Z", 0];

// THE agent identity: the same rule as staff.js (trim, lowercase).
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isoSeconds = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const rank = (level) => LEVELS.indexOf(level);

// The ISO-seconds time `days` days before t. A row with resolved_at >= it is in.
export const windowCutoff = (t, days) => isoSeconds(Date.parse(t) - days * DAY_MS);

// The knobs as { value, source }, from one read of their settings rows.
const readKnobs = async (env) => {
  const keys = Object.values(KNOBS).map((k) => k.key);
  const { results } = await env.DB.prepare(`SELECT key, value FROM settings WHERE key IN (?1, ?2, ?3, ?4)`)
    .bind(...keys).all();
  const byKey = new Map((results || []).map((r) => [r.key, r.value]));
  const out = {};
  for (const [name, k] of Object.entries(KNOBS)) {
    const raw = byKey.get(k.key);
    const v = typeof raw === "string" ? raw.trim() : "";
    out[name] = /^\d{1,4}$/.test(v) && Number(v) >= k.min && Number(v) <= k.max
      ? { value: Number(v), source: "settings" }
      : { value: k.def, source: "default" };
  }
  return out;
};
const readAgent = (env, name) =>
  env.DB.prepare(`SELECT name, autonomy, cap, status, updated_at FROM staff_agents WHERE name=?1`).bind(name).first();
// archie, or any staff agent: an agent never decides a promotion.
const isAgentActor = async (env, actor) => {
  const a = actor.toLowerCase();
  if (a === "archie") return true;
  return !!(await env.DB.prepare(`SELECT 1 AS x FROM staff_agents WHERE name=?1`).bind(a).first());
};

const outcomeRow = (r) => ({
  id: r.id, class: r.class, outcome: r.outcome, verdict: r.verdict, ticket_url: r.ticket_url,
  resolved_at: r.resolved_at, finding_id: r.finding_id === null || r.finding_id === undefined ? null : r.finding_id,
});
const decisionOut = (d) => ({
  id: d.id, promotion_id: d.promotion_id, decision: d.decision, from_level: d.from_level, to_level: d.to_level,
  reason: d.reason, actor: d.actor, decided_at: d.decided_at,
});
const promotionOut = (p) => ({
  id: p.id, agent: p.agent, status: p.status, from_level: p.from_level, to_level: p.to_level,
  agreements: p.agreements, created_at: p.created_at, decided_at: p.decided_at,
});
const agentOut = (a) => ({ name: a.name, autonomy: a.autonomy, cap: a.cap, status: a.status });

// One window's numbers from the GROUP BY outcome rows; `col` is its count column.
const windowOf = (knob, rows, col) => {
  const n = (w) => Number((rows.find((r) => r.outcome === w) || {})[col] || 0);
  const merged = n("merged");
  const rejected = n("rejected");
  const noise = n("noise");
  const total = merged + rejected + noise;
  const verdicts = [
    ...Array.from({ length: merged }, () => ({ verdict: "agree" })),
    ...Array.from({ length: rejected + noise }, () => ({ verdict: "overrule" })),
  ];
  return {
    days: knob.value, source: knob.source, merged, rejected, noise, total,
    agree: merged, overrule: rejected + noise,
    precision: precision(verdicts), noise_rate: total === 0 ? null : noise / total,
  };
};

export const routes = [
  // ── GET /api/staff/learning — one agent's windows, proposal and decisions ──
  [
    "GET", "/api/staff/learning",
    async ({ env, url, t }) => {
      const name = agentOf(url.searchParams.get("agent"));
      if (name === null) return bad("agent");
      return d1Guarded("staff_outcomes", async () => {
        // Independent reads, in parallel. The evidence reads the outcomes since
        // the agent's last level change; the subquery runs once (uncorrelated).
        const [knobs, agent, pending, evidence, evidenceTotal, decided] = await Promise.all([
          readKnobs(env),
          readAgent(env, name),
          env.DB.prepare(`SELECT * FROM staff_promotions WHERE agent=?1 AND status='pending'`).bind(name).first(),
          env.DB.prepare(
            `SELECT o.id, o.class, o.outcome, o.verdict, o.ticket_url, o.resolved_at, f.id AS finding_id
               FROM staff_outcomes o LEFT JOIN staff_findings f ON f.fingerprint = o.fingerprint
              WHERE o.agent=?1 AND o.applied=1 AND o.resolved_at >= (SELECT updated_at FROM staff_agents WHERE name=?1)
              ORDER BY o.resolved_at DESC, o.id DESC LIMIT ?2`
          ).bind(name, EVIDENCE_MAX + 1).all(),
          env.DB.prepare(
            `SELECT COUNT(*) AS n FROM staff_outcomes
              WHERE agent=?1 AND applied=1 AND resolved_at >= (SELECT updated_at FROM staff_agents WHERE name=?1)`
          ).bind(name).first(),
          env.DB.prepare(
            `SELECT * FROM staff_promotion_decisions WHERE agent=?1 ORDER BY decided_at DESC, id DESC LIMIT ?2`
          ).bind(name, DECISIONS_MAX + 1).all(),
        ]);
        if (!agent) return json(404, { error: "agent not found" });
        const cutShort = windowCutoff(t, knobs.short.value);
        const cutLong = windowCutoff(t, knobs.long.value);
        const { results: counts } = await env.DB.prepare(
          `SELECT outcome,
                  SUM(CASE WHEN resolved_at >= ?2 THEN 1 ELSE 0 END) AS short_n,
                  SUM(CASE WHEN resolved_at >= ?3 THEN 1 ELSE 0 END) AS long_n
             FROM staff_outcomes
            WHERE agent=?1 AND applied=1 AND resolved_at >= ?4
            GROUP BY outcome`
        ).bind(name, cutShort, cutLong, cutShort < cutLong ? cutShort : cutLong).all();
        const rows = counts || [];

        let promotion = null;
        if (pending) {
          const ev = (evidence.results || []).map(outcomeRow);
          promotion = {
            ...promotionOut(pending),
            stale: agent.autonomy !== pending.from_level,
            evidence: {
              rows: ev.slice(0, EVIDENCE_MAX), total: Number(evidenceTotal ? evidenceTotal.n : 0),
              truncated: ev.length > EVIDENCE_MAX, since: agent.updated_at,
            },
          };
        }
        const dec = (decided.results || []).map(decisionOut);
        return json(200, {
          agent: agentOut(agent),
          windows: [windowOf(knobs.short, rows, "short_n"), windowOf(knobs.long, rows, "long_n")],
          promotion,
          decisions: dec.slice(0, DECISIONS_MAX),
          decisions_more: dec.length > DECISIONS_MAX,
          page_max: knobs.page,
          retention_days: knobs.retention,
          as_of: t,
        });
      });
    },
  ],

  // ── GET /api/staff/learning/outcomes — the rows behind one count ───────────
  [
    "GET", "/api/staff/learning/outcomes",
    async ({ env, url, t }) => {
      const q = (k) => url.searchParams.get(k);
      const name = agentOf(q("agent"));
      if (name === null) return bad("agent");
      const d = q("days");
      if (!(d !== null && /^\d{1,3}$/.test(d) && Number(d) >= 1 && Number(d) <= 365)) return bad("days");
      const outcome = q("outcome") === null ? "all" : q("outcome");
      if (outcome !== "all" && !OUTCOMES.includes(outcome)) return bad("outcome");
      let before = FIRST_PAGE;
      if (q("before") !== null) {
        const m = BEFORE_RE.exec(q("before"));
        if (!m || !Number.isFinite(Date.parse(m[1])) || isoSeconds(Date.parse(m[1])) !== m[1]) return bad("before");
        before = [m[1], Number(m[2])];
      }
      const l = q("limit");
      if (l !== null && !(/^\d{1,3}$/.test(l) && Number(l) >= 1 && Number(l) <= PAGE_HARD_MAX)) return bad("limit");

      return d1Guarded("staff_outcomes", async () => {
        const [knobs, agent] = await Promise.all([readKnobs(env), readAgent(env, name)]);
        if (!agent) return json(404, { error: "agent not found" });
        if (l !== null && Number(l) > knobs.page.value) return json(400, { error: "limit", max: knobs.page.value });
        const limit = l === null ? knobs.page.value : Number(l);
        const { results } = await env.DB.prepare(
          `SELECT o.id, o.class, o.outcome, o.verdict, o.ticket_url, o.resolved_at, f.id AS finding_id
             FROM staff_outcomes o LEFT JOIN staff_findings f ON f.fingerprint = o.fingerprint
            WHERE o.agent=?1 AND o.applied=1 AND o.resolved_at >= ?2 AND (?3 = 'all' OR o.outcome = ?3)
              AND (o.resolved_at, o.id) < (?4, ?5)
            ORDER BY o.resolved_at DESC, o.id DESC LIMIT ?6`
        ).bind(name, windowCutoff(t, Number(d)), outcome, before[0], before[1], limit + 1).all();
        const got = (results || []).map(outcomeRow);
        const rows = got.slice(0, limit);
        const truncated = got.length > limit;
        const last = rows[rows.length - 1];
        return json(200, {
          agent: name, days: Number(d), outcome, limit, rows, truncated,
          next_before: truncated && last ? `${last.resolved_at}|${last.id}` : null,
        });
      });
    },
  ],

  // ── POST /api/staff/promotions/decide — a human approves or voids one ──────
  [
    "POST", "/api/staff/promotions/decide",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!(typeof b.id === "number" && Number.isInteger(b.id) && b.id > 0)) return bad("id");
      if (b.decision !== "approve" && b.decision !== "void") return bad("decision");
      const reason = typeof b.reason === "string" ? b.reason.trim() : "";
      if (reason.length < 1 || reason.length > 500) return bad("reason");
      const actor = typeof b.actor === "string" ? b.actor.trim() : "";
      if (actor.length < 1 || actor.length > 64) return bad("actor");

      return d1Guarded("staff_promotion_decisions", async () => {
        const readPromotion = () => env.DB.prepare(`SELECT * FROM staff_promotions WHERE id=?1`).bind(b.id).first();
        const readDecision = () =>
          env.DB.prepare(`SELECT * FROM staff_promotion_decisions WHERE promotion_id=?1`).bind(b.id).first();
        // The rows as they are now: the answer of every 200.
        const readBack = async (extra) => {
          const [p, dRow] = await Promise.all([readPromotion(), readDecision()]);
          const a = p ? await readAgent(env, p.agent) : null;
          if (!p || !dRow || !a || dRow.decision !== b.decision) return json(500, { error: "decide_unresolved" });
          return json(200, {
            ok: true, ...extra, promotion: promotionOut(p), decision: decisionOut(dRow), agent: agentOut(a),
          });
        };

        // Independent reads, in parallel.
        const [isAgent, p] = await Promise.all([isAgentActor(env, actor), readPromotion()]);
        if (isAgent) return json(403, { error: "agent_approver" });
        if (!p) return json(404, { error: "promotion not found" });
        if (p.status !== "pending") {
          const prior = await readDecision();
          if (prior && prior.decision === b.decision) return readBack({ existing: true });
          return json(409, { error: "not_pending", status: p.status });
        }

        // The decision row goes first, written only while every rule holds;
        // each later statement needs that row, so the batch is all or nothing.
        const stmts = [];
        if (b.decision === "approve") {
          stmts.push(env.DB.prepare(
            `INSERT INTO staff_promotion_decisions (promotion_id, agent, decision, from_level, to_level, reason, actor, decided_at)
             SELECT ?1, ?2, 'approve', ?3, ?4, ?5, ?6, ?7
              WHERE EXISTS (SELECT 1 FROM staff_promotions WHERE id=?1 AND agent=?2 AND status='pending')
                AND EXISTS (SELECT 1 FROM staff_agents
                             WHERE name=?2 AND autonomy=?3 AND status='active'
                               AND (CASE ?4 WHEN 'automation' THEN 0 WHEN 'augmentation' THEN 1 ELSE 2 END)
                                <= (CASE cap WHEN 'automation' THEN 0 WHEN 'augmentation' THEN 1 ELSE 2 END))
             ON CONFLICT(promotion_id) DO NOTHING`
          ).bind(p.id, p.agent, p.from_level, p.to_level, reason, actor, t));
          stmts.push(env.DB.prepare(
            `UPDATE staff_agents SET autonomy=?2, updated_at=?3, note=?4
              WHERE name=?1 AND autonomy=?5
                AND EXISTS (SELECT 1 FROM staff_promotion_decisions
                             WHERE promotion_id=?6 AND decision='approve' AND decided_at=?3 AND actor=?7)`
          ).bind(p.agent, p.to_level, t, `autonomy ${p.to_level} by ${actor} (promotion #${p.id})`, p.from_level, p.id, actor));
          stmts.push(env.DB.prepare(
            `UPDATE staff_promotions SET status='applied', decided_at=?2
              WHERE id=?1 AND status='pending'
                AND EXISTS (SELECT 1 FROM staff_promotion_decisions
                             WHERE promotion_id=?1 AND decision='approve' AND decided_at=?2 AND actor=?3)`
          ).bind(p.id, t, actor));
        } else {
          stmts.push(env.DB.prepare(
            `INSERT INTO staff_promotion_decisions (promotion_id, agent, decision, from_level, to_level, reason, actor, decided_at)
             SELECT ?1, ?2, 'void', ?3, ?4, ?5, ?6, ?7
              WHERE EXISTS (SELECT 1 FROM staff_promotions WHERE id=?1 AND agent=?2 AND status='pending')
             ON CONFLICT(promotion_id) DO NOTHING`
          ).bind(p.id, p.agent, p.from_level, p.to_level, reason, actor, t));
          stmts.push(env.DB.prepare(
            `UPDATE staff_promotions SET status='void', decided_at=?2
              WHERE id=?1 AND status='pending'
                AND EXISTS (SELECT 1 FROM staff_promotion_decisions
                             WHERE promotion_id=?1 AND decision='void' AND decided_at=?2 AND actor=?3)`
          ).bind(p.id, t, actor));
        }
        const res = await env.DB.batch(stmts);
        if (changesOf(res[0]) === 1) return readBack({});

        // Nothing was written. Say which rule refused it, from the rows now.
        const [p2, a2] = await Promise.all([readPromotion(), readAgent(env, p.agent)]);
        if (!p2 || p2.status !== "pending") {
          const prior = await readDecision();
          if (prior && prior.decision === b.decision) return readBack({ existing: true });
          return json(409, { error: "not_pending", status: p2 ? p2.status : null });
        }
        if (!a2) return json(404, { error: "agent not found" });
        if (a2.status !== "active") return json(409, { error: "agent_not_active", status: a2.status });
        if (a2.autonomy !== p.from_level) return json(409, { error: "stale_level", autonomy: a2.autonomy, from_level: p.from_level });
        if (rank(p.to_level) > rank(a2.cap)) return json(409, { error: "above_cap", to_level: p.to_level, cap: a2.cap });
        return json(409, { error: "decide_raced" });
      });
    },
  ],
];
