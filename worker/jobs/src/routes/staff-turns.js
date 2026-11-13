// staff turn routes — BH-9127: the writer of the `turn` events on an agent's
// timeline (GET /api/staff/agent/:name/activity in staff-activity.js reads them).
//
// POST /api/staff/turns is one row per Archie turn. bin/lib/archie-hb.sh
// posts it after the reply is delivered, so a failed post never touches the
// reply. Every field is validated; a bad value is a 400 naming the field, never
// a clamp. turn_key is the natural key: the same body again is a 200 replay,
// another body under the same key is 409.
//
// summary is one line of text. Control characters go, whitespace runs become
// one space, and 1..staff.turns.summary_in_max characters are accepted (the
// request bound; bin/lib/archie-hb.sh cuts to the same row). GitHub-token shapes
// (the bin/lib/token-redact.sh patterns) are replaced by
// <redacted:github-token> here too, so a caller that missed the scrub still
// stores no secret. The STORED text is then cut to the settings row
// staff.turns.summary_max_chars. link_url is null or one GitHub issue or pull
// request URL with no query. cost_run_id is null or staff-turn:<turn_key>.
import { json, d1Guarded } from "../lib/http.js";
import { KEY_RE, TS_RE, agentOf, knownAgent } from "./staff-activity.js";

const TRIGGERS = ["telegram", "slack", "dash", "beat", "sweep", "follow-up"];
const OUTCOMES = ["answered", "no_reply", "stopped", "acted"];
// The request bound on summary: settings row staff.turns.summary_in_max; 2000
// is its fallback when the row is absent or not a positive integer. It rejects
// a body, it is not the stored length (that is the next knob).
const SUMMARY_IN_DEFAULT = 2000;
// Stored summary length: settings row staff.turns.summary_max_chars; 200 is
// its fallback when the row is absent or outside 1..the request bound.
const SUMMARY_KEEP_DEFAULT = 200;
const SUMMARY_KEYS = ["staff.turns.summary_in_max", "staff.turns.summary_max_chars"];
const LINK_RE = /^https:\/\/github\.com\/[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}\/(issues|pull)\/[1-9]\d{0,9}$/;
const TURN_COLS = "id, turn_key, agent, started_at, ended_at, trigger, summary, link_url, outcome, cost_run_id, created_at";
const SAME_FIELDS = ["agent", "started_at", "ended_at", "trigger", "summary", "link_url", "outcome", "cost_run_id"];

const bad = (field) => json(400, { error: field });

// The bin/lib/token-redact.sh patterns, in the same order.
export function redactTokens(s) {
  return s
    .replace(/gh[pousr]_[0-9]+_[A-Za-z0-9._-]{20,}/g, "<redacted:github-token>")
    .replace(/gh[pousr]_[A-Za-z0-9]{30,}/g, "<redacted:github-token>")
    .replace(/github_pat_[A-Za-z0-9_]{22,}/g, "<redacted:github-token>")
    .replace(/x-access-token:[^@\s]+@/g, "x-access-token:<redacted:github-token>@")
    .replace(/sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{20,}/g, "<redacted:anthropic-key>");
}

// The turn body, validated. Returns { error } naming the first bad field, or { row }.
function turnRow(b, inMax) {
  if (!b || typeof b !== "object") return { error: "body" };
  const agent = agentOf(b.agent);
  if (!agent) return { error: "agent" };
  const key = typeof b.turn_key === "string" ? b.turn_key : "";
  if (!KEY_RE.test(key)) return { error: "turn_key" };
  if (typeof b.started_at !== "string" || !TS_RE.test(b.started_at)) return { error: "started_at" };
  if (typeof b.ended_at !== "string" || !TS_RE.test(b.ended_at)) return { error: "ended_at" };
  const s = Date.parse(b.started_at); const e = Date.parse(b.ended_at);
  if (Number.isNaN(s)) return { error: "started_at" };
  if (Number.isNaN(e) || e < s) return { error: "ended_at" };
  if (!TRIGGERS.includes(b.trigger)) return { error: "trigger" };
  if (!OUTCOMES.includes(b.outcome)) return { error: "outcome" };
  if (typeof b.summary !== "string") return { error: "summary" };
  // eslint-disable-next-line no-control-regex
  const line = b.summary.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "").replace(/\s+/g, " ").trim();
  if (line.length < 1 || line.length > inMax) return { error: "summary" };
  let link = null;
  if (b.link_url !== null && b.link_url !== undefined) {
    if (typeof b.link_url !== "string" || !LINK_RE.test(b.link_url)) return { error: "link_url" };
    link = b.link_url;
  }
  let run = null;
  if (b.cost_run_id !== null && b.cost_run_id !== undefined) {
    if (b.cost_run_id !== `staff-turn:${key}`) return { error: "cost_run_id" };
    run = b.cost_run_id;
  }
  return { row: { turn_key: key, agent, started_at: b.started_at, ended_at: b.ended_at, trigger: b.trigger,
    outcome: b.outcome, summary: redactTokens(line), link_url: link, cost_run_id: run } };
}

// The two summary bounds, from their settings rows in one read: { inMax, keep }.
// A missing table or row, or a bad value, is that row's documented fallback.
async function summaryBounds(env) {
  const v = {};
  try {
    const { results } = await env.DB.prepare(
      `SELECT key, value FROM settings WHERE key IN (SELECT value FROM json_each(?1))`
    ).bind(JSON.stringify(SUMMARY_KEYS)).all();
    for (const r of results || []) {
      const t = String(r.value).trim();
      if (/^\d{1,9}$/.test(t)) v[r.key] = Number(t);
    }
  } catch {
    // the fallbacks below
  }
  const inMax = v["staff.turns.summary_in_max"] >= 1 ? v["staff.turns.summary_in_max"] : SUMMARY_IN_DEFAULT;
  const k = v["staff.turns.summary_max_chars"];
  return { inMax, keep: k >= 1 && k <= inMax ? k : Math.min(SUMMARY_KEEP_DEFAULT, inMax) };
}

export const routes = [
  // ── POST /api/staff/turns — one agent turn ────────────────────────────────
  [
    "POST", "/api/staff/turns",
    async ({ env, body, t }) => {
      const { inMax, keep } = await summaryBounds(env);
      const { error, row } = turnRow(body, inMax);
      if (error) return bad(error);
      const unknown = await knownAgent(env, row.agent);
      if (unknown) return unknown;
      row.summary = row.summary.slice(0, keep);
      return d1Guarded("staff_turns", async () => {
        const cols = ["turn_key", "agent", "started_at", "ended_at", "trigger", "summary", "link_url", "outcome", "cost_run_id", "created_at"];
        const vals = cols.map((c) => (c === "created_at" ? t : row[c]));
        // sql-ident-ok: cols is a literal column list mapped to ?N placeholders
        const res = await env.DB.prepare(
          `INSERT INTO staff_turns (${cols.join(", ")}) VALUES (${cols.map((_, i) => `?${i + 1}`).join(", ")})
           ON CONFLICT(turn_key) DO NOTHING`
        ).bind(...vals).run();
        // sql-ident-ok: TURN_COLS is a module const column list; the turn_key is a ?N bind
        const stored = await env.DB.prepare(`SELECT ${TURN_COLS} FROM staff_turns WHERE turn_key=?1`).bind(row.turn_key).first();
        if (!stored) return json(503, { error: "staff_turns unavailable", detail: "the row is not readable after the write" });
        const out = { id: Number(stored.id), turn_key: stored.turn_key, agent: stored.agent };
        if (res && res.meta && res.meta.changes > 0) return json(201, { turn: out, replay: false });
        const same = SAME_FIELDS.every((f) => (stored[f] ?? null) === (row[f] ?? null));
        if (!same) return json(409, { error: "turn_key_conflict", turn: out });
        return json(200, { turn: out, replay: true });
      });
    },
  ],
];
