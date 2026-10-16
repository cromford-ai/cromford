// staff routes — BH-5559 (BH-5556.2): the staff charter and autonomy tables.
//
// The roster is staff_agents plus staff_lanes (schema.sql, BH-5559 block). Each
// row is composed into one charter and checked with agent-core's
// charter.schema.json: a row that fails is named in `invalid` and is not served
// (complete: false), never passed on as if it were whole.
//
// An agent's level moves only through POST /api/staff/agents/autonomy. It is
// refused above the agent's cap (409 above_cap) and a raise by archie or by any
// staff agent is refused (403 self_promotion): a human promotes. A lower level
// is open to any actor. agent-core decide() is not the gate here, because it
// refuses every automation request, and automation is the level a demotion
// goes to. The level must be one of agent-core LEVELS, and the UPDATE moves it
// only when its rank is at or below the cap's rank (the table CHECK backs it).
//
// A staff class moves to delegated only through POST /api/staff/classes/delegation.
// agent-core decide('autonomy', <the lower of the agent cap and the class cap>,
// {name, never}) must answer allow: a protected class (never_delegable, or a
// name archie-autonomy.js's isProtectedSlug matches) is 409 never_delegable,
// and a cap below autonomy on either side is 409 capped. Then the streak must
// reach the settings row staff.delegate_after (default 5, named in the answer
// when the row is absent or junk).
//
// These routes read the staff_* tables (and the one settings row), never
// archie_classes, and Archie's routes never read staff_classes, so a class in
// one family is invisible to the other.

import { json, d1Guarded } from "../lib/http.js";
import { decide, validate, LEVELS } from "../../../../agent-core/src/index.js";
import CHARTER from "../../../../agent-core/schema/charter.schema.json" with { type: "json" };
import { isProtectedSlug } from "./archie-autonomy.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const CLASS_RE = /^[a-z][a-z0-9-]{1,40}$/;
// The documented fallback when settings row staff.delegate_after is absent or junk.
const DELEGATE_AFTER_DEFAULT = 5;

// THE agent identity: trimmed and lowercased here and nowhere else.
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
// THE class identity, the same rule as archie-autonomy.js.
const classOf = (v) => {
  if (typeof v !== "string") return null;
  const c = v.trim().toLowerCase();
  return CLASS_RE.test(c) ? c : null;
};
const actorOf = (v) => {
  const a = typeof v === "string" ? v.trim() : "";
  return a.length >= 1 && a.length <= 64 ? a : null;
};
const rank = (level) => LEVELS.indexOf(level);
const RANK_SQL = (x) => `CASE ${x} WHEN 'automation' THEN 0 WHEN 'augmentation' THEN 1 ELSE 2 END`;

const bad = (field) => json(400, { error: field });
const NOT_FOUND = () => json(404, { error: "agent not found" });

const readAgent = (env, name) => env.DB.prepare(`SELECT * FROM staff_agents WHERE name=?1`).bind(name).first();
const readLanes = async (env, name) => {
  const { results } = await env.DB.prepare(`SELECT lane FROM staff_lanes WHERE agent=?1 ORDER BY lane`).bind(name).all();
  return (results || []).map((r) => r.lane);
};
const readClass = (env, a, c) =>
  env.DB.prepare(`SELECT * FROM staff_classes WHERE agent=?1 AND class=?2`).bind(a, c).first();
const charterOf = (row, lanes) => ({
  name: row.name, role: row.role, accountable: row.accountable, autonomy: row.autonomy,
  cap: row.cap, status: row.status, soul: row.soul_path, lanes,
});
const classState = (row) => row && ({
  agent: row.agent, class: row.class, cap: row.cap, state: row.state, streak: Number(row.streak),
  never_delegable: row.never_delegable === 1,
});
// archie, or any staff agent: an agent never raises an agent.
const isAgentActor = async (env, actor) => {
  const a = actor.toLowerCase();
  if (a === "archie") return true;
  return !!(await env.DB.prepare(`SELECT 1 AS x FROM staff_agents WHERE name=?1`).bind(a).first());
};
const delegateAfter = async (env) => {
  const row = await env.DB.prepare(`SELECT value FROM settings WHERE key='staff.delegate_after'`).first();
  const v = row && typeof row.value === "string" ? row.value.trim() : "";
  if (/^\d{1,4}$/.test(v) && Number(v) >= 1 && Number(v) <= 1000) return { min: Number(v), source: "settings" };
  return { min: DELEGATE_AFTER_DEFAULT, source: "default" };
};

export const routes = [
  // ── GET /api/staff/agents — the roster, one validated charter per agent ────
  [
    "GET", "/api/staff/agents",
    async ({ env }) => d1Guarded("staff_agents", async () => {
      const { results: rows } = await env.DB.prepare(`SELECT * FROM staff_agents ORDER BY name`).all();
      const { results: laneRows } = await env.DB.prepare(`SELECT agent, lane FROM staff_lanes ORDER BY agent, lane`).all();
      const lanes = new Map();
      for (const l of laneRows || []) lanes.set(l.agent, [...(lanes.get(l.agent) || []), l.lane]);
      const agents = [];
      const invalid = [];
      for (const row of rows || []) {
        const charter = charterOf(row, lanes.get(row.name) || []);
        const v = validate(CHARTER, charter);
        if (v.ok) agents.push(charter);
        else invalid.push({ name: row.name, errors: v.errors });
      }
      return json(200, { agents, invalid, complete: invalid.length === 0 });
    }),
  ],

  // ── GET /api/staff/agent?name= — one charter ───────────────────────────────
  [
    "GET", "/api/staff/agent",
    async ({ env, url }) => {
      const name = agentOf(url.searchParams.get("name"));
      if (name === null) return bad("name");
      return d1Guarded("staff_agents", async () => {
        const row = await readAgent(env, name);
        if (!row) return NOT_FOUND();
        const charter = charterOf(row, await readLanes(env, name));
        const v = validate(CHARTER, charter);
        if (!v.ok) return json(503, { error: "agent row invalid", errors: v.errors });
        return json(200, { agent: charter });
      });
    },
  ],

  // ── POST /api/staff/agents/autonomy — set an agent's level, never above cap ─
  [
    "POST", "/api/staff/agents/autonomy",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const name = agentOf(b.agent);
      if (name === null) return bad("agent");
      if (typeof b.autonomy !== "string" || rank(b.autonomy) < 0) return bad("autonomy");
      const actor = actorOf(b.actor);
      if (actor === null) return bad("actor");

      return d1Guarded("staff_agents", async () => {
        const row = await readAgent(env, name);
        if (!row) return NOT_FOUND();
        const rises = rank(b.autonomy) > rank(row.autonomy);
        if (rises && await isAgentActor(env, actor)) return json(403, { error: "self_promotion" });
        if (row.autonomy === b.autonomy) {
          return json(200, { ok: true, existing: true, agent: charterOf(row, await readLanes(env, name)) });
        }
        // The cap gate: the rank comparison sits in the WHERE, so the read
        // and the write cannot disagree. The table CHECK backs it.
        // sql-ident-ok: RANK_SQL is a module helper called only with the literals ?2 and cap
        const res = await env.DB.prepare(
          `UPDATE staff_agents SET autonomy = ?2, updated_at = ?3, note = ?4
            WHERE name = ?1 AND ${RANK_SQL("?2")} <= ${RANK_SQL("cap")}`
        ).bind(name, b.autonomy, t, `autonomy ${b.autonomy} by ${actor}`).run();
        const after = await readAgent(env, name);
        if (Number((res.meta && res.meta.changes) || 0) !== 1) {
          // Above the cap (or a racing cap change won): the level did not move.
          return json(409, { error: "above_cap", autonomy: b.autonomy, cap: after ? after.cap : null });
        }
        return json(200, { ok: true, agent: charterOf(after, await readLanes(env, name)) });
      });
    },
  ],

  // ── POST /api/staff/classes/delegation — delegate or ask_first one class ───
  [
    "POST", "/api/staff/classes/delegation",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const name = agentOf(b.agent);
      if (name === null) return bad("agent");
      const c = classOf(b.class);
      if (c === null) return bad("class");
      if (b.decision !== "delegate" && b.decision !== "ask_first") return bad("decision");
      const actor = actorOf(b.actor);
      if (actor === null) return bad("actor");

      return d1Guarded("staff_classes", async () => {
        const agent = await readAgent(env, name);
        if (!agent) return NOT_FOUND();
        const row = await readClass(env, name, c);
        if (!row) return json(404, { error: `class ${c} not found` });
        if (b.decision === "ask_first") {
          await env.DB.prepare(
            `UPDATE staff_classes SET state = 'ask_first', streak = 0, updated_at = ?3, note = ?4,
                    reverted_at = CASE WHEN state = 'delegated' THEN ?3 ELSE reverted_at END
              WHERE agent = ?1 AND class = ?2`
          ).bind(name, c, t, `ask first by ${actor}`).run();
          return json(200, { ok: true, class_state: classState(await readClass(env, name, c)) });
        }
        if (await isAgentActor(env, actor)) return json(403, { error: "self_delegation" });
        if (agent.status !== "active") return json(409, { error: "agent_not_active", status: agent.status });
        const effectiveCap = LEVELS[Math.min(rank(agent.cap), rank(row.cap))];
        const never = row.never_delegable === 1 || isProtectedSlug(c) ? [c] : [];
        if (decide("autonomy", effectiveCap, { name: c, never }) !== "allow") {
          return json(409, {
            error: never.length ? "never_delegable" : "capped",
            agent_cap: agent.cap, class_cap: row.cap, class_state: classState(row),
          });
        }
        if (row.state === "delegated") return json(200, { ok: true, existing: true, class_state: classState(row) });
        const { min, source } = await delegateAfter(env);
        const res = await env.DB.prepare(
          `UPDATE staff_classes SET state = 'delegated', delegated_at = ?3, updated_at = ?3, note = ?5
            WHERE agent = ?1 AND class = ?2 AND state = 'ask_first' AND never_delegable = 0
              AND cap = 'autonomy' AND streak >= ?4
              AND EXISTS (SELECT 1 FROM staff_agents a WHERE a.name = ?1 AND a.cap = 'autonomy' AND a.status = 'active')`
        ).bind(name, c, t, min, `delegated by ${actor}`).run();
        const after = await readClass(env, name, c);
        const out = { min_streak: min, min_streak_source: source, class_state: classState(after) };
        if (Number((res.meta && res.meta.changes) || 0) !== 1 && after.state !== "delegated") {
          return json(409, { error: "not_earned", streak: Number(after.streak), ...out });
        }
        return json(200, { ok: true, ...out });
      });
    },
  ],
];
