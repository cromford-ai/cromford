// unblock-metrics routes — BH-7728 (UNB-6): the read side and the override
// side of the Tackler ledger.
//
//   GET  /api/unblock/metrics              the four metrics and the per-day trend
//   GET  /api/unblock/metrics/decisions    the console's ledger list, newest first
//   GET  /api/unblock/overrides/candidates done acts with no override yet
//   POST /api/unblock/overrides            bin/lib/unblock/override.sh stamps one
//
// The table is UNB-0's (unblock_decisions, #7722). This family adds none and
// ships no schema fragment: before UNB-0's fragment is applied every route
// answers 503 "unblock_decisions schema not applied" (d1Guarded), and the
// console shows "not live yet" on exactly that answer.
//
// THE DEFINITIONS (spec "Metrics with before and after targets"):
//   decision     decision='act' AND outcome='done'
//   would        outcome='would' (shadow mode: what Tackler would have done)
//   escalation   a card sent: outcome IN ('escalated','answered','expired')
//   override     a decision with override_by set
//   override_rate overrides / decisions, null at 0 decisions
//   stall minutes (acted_at, else created_at) - evidence.stall_at, for every
//                row that is a decision, a would or an escalation; a row of
//                those with no parseable stall_at counts in stall_unknown
//   median, p95  nearest rank over the sorted minutes
//   uncovered    rows with no rule_id (U12)
//   expired_cards outcome='expired'
// The window is `days` whole UTC days that end at `to` (a YYYY-MM-DD, default
// today, exclusive): [to - days, to).
//
// THE READS (BH-6730). Each route runs one statement on an index the UNB-0
// DDL declares; R7 in test/unblock-metrics.bh-7728.test.js EXPLAINs these
// exact texts at 50 000 rows:
//   metrics     idx_unblock_decisions_created (range). `+project` keeps the
//               planner on the 7-day range rather than on all of a project's
//               history through idx_unblock_decisions_project_id.
//   list        idx_unblock_decisions_project_id
//   candidates  idx_unblock_decisions_created; `+outcome` keeps the planner off
//               idx_unblock_decisions_outcome_project (every done row ever).
//
// D1 has no RLS. Every route sits behind the HARNESS_SECRET bearer (this
// family is not in OPEN_FAMILIES).

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

const TABLE = "unblock_decisions";
// Fallback, used only when settings row unblock.metrics_days is absent or junk.
const METRICS_DAYS_DEFAULT = 7;
const DAYS_MIN = 1;
const DAYS_MAX = 30;
const MAX_WINDOW_ROWS = 20000;
const LIST_LIMIT_DEFAULT = 50;
const LIST_LIMIT_MAX = 100;
const CANDIDATES_MAX = 200;
const EVIDENCE_CUT = 2048;
const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
const INT_RE = /^[1-9]\d{0,15}$/;
const CARD_OUTCOMES = new Set(["escalated", "answered", "expired"]);

export const METRICS_WINDOW_SQL =
  `SELECT id, created_at, acted_at, rule_id, decision, outcome, mode, override_by,
          json_extract(evidence, '$.stall_at') AS stall_at
     FROM unblock_decisions
    WHERE created_at >= ?1 AND created_at < ?2 AND +project = ?3
    ORDER BY created_at LIMIT ?4`;
const LIST_COLUMNS =
  `id, created_at, acted_at, project, repo, subject_kind, subject, head, rule_id, rule_cites, decision, action,
   mode, outcome, outcome_detail, override_by, override_at, override_detail, evidence`;
export const DECISIONS_PAGE_SQL =
  `SELECT ${LIST_COLUMNS} FROM unblock_decisions
    WHERE project = ?1 AND (?2 IS NULL OR id < ?2)
    ORDER BY id DESC LIMIT ?3`;
export const CANDIDATES_SQL =
  `SELECT id, project, repo, subject_kind, subject, head, rule_id, action, action_args, created_at, acted_at
     FROM unblock_decisions
    WHERE created_at >= ?1 AND decision = 'act' AND +outcome = 'done' AND override_by IS NULL
    ORDER BY created_at LIMIT ?2`;

const bad = (field) => json(400, { error: field });
const settingInt = async (env, key, def, lo, hi) => {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first("value");
  const n = Number(v);
  return v !== null && Number.isInteger(n) && n >= lo && n <= hi ? n : def;
};
const dayOk = (s) => {
  const t = DAY_RE.test(s) ? Date.parse(`${s}T00:00:00Z`) : NaN;
  return Number.isFinite(t) && new Date(t).toISOString().slice(0, 10) === s;
};
const isoOk = (s) => typeof s === "string" && ISO_RE.test(s) && Number.isFinite(Date.parse(s));
const isoOfMs = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, "Z");
const round = (v, dp) => Math.round(v * 10 ** dp) / 10 ** dp;
// Nearest rank: the value at rank ceil(p * n) of the ascending list.
const rankOf = (sorted, p) => (sorted.length ? sorted[Math.max(1, Math.ceil(p * sorted.length)) - 1] : null);
const isDecision = (r) => r.decision === "act" && r.outcome === "done";
const isCard = (r) => CARD_OUTCOMES.has(r.outcome);
// Minutes from the stall to the action or the card; null when unknown.
const stallMin = (r) => {
  const s = typeof r.stall_at === "string" ? Date.parse(r.stall_at) : NaN;
  const e = Date.parse(r.acted_at || r.created_at);
  if (!Number.isFinite(s) || !Number.isFinite(e) || e < s) return null;
  return Math.round((e - s) / 60000);
};

// The aggregate over the window rows. Pure; exported for the readers' fixture.
export function aggregate(rows, from, days) {
  const fromMs = Date.parse(from);
  const daily = [];
  for (let i = 0; i < days; i++) {
    daily.push({ day: isoOfMs(fromMs + i * 86400000).slice(0, 10), decisions: 0, would: 0, escalations: 0, overrides: 0, _m: [] });
  }
  const byDay = new Map(daily.map((d) => [d.day, d]));
  const rules = new Map();
  const all = [];
  let stallUnknown = 0, expired = 0, uncovered = 0;
  for (const r of rows) {
    const d = byDay.get(String(r.created_at).slice(0, 10));
    if (!d) continue;
    if (r.rule_id === null || r.rule_id === undefined) uncovered++;
    if (r.outcome === "expired") expired++;
    const dec = isDecision(r), would = r.outcome === "would", card = isCard(r);
    if (dec) {
      d.decisions++;
      if (r.override_by) d.overrides++;
      const k = r.rule_id ?? null;
      if (!rules.has(k)) rules.set(k, { rule_id: k, acts: 0, overrides: 0, would: 0 });
      rules.get(k).acts++;
      if (r.override_by) rules.get(k).overrides++;
    }
    if (would) {
      d.would++;
      const k = r.rule_id ?? null;
      if (!rules.has(k)) rules.set(k, { rule_id: k, acts: 0, overrides: 0, would: 0 });
      rules.get(k).would++;
    }
    if (card) d.escalations++;
    if (dec || would || card) {
      const m = stallMin(r);
      if (m === null) stallUnknown++;
      else { d._m.push(m); all.push(m); }
    }
  }
  const asc = (a, b) => a - b;
  for (const d of daily) {
    d._m.sort(asc);
    d.stall_median_min = rankOf(d._m, 0.5);
    d.stall_p95_min = rankOf(d._m, 0.95);
    delete d._m;
  }
  all.sort(asc);
  const decisions = daily.reduce((s, d) => s + d.decisions, 0);
  const overrides = daily.reduce((s, d) => s + d.overrides, 0);
  const escalations = daily.reduce((s, d) => s + d.escalations, 0);
  return {
    daily,
    totals: {
      decisions_per_day: round(decisions / days, 2),
      escalations_per_day: round(escalations / days, 2),
      override_rate: decisions === 0 ? null : round(overrides / decisions, 4),
      stall_median_min: rankOf(all, 0.5),
      stall_p95_min: rankOf(all, 0.95),
      stall_unknown: stallUnknown,
    },
    rules: [...rules.values()].sort((a, b) => b.acts - a.acts || String(a.rule_id).localeCompare(String(b.rule_id))),
    expired_cards: expired,
    uncovered,
  };
}

export const routes = [
  // ── GET /api/unblock/metrics?project=&days=&to= ─────────────────────────
  // days 1..30 (default the settings row unblock.metrics_days, else 7); to a
  // YYYY-MM-DD (default today UTC), exclusive. `truncated` is true when the
  // window held more than MAX_WINDOW_ROWS rows (the oldest were read).
  [
    "GET", "/api/unblock/metrics",
    async ({ env, url, t }) => {
      const project = url.searchParams.get("project") || "";
      if (!PROJECT_RE.test(project)) return bad("project");
      const daysQ = url.searchParams.get("days");
      if (daysQ !== null && !(INT_RE.test(daysQ) && Number(daysQ) >= DAYS_MIN && Number(daysQ) <= DAYS_MAX)) return bad("days");
      const toQ = url.searchParams.get("to");
      if (toQ !== null && !dayOk(toQ)) return bad("to");
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const days = daysQ !== null ? Number(daysQ)
          : await settingInt(env, "unblock.metrics_days", METRICS_DAYS_DEFAULT, DAYS_MIN, DAYS_MAX);
        const to = `${toQ ?? t.slice(0, 10)}T00:00:00Z`;
        const from = isoOfMs(Date.parse(to) - days * 86400000);
        const { results } = await env.DB.prepare(METRICS_WINDOW_SQL).bind(from, to, project, MAX_WINDOW_ROWS + 1).all();
        const rows = results || [];
        return json(200, {
          project, days, from, to,
          ...aggregate(rows.slice(0, MAX_WINDOW_ROWS), from, days),
          truncated: rows.length > MAX_WINDOW_ROWS,
        });
      });
    },
  ],

  // ── GET /api/unblock/metrics/decisions?project=&before_id=&limit= ───────
  // Newest first. evidence (at most 8 KB from UNB-0's writer) is cut to 2 KB
  // here, with evidence_truncated. next_before_id is the last id of a full
  // page, else null.
  [
    "GET", "/api/unblock/metrics/decisions",
    async ({ env, url }) => {
      const project = url.searchParams.get("project") || "";
      if (!PROJECT_RE.test(project)) return bad("project");
      const beforeQ = url.searchParams.get("before_id");
      if (beforeQ !== null && !INT_RE.test(beforeQ)) return bad("before_id");
      const limitQ = url.searchParams.get("limit");
      if (limitQ !== null && !(INT_RE.test(limitQ) && Number(limitQ) <= LIST_LIMIT_MAX)) return bad("limit");
      const limit = limitQ === null ? LIST_LIMIT_DEFAULT : Number(limitQ);
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const { results } = await env.DB.prepare(DECISIONS_PAGE_SQL)
          .bind(project, beforeQ === null ? null : Number(beforeQ), limit).all();
        const decisions = (results || []).map((r) => {
          const ev = typeof r.evidence === "string" ? r.evidence : "";
          return { ...r, evidence: ev.slice(0, EVIDENCE_CUT), evidence_truncated: ev.length > EVIDENCE_CUT };
        });
        return json(200, {
          project, limit, decisions,
          next_before_id: decisions.length === limit ? decisions[decisions.length - 1].id : null,
        });
      });
    },
  ],

  // ── GET /api/unblock/overrides/candidates?since= ────────────────────────
  // Done acts with no override, created at or after `since` (override.sh asks
  // for now - 48 h: an act is created before it is acted, and the override
  // window is 24 h after acted_at). At most 200, oldest first, `truncated`.
  [
    "GET", "/api/unblock/overrides/candidates",
    async ({ env, url }) => {
      const since = url.searchParams.get("since");
      if (!isoOk(since)) return bad("since");
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const { results } = await env.DB.prepare(CANDIDATES_SQL).bind(since, CANDIDATES_MAX + 1).all();
        const rows = results || [];
        return json(200, { since, candidates: rows.slice(0, CANDIDATES_MAX), truncated: rows.length > CANDIDATES_MAX });
      });
    },
  ],

  // ── POST /api/unblock/overrides ─────────────────────────────────────────
  // {id, override_by, override_at, override_detail}. Sets the override once:
  // 200 {ok:true} on the write, 200 {ok:true, existing:true, override_by} when
  // the row already carries one (the first one stays), 404 for no such row,
  // 409 not_an_act for a row that is not an act.
  [
    "POST", "/api/unblock/overrides",
    async ({ env, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!Number.isInteger(b.id) || b.id < 1) return bad("id");
      const by = typeof b.override_by === "string" ? b.override_by.trim() : "";
      if (by.length < 1 || by.length > 80) return bad("override_by");
      if (!isoOk(b.override_at)) return bad("override_at");
      if (b.override_detail !== undefined && b.override_detail !== null
        && (typeof b.override_detail !== "string" || b.override_detail.length > 500)) return bad("override_detail");
      const detail = b.override_detail ?? null;
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const res = await env.DB.prepare(
          `UPDATE unblock_decisions SET override_by = ?2, override_at = ?3, override_detail = ?4
            WHERE id = ?1 AND override_by IS NULL AND decision = 'act'`
        ).bind(b.id, by, b.override_at, detail).run();
        if ((res && res.meta && res.meta.changes) > 0) return json(200, { ok: true, id: b.id });
        const row = await env.DB.prepare("SELECT id, decision, override_by FROM unblock_decisions WHERE id = ?1").bind(b.id).first();
        if (!row) return json(404, { error: "decision not found" });
        if (row.override_by) return json(200, { ok: true, existing: true, id: b.id, override_by: row.override_by });
        return json(409, { error: "not_an_act", decision: row.decision });
      });
    },
  ],
];
