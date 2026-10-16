// staff activity routes — the agent detail page's timeline (BH-6822).
//
// POST /api/staff/ticks is the tick writer. bin/staff.sh posts one row per
// heartbeat tick that got past its lock, from its EXIT trap. Every field is
// validated; a value out of range is a 400 naming the field, never a clamp.
// duration_s is computed here from the two times. tick_key is the natural key:
// the same body again is a 200 replay, another body under the same key is 409.
//
// GET /api/staff/agent/:name/activity?before=&limit= is one agent's timeline,
// newest first, merged from five sources by (ts DESC, kind DESC, id DESC):
//   tick              staff_ticks.started_at (none for Archie)
//   finding.claimed   staff_findings.claimed_at
//   finding.recorded  staff_findings.updated_at, for a status past the claim
//                     that is not an outcome (the table keeps only the current
//                     status, so earlier statuses are not shown)
//   outcome           staff_outcomes.resolved_at
//   decision          staff_decisions.created_at (Archie: archie_decisions)
// Each source is one indexed statement with LIMIT limit+1 past the cursor, so
// the merged page is exact. `before` is the opaque cursor <ts>~<kind>~<id> of
// the last event of the previous page; `next` is null on the last page. A page
// then makes two batched lookups, never one per row: the cost rows of its ticks
// (cost_rows.run_id = the tick's cost_run_id) and the findings its outcomes and
// staff:<fp> decisions point at. A failed cost read keeps the events and says
// cost_status "unread". An unpriced cost row is counted, never read as $0.
//
// GET /api/staff/tick?id= is one tick with its cost rows (their session ids
// are the transcript pointers).
import { json, d1Guarded } from "../lib/http.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const KEY_RE = /^[a-z0-9][a-z0-9:._-]{0,119}$/;
const TS_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
// Stored times are ISO-Z; a cursor echoes a stored time, so it may carry millis.
const CURSOR_TS_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,6})?Z$/;
const ID_RE = /^[1-9]\d{0,15}$/;
const ARCHIE = "archie";
const PHASES = ["roster", "soul", "collect", "claim", "model", "act", "done"];
const COUNTS = ["collected", "new_items", "deferred", "model_calls", "digested", "filed", "refused", "unsupported", "failed", "held"];
const RCS = ["collector_rc", "model_rc"];
const COUNT_MAX = 100000;
const RC_MAX = 255;
const LIMIT_DEFAULT = 50;
const LIMIT_MAX = 200;
const COST_ROWS_MAX = 20;
const TICK_COLS = `id, tick_key, agent, started_at, ended_at, duration_s, phase, collector_rc, collector_s, model_rc,
  ${COUNTS.join(", ")}, cost_run_id, created_at`;
// The statuses that are not a finding.recorded event: the claim itself, and
// the outcomes (staff_outcomes carries those as their own events).
const NOT_RECORDED = "'claimed','merged','rejected','noise'";

// THE agent identity: the same rule as staff.js and staff-screen.js.
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
const bad = (field) => json(400, { error: field });
const intIn = (v, max) => Number.isInteger(v) && v >= 0 && v <= max;

// The tick body, validated. Returns { error } naming the first bad field, or { row }.
function tickRow(b) {
  if (!b || typeof b !== "object") return { error: "body" };
  const agent = agentOf(b.agent);
  if (!agent) return { error: "agent" };
  const key = typeof b.tick_key === "string" ? b.tick_key : "";
  if (!KEY_RE.test(key)) return { error: "tick_key" };
  if (typeof b.started_at !== "string" || !TS_RE.test(b.started_at)) return { error: "started_at" };
  if (typeof b.ended_at !== "string" || !TS_RE.test(b.ended_at)) return { error: "ended_at" };
  const s = Date.parse(b.started_at); const e = Date.parse(b.ended_at);
  if (Number.isNaN(s)) return { error: "started_at" };
  if (Number.isNaN(e) || e < s) return { error: "ended_at" };
  if (!PHASES.includes(b.phase)) return { error: "phase" };
  const row = { tick_key: key, agent, started_at: b.started_at, ended_at: b.ended_at, duration_s: (e - s) / 1000, phase: b.phase };
  for (const f of RCS) {
    if (b[f] === null || b[f] === undefined) row[f] = null;
    else if (intIn(b[f], RC_MAX)) row[f] = b[f];
    else return { error: f };
  }
  if (b.collector_s === null || b.collector_s === undefined) row.collector_s = null;
  else if (intIn(b.collector_s, COUNT_MAX)) row.collector_s = b.collector_s;
  else return { error: "collector_s" };
  for (const f of COUNTS) {
    if (!intIn(b[f], COUNT_MAX)) return { error: f };
    row[f] = b[f];
  }
  if (b.cost_run_id === null || b.cost_run_id === undefined) row.cost_run_id = null;
  else if (b.cost_run_id === `staff-tick:${key}`) row.cost_run_id = b.cost_run_id;
  else return { error: "cost_run_id" };
  return { row };
}
const SAME_FIELDS = ["agent", "started_at", "ended_at", "phase", "collector_rc", "collector_s", "model_rc", ...COUNTS, "cost_run_id"];

// ── the timeline ─────────────────────────────────────────────────────────────
// Kind names sort in this order; the cursor compares kinds by it.
const KINDS = ["decision", "finding.claimed", "finding.recorded", "outcome", "tick"];
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
// The total order, newest first: ts DESC, kind DESC, id DESC.
const order = (x, y) => cmp(y.ts, x.ts) || cmp(y.kind, x.kind) || (y.id - x.id);

function parseCursor(raw) {
  const parts = raw.split("~");
  if (parts.length !== 3) return null;
  const [ts, kind, id] = parts;
  if (!CURSOR_TS_RE.test(ts) || !KINDS.includes(kind) || !ID_RE.test(id)) return null;
  return { ts, kind, id: Number(id) };
}
// The WHERE part a source of kind K adds for cursor c, with its binds.
// K < Kc: ts <= Tc. K = Kc: (ts, id) < (Tc, Ic). K > Kc: ts < Tc.
function cursorCond(kind, tsCol, c, n) {
  if (!c) return { sql: "", binds: [] };
  if (kind < c.kind) return { sql: ` AND ${tsCol} <= ?${n}`, binds: [c.ts] };
  if (kind === c.kind) return { sql: ` AND (${tsCol}, id) < (?${n}, ?${n + 1})`, binds: [c.ts, c.id] };
  return { sql: ` AND ${tsCol} < ?${n}`, binds: [c.ts] };
}

// The source statements for one agent. Each returns rows with `ts` and `id`.
function sources(name) {
  const archie = name === ARCHIE;
  const list = [];
  if (!archie) {
    list.push({ kind: "tick", table: "staff_ticks", ts: "started_at",
      sql: (w) => `SELECT ${TICK_COLS}, started_at AS ts FROM staff_ticks
                    WHERE agent=?1${w} ORDER BY started_at DESC, id DESC LIMIT ?2` });
  }
  list.push({ kind: "finding.claimed", table: "staff_findings", ts: "claimed_at",
    sql: (w) => `SELECT id, title, status, ticket_url, claimed_at AS ts FROM staff_findings
                  WHERE agent=?1${w} ORDER BY claimed_at DESC, id DESC LIMIT ?2` });
  list.push({ kind: "finding.recorded", table: "staff_findings", ts: "updated_at",
    sql: (w) => `SELECT id, title, status, ticket_url, updated_at AS ts FROM staff_findings
                  WHERE agent=?1 AND status NOT IN (${NOT_RECORDED})${w} ORDER BY updated_at DESC, id DESC LIMIT ?2` });
  list.push({ kind: "outcome", table: "staff_outcomes", ts: "resolved_at",
    sql: (w) => `SELECT id, fingerprint, outcome, verdict, ticket_url, resolved_at AS ts FROM staff_outcomes
                  WHERE agent=?1${w} ORDER BY resolved_at DESC, id DESC LIMIT ?2` });
  if (archie) {
    // archie_decisions has no agent column: ?1 is bound and unused, so every
    // source takes the same (?1 agent, ?2 limit, ?3.. cursor) binds.
    list.push({ kind: "decision", table: "archie_decisions", ts: "created_at",
      sql: (w) => `SELECT id, escalation_key, class, mode, recommendation, choice, chosen_at, created_at AS ts
                    FROM archie_decisions WHERE ?1 IS NOT NULL${w} ORDER BY created_at DESC, id DESC LIMIT ?2` });
  } else {
    list.push({ kind: "decision", table: "staff_decisions", ts: "created_at",
      sql: (w) => `SELECT id, escalation_key, class, mode, recommendation, choice, chosen_at, created_at AS ts
                    FROM staff_decisions WHERE agent=?1${w} ORDER BY created_at DESC, id DESC LIMIT ?2` });
  }
  return list;
}

const cursorOf = (e) => `${e.ts}~${e.kind}~${e.id}`;
function eventOf(kind, r) {
  const base = { kind, ts: r.ts, id: Number(r.id) };
  if (kind === "tick") {
    const ev = { ...base, phase: r.phase, duration_s: r.duration_s, collector_rc: r.collector_rc, collector_s: r.collector_s,
      model_rc: r.model_rc, cost_run_id: r.cost_run_id, cost: null };
    for (const f of COUNTS) ev[f] = r[f];
    return ev;
  }
  if (kind === "finding.claimed" || kind === "finding.recorded") {
    return { ...base, finding_id: Number(r.id), title: r.title, status: r.status, ticket_url: r.ticket_url };
  }
  if (kind === "outcome") {
    return { ...base, outcome: r.outcome, verdict: r.verdict, ticket_url: r.ticket_url, finding_id: null, fingerprint: r.fingerprint };
  }
  const fp = typeof r.escalation_key === "string" && r.escalation_key.startsWith("staff:") ? r.escalation_key.slice(6) : null;
  return { ...base, class: r.class, mode: r.mode, recommendation: r.recommendation, choice: r.choice,
    chosen_at: r.chosen_at, finding_id: null, fingerprint: fp };
}

async function knownAgent(env, name) {
  if (name === ARCHIE) return null;
  return d1Guarded("staff_agents", async () => {
    const row = await env.DB.prepare(`SELECT name FROM staff_agents WHERE name=?1`).bind(name).first();
    return row ? null : json(404, { error: "agent not found" });
  });
}

export const routes = [
  // ── POST /api/staff/ticks — one heartbeat tick ────────────────────────────
  [
    "POST", "/api/staff/ticks",
    async ({ env, body, t }) => {
      const { error, row } = tickRow(body);
      if (error) return bad(error);
      const unknown = await knownAgent(env, row.agent);
      if (unknown) return unknown;
      return d1Guarded("staff_ticks", async () => {
        const cols = ["tick_key", "agent", "started_at", "ended_at", "duration_s", "phase", "collector_rc", "collector_s",
          "model_rc", ...COUNTS, "cost_run_id", "created_at"];
        const vals = cols.map((c) => (c === "created_at" ? t : row[c]));
        // sql-ident-ok: cols is a literal column list plus the module const COUNTS, mapped to ?N placeholders
        const res = await env.DB.prepare(
          `INSERT INTO staff_ticks (${cols.join(", ")}) VALUES (${cols.map((_, i) => `?${i + 1}`).join(", ")})
           ON CONFLICT(tick_key) DO NOTHING`
        ).bind(...vals).run();
        // sql-ident-ok: TICK_COLS is a module const column list; the tick_key is a ?N bind
        const stored = await env.DB.prepare(`SELECT ${TICK_COLS} FROM staff_ticks WHERE tick_key=?1`).bind(row.tick_key).first();
        if (!stored) return json(503, { error: "staff_ticks unavailable", detail: "the row is not readable after the write" });
        const out = { id: Number(stored.id), tick_key: stored.tick_key, agent: stored.agent, duration_s: stored.duration_s };
        if (res && res.meta && res.meta.changes > 0) return json(201, { tick: out, replay: false });
        const same = SAME_FIELDS.every((f) => (stored[f] ?? null) === (row[f] ?? null));
        if (!same) return json(409, { error: "tick_key_conflict", tick: out });
        return json(200, { tick: out, replay: true });
      });
    },
  ],

  // ── GET /api/staff/agent/:name/activity — the merged timeline ─────────────
  [
    "GET", /^\/api\/staff\/agent\/([^/]+)\/activity$/,
    async ({ env, url, m, t }) => {
      let rawName;
      try { rawName = decodeURIComponent(m[1]); } catch { return bad("agent"); }
      const name = agentOf(rawName);
      if (name === null) return bad("agent");
      const rawLimit = url.searchParams.get("limit");
      let limit = LIMIT_DEFAULT;
      if (rawLimit !== null) {
        if (!/^\d{1,4}$/.test(rawLimit)) return bad("limit");
        limit = Number(rawLimit);
        if (limit < 1 || limit > LIMIT_MAX) return bad("limit");
      }
      const rawBefore = url.searchParams.get("before");
      let cursor = null;
      if (rawBefore !== null) {
        cursor = parseCursor(rawBefore);
        if (!cursor) return bad("before");
      }
      const unknown = await knownAgent(env, name);
      if (unknown) return unknown;

      const events = [];
      for (const src of sources(name)) {
        const fail = await d1Guarded(src.table, async () => {
          const w = cursorCond(src.kind, src.ts, cursor, 3);
          const { results } = await env.DB.prepare(src.sql(w.sql)).bind(name, limit + 1, ...w.binds).all();
          for (const r of results || []) events.push(eventOf(src.kind, r));
          return null;
        });
        if (fail) return fail;
      }
      events.sort(order);
      const page = events.slice(0, limit);
      const next = events.length > limit ? cursorOf(page[page.length - 1]) : null;

      // Cost per tick: one grouped read over the page's run ids.
      let costStatus = "ok";
      const runIds = [...new Set(page.filter((e) => e.kind === "tick" && e.cost_run_id).map((e) => e.cost_run_id))];
      if (runIds.length) {
        try {
          const { results } = await env.DB.prepare(
            `SELECT run_id, SUM(cost_usd) AS cost_usd, COUNT(*) AS rows, SUM(cost_usd IS NULL) AS unpriced
               FROM cost_rows WHERE run_id IN (SELECT value FROM json_each(?1)) GROUP BY run_id`
          ).bind(JSON.stringify(runIds)).all();
          const byRun = new Map((results || []).map((r) => [r.run_id, r]));
          for (const e of page) {
            const c = e.kind === "tick" && e.cost_run_id ? byRun.get(e.cost_run_id) : null;
            if (c) e.cost = { cost_usd: c.cost_usd === null ? null : Number(c.cost_usd), rows: Number(c.rows), unpriced: Number(c.unpriced) };
          }
        } catch {
          costStatus = "unread";
        }
      }
      // Finding links for outcomes and staff:<fp> decisions: one read.
      const fps = [...new Set(page.filter((e) => e.fingerprint).map((e) => e.fingerprint))];
      if (fps.length) {
        const fail = await d1Guarded("staff_findings", async () => {
          const { results } = await env.DB.prepare(
            `SELECT id, fingerprint FROM staff_findings WHERE fingerprint IN (SELECT value FROM json_each(?1))`
          ).bind(JSON.stringify(fps)).all();
          const byFp = new Map((results || []).map((r) => [r.fingerprint, Number(r.id)]));
          for (const e of page) if (e.fingerprint) e.finding_id = byFp.get(e.fingerprint) ?? null;
          return null;
        });
        if (fail) return fail;
      }
      for (const e of page) { delete e.fingerprint; e.cursor = cursorOf(e); }

      let lastTick = null;
      if (name !== ARCHIE) {
        const fail = await d1Guarded("staff_ticks", async () => {
          lastTick = await env.DB.prepare(
            `SELECT id, started_at, ended_at, phase FROM staff_ticks WHERE agent=?1 ORDER BY started_at DESC, id DESC LIMIT 1`
          ).bind(name).first() || null;
          return null;
        });
        if (fail) return fail;
      }
      return json(200, { agent: name, events: page, next, last_tick: lastTick, cost_status: costStatus, as_of: t });
    },
  ],

  // ── GET /api/staff/tick?id= — one tick and its cost rows ──────────────────
  [
    "GET", "/api/staff/tick",
    async ({ env, url }) => {
      const raw = (url.searchParams.get("id") || "").trim();
      if (!ID_RE.test(raw)) return bad("id");
      return d1Guarded("staff_ticks", async () => {
        // sql-ident-ok: TICK_COLS is a module const column list; the id is a ?N bind
        const tick = await env.DB.prepare(`SELECT ${TICK_COLS} FROM staff_ticks WHERE id=?1`).bind(Number(raw)).first();
        if (!tick) return json(404, { error: "tick not found" });
        let rows = [];
        let costStatus = "ok";
        let truncated = false;
        if (tick.cost_run_id) {
          try {
            rows = (await env.DB.prepare(
              `SELECT ts, stage, model, rc, duration_s, cost_usd, session_id FROM cost_rows
                WHERE run_id=?1 ORDER BY ts LIMIT ?2`
            ).bind(tick.cost_run_id, COST_ROWS_MAX + 1).all()).results || [];
            truncated = rows.length > COST_ROWS_MAX;
            rows = rows.slice(0, COST_ROWS_MAX);
          } catch {
            costStatus = "unread";
          }
        }
        return json(200, { tick, cost_rows: rows, cost_rows_truncated: truncated, cost_status: costStatus });
      });
    },
  ],
];
