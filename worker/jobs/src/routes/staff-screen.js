// staff screen routes — BH-5567 (BH-5556.10): the reads behind the console's
// /staff screen. Read only: nothing here writes staff_findings or staff_agents.
// The kill switch is not here either; the screen writes it through the
// existing PUT/DELETE /api/flags (flags.js) as staff-kill-<agent> and
// staff-kill-all.
//
// GET /api/staff/roster is Archie plus every staff_agents row, each with its
// open-findings count. Archie is not a staff_agents row: its role and
// accountable person are the settings rows staff.archie.role and
// staff.archie.accountable, and an absent row is null, never a fallback.
// precision and spend_usd are null on every row, because no source for either
// exists yet; `sources` names the ticket that builds each one.
//
// GET /api/staff/findings?agent= is one agent's open findings, newest first,
// capped at FINDINGS_MAX with `truncated` set when the cap cut the list.
// GET /api/staff/finding?id= is one finding with every column.
//
// "Open" is any status outside CLOSED. A missing table answers 503 naming it
// (d1Guarded), on every route.

import { json, d1Guarded } from "../lib/http.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const ID_RE = /^[1-9]\d{0,15}$/;
const ARCHIE = "archie";
const FINDINGS_MAX = 500;
// The status words that end a finding (wave 6's outcomes). Everything else is open.
const CLOSED = ["merged", "rejected", "noise", "closed"];
const CLOSED_SQL = CLOSED.map((s) => `'${s}'`).join(",");
const SOURCES = { precision: "not built: BH-5563 (#5563)", spend: "not built: BH-5561 (#5561)" };
const COLUMNS = "id, fingerprint, agent, title, source_kind, source_url, status, ticket_url, observed_at, claimed_at, updated_at";

// THE agent identity: the same rule as staff.js (trim, lowercase).
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
const bad = (field) => json(400, { error: field });

const settingOf = async (env, key) => {
  const row = await env.DB.prepare(`SELECT value FROM settings WHERE key=?1`).bind(key).first();
  return row && typeof row.value === "string" && row.value.trim() !== "" ? row.value.trim() : null;
};
const labelsOf = (raw) => {
  try {
    const v = JSON.parse(raw);
    if (Array.isArray(v)) return { source_labels: v };
  } catch { /* falls through: the raw text is shown, marked invalid */ }
  return { source_labels: raw, labels_invalid: true };
};

// The newest staff_ticks.started_at per agent (BH-6822): one index seek per
// agent, run together, never a GROUP BY over the table. null when the read
// fails (the table predates nothing here): the roster still answers, with
// sources.last_tick "unread".
async function lastTicks(env, names) {
  if (!names.length) return new Map();
  try {
    const stmt = `SELECT started_at FROM staff_ticks WHERE agent=?1 ORDER BY started_at DESC, id DESC LIMIT 1`;
    const rows = await Promise.all(names.map((n) => env.DB.prepare(stmt).bind(n).first()));
    return new Map(names.map((n, i) => [n, (rows[i] && rows[i].started_at) || null]));
  } catch {
    return null;
  }
}

export const routes = [
  // ── GET /api/staff/roster — Archie plus the staff, with open findings ──────
  [
    "GET", "/api/staff/roster",
    async ({ env, t }) => {
      let agents = null;
      let archie = null;
      const phase1 = await d1Guarded("staff_agents", async () => {
        const { results } = await env.DB.prepare(
          `SELECT name, role, accountable, autonomy, cap, status FROM staff_agents ORDER BY name`
        ).all();
        agents = results || [];
        archie = {
          role: await settingOf(env, "staff.archie.role"),
          accountable: await settingOf(env, "staff.archie.accountable"),
        };
        return null;
      });
      if (phase1) return phase1;

      const open = new Map();
      const phase2 = await d1Guarded("staff_findings", async () => {
        // sql-ident-ok: CLOSED_SQL is a module const list of quoted literal status words
        const { results } = await env.DB.prepare(
          `SELECT agent, COUNT(*) AS n FROM staff_findings WHERE status NOT IN (${CLOSED_SQL}) GROUP BY agent`
        ).all();
        for (const r of results || []) open.set(r.agent, Number(r.n));
        return null;
      });
      if (phase2) return phase2;

      const rows = [
        {
          name: ARCHIE, kind: "overlooker", role: archie.role, accountable: archie.accountable,
          autonomy: "per-class", cap: null, status: null,
        },
        ...agents.filter((a) => a.name !== ARCHIE).map((a) => ({
          name: a.name, kind: "staff", role: a.role, accountable: a.accountable,
          autonomy: a.autonomy, cap: a.cap, status: a.status,
        })),
      ].map((a) => ({ ...a, open_findings: open.get(a.name) || 0, precision: null, spend_usd: null }));
      const lastTick = await lastTicks(env, agents.filter((a) => a.name !== ARCHIE).map((a) => a.name));
      for (const r of rows) r.last_tick_at = (lastTick && lastTick.get(r.name)) || null;
      return json(200, { agents: rows, sources: lastTick ? SOURCES : { ...SOURCES, last_tick: "unread" }, as_of: t });
    },
  ],

  // ── GET /api/staff/findings?agent= — one agent's open findings ─────────────
  [
    "GET", "/api/staff/findings",
    async ({ env, url, t }) => {
      const name = agentOf(url.searchParams.get("agent"));
      if (name === null) return bad("agent");
      if (name !== ARCHIE) {
        const known = await d1Guarded("staff_agents", async () => {
          const row = await env.DB.prepare(`SELECT name FROM staff_agents WHERE name=?1`).bind(name).first();
          return row ? null : json(404, { error: "agent not found" });
        });
        if (known) return known;
      }
      return d1Guarded("staff_findings", async () => {
        // sql-ident-ok: COLUMNS, CLOSED_SQL and FINDINGS_MAX are module consts
        const { results } = await env.DB.prepare(
          `SELECT ${COLUMNS} FROM staff_findings
            WHERE agent=?1 AND status NOT IN (${CLOSED_SQL})
            ORDER BY id DESC LIMIT ${FINDINGS_MAX + 1}`
        ).bind(name).all();
        const list = results || [];
        return json(200, {
          agent: name, findings: list.slice(0, FINDINGS_MAX), truncated: list.length > FINDINGS_MAX, as_of: t,
        });
      });
    },
  ],

  // ── GET /api/staff/finding?id= — one finding, every column ─────────────────
  [
    "GET", "/api/staff/finding",
    async ({ env, url }) => {
      const raw = (url.searchParams.get("id") || "").trim();
      if (!ID_RE.test(raw)) return bad("id");
      return d1Guarded("staff_findings", async () => {
        const row = await env.DB.prepare(`SELECT * FROM staff_findings WHERE id=?1`).bind(Number(raw)).first();
        if (!row) return json(404, { error: "finding not found" });
        return json(200, { finding: { ...row, ...labelsOf(row.source_labels) } });
      });
    },
  ],
];
