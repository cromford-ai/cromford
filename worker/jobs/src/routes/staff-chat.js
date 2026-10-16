// staff chat routes — one chat thread per staff agent (BH-6823).
//
// An operator writes a note to a staff agent. bin/staff.sh takes the agent's
// open notes at the start of its next tick, puts them in the same model call
// as the findings, and settles them: a reply row per answered note, each
// naming the tick (tick_key) that wrote it.
//
//   POST /api/staff/chat           send {agent, text, actor}. The note is
//                                  'held' when the agent is stopped at send
//                                  time, else 'pending'. Both are taken.
//   GET  /api/staff/chat           one thread page, newest first:
//                                  ?agent=&before=<id>&limit=1..100 (50)
//   POST /api/staff/chat/take      box: claim open notes for one tick
//                                  {agent, tick_key, limit 1..20 (5)}
//   POST /api/staff/chat/settle    box: {agent, tick_key, replies:[{id,text}],
//                                  unanswered:[id], release:[id]}
//
// The table, its states and its indexes are described in
// schema.d/202610162003-bh-6823-staff-chat.sql. Archie is not a staff_agents
// row and is never ticked by bin/staff.sh, so it has no thread (404).
// Every value out of range is a 400 naming the field, never a clamp.
import { json, d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { STEER_TEXT_MAX } from "./steer.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
// bin/staff.sh's TICK_KEY, the same rule as staff-activity.js KEY_RE.
const KEY_RE = /^[a-z0-9][a-z0-9:._-]{0,119}$/;
const ID_RE = /^[1-9]\d{0,15}$/;
const ARCHIE = "archie";
const LIMIT_DEFAULT = 50;
const LIMIT_MAX = 100;
const TAKE_DEFAULT = 5;
const TAKE_MAX = 20;
// The ids one settle may name in total. Each id is one bind, and one id may
// sit in one list only. A take hands out at most TAKE_MAX notes.
const SETTLE_IDS_MAX = 20;
// The settings rows staff.chat.attempts_max (1..10) and staff.chat.take_lease_s
// (60..86400), seeded by the schema fragment. These constants are the
// documented fallback for a row that is absent or bad.
export const STAFF_CHAT_ATTEMPTS_MAX = 2;
export const STAFF_CHAT_TAKE_LEASE_S = 1200;
const SWEEP_MAX = 100;

// THE agent identity: the same rule as staff.js and staff-activity.js.
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
const bad = (field, why) => json(400, { error: field, detail: why });
const posId = (v) => Number.isInteger(v) && v > 0;

// A settings value as an integer in lo..hi, or the fallback (steer.js setting()).
function intSetting(v, lo, hi, fallback) {
  const n = typeof v === "string" && /^\d+$/.test(v.trim()) ? Number(v.trim()) : NaN;
  return Number.isInteger(n) && n >= lo && n <= hi ? n : fallback;
}

// The ISO second `s` seconds before `t`, in nowIso's shape.
const before = (t, s) => new Date(Date.parse(t) - s * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

const msgOut = (r) => ({
  id: Number(r.id), agent: r.agent, role: r.role, text: r.text, actor: r.actor, state: r.state,
  reply_to: r.reply_to === null || r.reply_to === undefined ? null : Number(r.reply_to),
  tick_key: r.tick_key ?? null,
  tick_id: r.tick_id === null || r.tick_id === undefined ? null : Number(r.tick_id),
  attempts: Number(r.attempts || 0), stopped_by: r.stopped_by ?? null,
  created_at: r.created_at, updated_at: r.updated_at,
});

// The reads a route needs before it acts go in ONE env.DB.batch (lead review
// of #7155): the staff_agents row, and, when asked, the stop-flag lookup, plus
// the caller's own statements. A batch is one D1 round trip.
const rosterStmt = (env, name) => env.DB.prepare("SELECT name, status FROM staff_agents WHERE name=?1").bind(name);
// The four flag names bin/staff.sh checks, matched exactly (PK lookups).
const flagStmt = (env, agent) => env.DB.prepare(
  `SELECT name FROM pause_flags WHERE active=1 AND name IN (?1, ?2, ?3, ?4) ORDER BY name LIMIT 1`
).bind("staff-kill-all", `staff-kill-${agent}`, "staff-off-all", `staff-off-${agent}`);
const firstOf = (r) => (r && Array.isArray(r.results) && r.results.length ? r.results[0] : null);
const notFound = () => json(404, { error: "agent not found" });

// Why the agent is stopped now, or null: a raised flag, then a status that is
// not active.
function stoppedFrom(flagRow, status) {
  if (flagRow && flagRow.name) return flagRow.name;
  return status && status !== "active" ? `status ${status}` : null;
}

// agentRead(env, name, {flags, extra}) — one batch: the roster row, the flag
// lookup when `flags`, then `extra`. Answers { res } (404 for archie or an
// unknown name) or { row, stopped, rest } with `rest` the results of `extra`.
// The caller runs it inside d1Guarded, so a failed read is a 503.
async function agentRead(env, name, { flags = false, extra = [] } = {}) {
  if (name === ARCHIE) return { res: notFound() };
  const out = await env.DB.batch([rosterStmt(env, name), ...(flags ? [flagStmt(env, name)] : []), ...extra]);
  const row = firstOf(out[0]);
  if (!row) return { res: notFound() };
  return { row, stopped: flags ? stoppedFrom(firstOf(out[1]), row.status) : null, rest: out.slice(flags ? 2 : 1) };
}

// The staff_agents row of a valid name, or a Response (404 for archie or an
// unknown name, 503 when the roster cannot be read). One read.
async function agentRow(env, name) {
  if (name === ARCHIE) return { res: notFound() };
  let row = null;
  const fail = await d1Guarded("staff_agents", async () => {
    row = await rosterStmt(env, name).first();
    return null;
  });
  if (fail) return { res: fail };
  if (!row) return { res: notFound() };
  return { row };
}

// A list of positive integer ids, or null when the value is not one.
function idList(v) {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v) || !v.every(posId)) return null;
  return v;
}

export const routes = [
  // ── GET /api/staff/chat — one thread page ─────────────────────────────────
  [
    "GET", "/api/staff/chat",
    async ({ env, t, url }) => {
      const agent = agentOf(url.searchParams.get("agent"));
      if (!agent) return bad("agent", "agent must match [a-z][a-z0-9-]{1,39}");
      const rawBefore = url.searchParams.get("before");
      let cursor = Number.MAX_SAFE_INTEGER;
      if (rawBefore !== null) {
        if (!ID_RE.test(rawBefore)) return bad("before", "before must be a positive message id");
        cursor = Number(rawBefore);
      }
      const rawLimit = url.searchParams.get("limit");
      let limit = LIMIT_DEFAULT;
      if (rawLimit !== null) {
        if (!/^\d{1,4}$/.test(rawLimit) || Number(rawLimit) < 1 || Number(rawLimit) > LIMIT_MAX) {
          return bad("limit", `limit must be 1..${LIMIT_MAX}`);
        }
        limit = Number(rawLimit);
      }
      if (agent === ARCHIE) return notFound();
      return d1Guarded("staff_chat", async () => {
        await ensureTable(env, "staff_chat");
        await ensureTable(env, "staff_ticks");
        // One round trip: the roster row, the stop flags and the page.
        const { res, stopped, rest } = await agentRead(env, agent, { flags: true, extra: [env.DB.prepare(
          `SELECT c.*, t.id AS tick_id FROM staff_chat c LEFT JOIN staff_ticks t ON t.tick_key = c.tick_key
            WHERE c.agent=?1 AND c.id < ?2 ORDER BY c.id DESC LIMIT ?3`
        ).bind(agent, cursor, limit + 1)] });
        if (res) return res;
        const rows = (rest[0] && rest[0].results) || [];
        const more = rows.length > limit;
        const page = rows.slice(0, limit).map(msgOut);
        return json(200, {
          agent, messages: page, next: more ? page[page.length - 1].id : null,
          stopped: stopped !== null, stopped_by: stopped, as_of: t,
        });
      });
    },
  ],

  // ── POST /api/staff/chat — send one note ──────────────────────────────────
  [
    "POST", "/api/staff/chat",
    async ({ env, t, body }) => {
      const agent = agentOf(body && body.agent);
      if (!agent) return bad("agent", "agent must match [a-z][a-z0-9-]{1,39}");
      const text = typeof body.text === "string" ? body.text.trim() : "";
      if (!text) return bad("text", "text required");
      if (text.length > STEER_TEXT_MAX) return bad("text", `text is over ${STEER_TEXT_MAX} characters`);
      const actor = typeof body.actor === "string" ? body.actor.trim().slice(0, 128) : "";
      if (!actor) return bad("actor", "actor required");
      if (agent === ARCHIE) return notFound();
      return d1Guarded("staff_chat", async () => {
        // One round trip for the reads (roster row and stop flags), then the insert.
        const { res, stopped } = await agentRead(env, agent, { flags: true });
        if (res) return res;
        await ensureTable(env, "staff_chat");
        const row = await env.DB.prepare(
          `INSERT INTO staff_chat (agent, role, text, actor, state, stopped_by, created_at, updated_at)
           VALUES (?1, 'operator', ?2, ?3, ?4, ?5, ?6, ?6) RETURNING *`
        ).bind(agent, text, actor, stopped ? "held" : "pending", stopped, t).first();
        return json(201, { message: msgOut(row), stopped: stopped !== null, stopped_by: stopped });
      });
    },
  ],

  // ── POST /api/staff/chat/take — claim open notes for one tick ─────────────
  // First the fail sweep: an open note that already used staff.chat.attempts_max
  // takes becomes 'failed' (reported in `failed`, never dropped in silence).
  // Then one claim UPDATE: its WHERE is the claim, so two ticks never both get
  // a note. A taken note whose tick never settled is open again after
  // staff.chat.take_lease_s. Each take counts one attempt. Both subqueries name
// idx_staff_chat_agent_state: without it the planner walks the agent's whole
// thread on idx_staff_chat_agent_id to skip the sort (W8 pins the plan).
  [
    "POST", "/api/staff/chat/take",
    async ({ env, t, body }) => {
      const agent = agentOf(body && body.agent);
      if (!agent) return bad("agent", "agent must match [a-z][a-z0-9-]{1,39}");
      const tickKey = typeof body.tick_key === "string" && KEY_RE.test(body.tick_key) ? body.tick_key : "";
      if (!tickKey) return bad("tick_key", "tick_key must match [a-z0-9][a-z0-9:._-]{0,119}");
      let limit = TAKE_DEFAULT;
      if (body.limit !== undefined && body.limit !== null) {
        if (!Number.isInteger(body.limit) || body.limit < 1 || body.limit > TAKE_MAX) return bad("limit", `limit must be 1..${TAKE_MAX}`);
        limit = body.limit;
      }
      if (agent === ARCHIE) return notFound();
      return d1Guarded("staff_chat", async () => {
        await ensureTable(env, "staff_chat");
        // One round trip: the roster row and both settings rows (one SELECT);
        // each key keeps its own range and code fallback.
        const { res, rest } = await agentRead(env, agent, { extra: [env.DB.prepare(
          "SELECT key, value FROM settings WHERE key IN (?1, ?2)"
        ).bind("staff.chat.attempts_max", "staff.chat.take_lease_s")] });
        if (res) return res;
        const sv = new Map(((rest[0] && rest[0].results) || []).map((r) => [r.key, r.value]));
        const max = intSetting(sv.get("staff.chat.attempts_max"), 1, 10, STAFF_CHAT_ATTEMPTS_MAX);
        const lease = intSetting(sv.get("staff.chat.take_lease_s"), 60, 86400, STAFF_CHAT_TAKE_LEASE_S);
        const cut = before(t, lease);
        // sql-ident-ok: SWEEP_MAX is a module const integer; every value is a ?N bind
        const failed = ((await env.DB.prepare(
          `UPDATE staff_chat SET state='failed', updated_at=?2
            WHERE id IN (SELECT id FROM staff_chat INDEXED BY idx_staff_chat_agent_state WHERE agent=?1 AND role='operator'
                           AND state IN ('pending','held','taken') AND (state <> 'taken' OR updated_at < ?3)
                           AND attempts >= ?4 ORDER BY id LIMIT ${SWEEP_MAX})
            RETURNING id, attempts`
        ).bind(agent, t, cut, max).all()).results || [])
          .map((r) => ({ id: Number(r.id), attempts: Number(r.attempts) })).sort((x, y) => x.id - y.id);
        const taken = ((await env.DB.prepare(
          `UPDATE staff_chat SET state='taken', tick_key=?2, attempts=attempts+1, updated_at=?3
            WHERE id IN (SELECT id FROM staff_chat INDEXED BY idx_staff_chat_agent_state WHERE agent=?1 AND role='operator'
                           AND state IN ('pending','held','taken') AND (state <> 'taken' OR updated_at < ?4)
                           AND attempts < ?5 ORDER BY id LIMIT ?6)
            RETURNING *`
        ).bind(agent, tickKey, t, cut, max, limit).all()).results || [])
          .map((r) => ({ id: Number(r.id), text: r.text, at: r.created_at, attempts: Number(r.attempts), tick_key: r.tick_key }))
          .sort((x, y) => x.id - y.id);
        return json(200, { notes: taken, failed, as_of: t });
      });
    },
  ],

  // ── POST /api/staff/chat/settle — the tick's answer ───────────────────────
  // Only a note of this agent that is 'taken' by THIS tick_key moves; any other
  // id is counted in `skipped`. One D1 batch (one transaction): per reply, the
  // reply row is inserted only while its note is still taken by this tick, then
  // the note becomes 'read', so "read" is never written without its reply row.
  // A second settle is a no-op: the note is no longer taken, and the UNIQUE
  // reply_to index refuses a second reply.
  [
    "POST", "/api/staff/chat/settle",
    async ({ env, t, body }) => {
      const agent = agentOf(body && body.agent);
      if (!agent) return bad("agent", "agent must match [a-z][a-z0-9-]{1,39}");
      const tickKey = typeof body.tick_key === "string" && KEY_RE.test(body.tick_key) ? body.tick_key : "";
      if (!tickKey) return bad("tick_key", "tick_key must match [a-z0-9][a-z0-9:._-]{0,119}");
      const rawReplies = body.replies === undefined || body.replies === null ? [] : body.replies;
      if (!Array.isArray(rawReplies)) return bad("replies", "replies must be a list of {id, text}");
      const replies = [];
      for (const r of rawReplies) {
        if (!r || typeof r !== "object" || !posId(r.id)) return bad("replies", "each reply needs a positive integer id");
        const text = typeof r.text === "string" ? r.text.trim() : "";
        if (!text) return bad("replies", `reply ${r.id} has no text`);
        replies.push({ id: r.id, text: text.slice(0, STEER_TEXT_MAX) });
      }
      const unanswered = idList(body.unanswered);
      if (!unanswered) return bad("unanswered", "unanswered must be a list of positive integer ids");
      const release = idList(body.release);
      if (!release) return bad("release", "release must be a list of positive integer ids");
      const all = [...replies.map((r) => r.id), ...unanswered, ...release];
      if (all.length === 0) return bad("ids", "name at least one note in replies, unanswered or release");
      if (all.length > SETTLE_IDS_MAX) return bad("ids", `at most ${SETTLE_IDS_MAX} notes per settle`);
      if (new Set(all).size !== all.length) return bad("ids", "a note id may appear once, in one list");
      const { res } = await agentRow(env, agent);
      if (res) return res;
      return d1Guarded("staff_chat", async () => {
        await ensureTable(env, "staff_chat");
        // sql-ident-ok: `mine` is the literal WHERE below; every value is a ?N bind
        const mine = "id=?1 AND agent=?2 AND role='operator' AND state='taken' AND tick_key=?3";
        const stmts = [];
        const kinds = [];
        for (const r of replies) {
          // sql-ident-ok: `mine` is the literal WHERE above; every value is a ?N bind
          stmts.push(env.DB.prepare(
            `INSERT OR IGNORE INTO staff_chat (agent, role, text, actor, state, reply_to, tick_key, created_at, updated_at)
             SELECT ?2, 'agent', ?4, ?2, 'sent', id, ?3, ?5, ?5 FROM staff_chat WHERE ${mine}`
          ).bind(r.id, agent, tickKey, r.text, t));
          kinds.push(null);
          // sql-ident-ok: `mine` is the literal WHERE above; every value is a ?N bind
          stmts.push(env.DB.prepare(`UPDATE staff_chat SET state='read', updated_at=?4 WHERE ${mine}`).bind(r.id, agent, tickKey, t));
          kinds.push("replied");
        }
        for (const id of unanswered) {
          // sql-ident-ok: `mine` is the literal WHERE above; every value is a ?N bind
          stmts.push(env.DB.prepare(`UPDATE staff_chat SET state='unanswered', updated_at=?4 WHERE ${mine}`).bind(id, agent, tickKey, t));
          kinds.push("unanswered");
        }
        for (const id of release) {
          // sql-ident-ok: `mine` is the literal WHERE above; every value is a ?N bind
          stmts.push(env.DB.prepare(`UPDATE staff_chat SET state='pending', updated_at=?4 WHERE ${mine}`).bind(id, agent, tickKey, t));
          kinds.push("released");
        }
        const results = await env.DB.batch(stmts);
        const out = { replied: 0, unanswered: 0, released: 0, skipped: 0 };
        results.forEach((r, i) => {
          if (kinds[i]) out[kinds[i]] += Number((r && r.meta && r.meta.changes) || 0);
        });
        out.skipped = all.length - out.replied - out.unanswered - out.released;
        return json(200, { ...out, as_of: t });
      });
    },
  ],
];
