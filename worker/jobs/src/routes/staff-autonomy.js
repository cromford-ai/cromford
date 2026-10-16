// staff-autonomy routes — BH-6824 (Staff in Mission Control 3/4): what the
// agent page's AUTONOMY panel reads.
//
// GET /api/staff/autonomy?agent=<name>
//   The agent's level, cap and status; every staff class of that agent with
//   its state; and the newest audit rows (staff_autonomy_changes, written by
//   the two write routes in staff.js). A class is `protected` when its
//   never_delegable column is 1 or archie-autonomy.js's isProtectedSlug
//   matches its name, the same test the delegation route refuses on, and its
//   display_state is then never_delegable. effective_cap is the lower of the
//   agent cap and the class cap. The list holds at most the settings row
//   staff.autonomy_changes_shown rows (1-500; absent or junk is the documented
//   fallback 20, and changes_limit_source says which), and changes_truncated
//   says when older rows exist. Archie is not a staff agent: 404.
import { json, d1Guarded } from "../lib/http.js";
import { LEVELS } from "../../../../agent-core/src/index.js";
import { isProtectedSlug } from "./archie-autonomy.js";
import { agentOf, delegateAfter } from "./staff.js";

// The documented fallback when settings row staff.autonomy_changes_shown is absent or junk.
const CHANGES_SHOWN_DEFAULT = 20;

const changesShown = async (env) => {
  const row = await env.DB.prepare(`SELECT value FROM settings WHERE key='staff.autonomy_changes_shown'`).first();
  const v = row && typeof row.value === "string" ? row.value.trim() : "";
  if (/^\d{1,3}$/.test(v) && Number(v) >= 1 && Number(v) <= 500) return { limit: Number(v), source: "settings" };
  return { limit: CHANGES_SHOWN_DEFAULT, source: "default" };
};
const rank = (level) => LEVELS.indexOf(level);

export const routes = [
  [
    "GET", "/api/staff/autonomy",
    async ({ env, url }) => {
      const name = agentOf(url.searchParams.get("agent"));
      if (name === null) return json(400, { error: "agent" });
      return d1Guarded("staff_agents", async () => {
        const a = await env.DB.prepare(`SELECT name, autonomy, cap, status FROM staff_agents WHERE name=?1`).bind(name).first();
        if (!a) return json(404, { error: "agent not found" });
        const { results } = await env.DB.prepare(`SELECT * FROM staff_classes WHERE agent=?1 ORDER BY class`).bind(name).all();
        const classes = (results || []).map((r) => {
          const prot = r.never_delegable === 1 || isProtectedSlug(r.class);
          return {
            class: r.class, cap: r.cap, effective_cap: LEVELS[Math.min(rank(a.cap), rank(r.cap))],
            state: r.state, streak: Number(r.streak), never_delegable: r.never_delegable === 1,
            protected: prot, display_state: prot ? "never_delegable" : r.state,
          };
        });
        const delegate_after = await delegateAfter(env);
        const { limit, source } = await changesShown(env);
        return d1Guarded("staff_autonomy_changes", async () => {
          const { results: rows } = await env.DB.prepare(
            `SELECT id, agent, kind, class, from_value, to_value, actor, reason, created_at
               FROM staff_autonomy_changes WHERE agent=?1 ORDER BY id DESC LIMIT ?2`
          ).bind(name, limit + 1).all();
          const list = rows || [];
          return json(200, {
            agent: { name: a.name, autonomy: a.autonomy, cap: a.cap, status: a.status },
            levels: LEVELS, classes, delegate_after,
            changes: list.slice(0, limit), changes_limit: limit, changes_limit_source: source,
            changes_truncated: list.length > limit,
          });
        });
      });
    },
  ],
];
