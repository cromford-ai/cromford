// split-watchdog routes — BH-1806 (BH-1793.1): the split-watchdog action ledger
// over split_watchdog_actions (worker/jobs/schema.sql, landed by BH-1805).
//
//   POST /api/split-watchdog   {project, family, child, step, reason?, outcome?, actor?}
//                              records one action; the same (project, child,
//                              step, reason_fp) again bumps repeats and moves
//                              last_at and outcome. Answers
//                              {recorded:true, repeats, first, reason_fp}.
//   GET  /api/split-watchdog?project&child&step&(reason_fp|reason)
//                              point lookup on the full key: {split_watchdog_action:
//                              row|null}. An absent row is 200 + null, never a
//                              404, so a client never has to tell "not seen"
//                              from an rc it also gets on an outage.
//   GET  /api/split-watchdog?project[&family][&since][&outcome][&limit]
//                              the project's rows, newest last_at first, at most
//                              500 (a larger limit is clamped), truncated:true
//                              when there were more.
//
// reason_fp IS COMPUTED HERE AND ONLY HERE: sha1 of the reason trimmed and with
// every whitespace run collapsed to one space, first 12 hex. Case is kept
// (PLAN_STALE and plan_stale are two reasons). A reason_fp in a POST body is
// ignored; the GET point lookup accepts one only because a caller may hold it
// from a list row (a malformed one is a 400, never a fallback to another key).
// The fp is taken over the FULL reason; only the stored copy is cut to 500, so
// a long reason is found by the same text it was recorded with.
//
// ONE KEY NORMALIZATION FOR BOTH VERBS: keyOf() validates child and step the
// same way on the write and the point lookup. An over-long child is a 400 on
// both sides rather than truncated on one, so a lookup can never miss a row
// the write made (BH-1806 review).
//
// The shell side is sw_record / sw_seen / sw_list / sw_actions_today in
// bin/lib/jobs/split-watchdog.sh.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, laneName, str } from "../lib/core.js";

export const SW_LIST_MAX = 500;
const STEP_RE = /^[a-z][a-z0-9-]{0,31}$/;
const FP_RE = /^[0-9a-f]{12}$/;
const CHILD_MAX = 128;
const REASON_MAX = 500;

// {child, step} or {error}: the shared validation of the key's text parts.
function keyOf(rawChild, rawStep) {
  const child = rawChild === undefined || rawChild === null ? "" : String(rawChild);
  if (!child) return { error: "child is required" };
  if (child.length > CHILD_MAX) return { error: `child must be at most ${CHILD_MAX} characters` };
  const step = typeof rawStep === "string" ? rawStep : "";
  if (!STEP_RE.test(step)) return { error: "step must match [a-z][a-z0-9-]{0,31}" };
  return { child, step };
}

export async function reasonFp(reason) {
  const norm = String(reason ?? "").trim().replace(/\s+/g, " ");
  const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(norm));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 12);
}

export const routes = [
  [
    "POST", "/api/split-watchdog",
    async ({ env, t, body }) => d1Guarded("split_watchdog_actions", async () => {
      const b = body && typeof body === "object" ? body : {};
      const project = laneName(b.project);
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const family = str(b.family, 128);
      if (!family) return json(400, { error: "family is required" });
      const key = keyOf(b.child, b.step);
      if (key.error) return json(400, { error: key.error });
      const { child, step } = key;
      const fp = await reasonFp(b.reason);
      const reason = str(b.reason, REASON_MAX);
      const outcome = str(b.outcome, 32);
      const actor = str(b.actor, 64);
      await ensureTable(env, "split_watchdog_actions");
      await env.DB.prepare(
        "INSERT INTO split_watchdog_actions (project, family, child, step, reason_fp, reason, outcome, repeats, first_at, last_at, actor) "
        + "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, ?8, ?8, ?9) "
        + "ON CONFLICT(project, child, step, reason_fp) DO UPDATE SET repeats=repeats+1, last_at=?8, outcome=?7"
      ).bind(project, family, child, step, fp, reason, outcome, t, actor).run();
      const repeats = await env.DB.prepare(
        "SELECT repeats FROM split_watchdog_actions WHERE project=?1 AND child=?2 AND step=?3 AND reason_fp=?4"
      ).bind(project, child, step, fp).first("repeats");
      if (typeof repeats !== "number") return json(503, { error: "split_watchdog_actions row not readable after write" });
      return json(200, { recorded: true, repeats, first: repeats === 1, reason_fp: fp });
    }),
  ],

  [
    "GET", "/api/split-watchdog",
    async ({ env, url, t }) => d1Guarded("split_watchdog_actions", async () => {
      const q = url.searchParams;
      const project = laneName(q.get("project"));
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      if (q.has("child") && q.has("step") && (q.has("reason_fp") || q.has("reason"))) {
        const key = keyOf(q.get("child"), q.get("step"));
        if (key.error) return json(400, { error: key.error });
        const { child, step } = key;
        const given = q.get("reason_fp");
        if (given !== null && !FP_RE.test(given)) return json(400, { error: "reason_fp must be 12 lowercase hex" });
        const fp = given !== null ? given : await reasonFp(q.get("reason"));
        await ensureTable(env, "split_watchdog_actions");
        const row = await env.DB.prepare(
          "SELECT * FROM split_watchdog_actions WHERE project=?1 AND child=?2 AND step=?3 AND reason_fp=?4"
        ).bind(project, child, step, fp).first();
        return json(200, { split_watchdog_action: row || null, as_of: t });
      }
      const rawLimit = q.get("limit");
      let limit = SW_LIST_MAX;
      if (rawLimit !== null && rawLimit !== "") {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : 0;
        if (limit < 1) return json(400, { error: "limit must be a positive integer" });
        limit = Math.min(limit, SW_LIST_MAX);
      }
      const where = ["project=?"];
      const binds = [project];
      for (const [param, clause] of [["family", "family=?"], ["since", "last_at>=?"], ["outcome", "outcome=?"]]) {
        const v = q.get(param);
        if (v !== null && v !== "") { where.push(clause); binds.push(v); }
      }
      await ensureTable(env, "split_watchdog_actions");
      // sql-ident-ok: where holds literal column=? clauses; limit is a Number clamped to SW_LIST_MAX
      const rows = (await env.DB.prepare(
        `SELECT * FROM split_watchdog_actions WHERE ${where.join(" AND ")} `
        + `ORDER BY last_at DESC, child ASC, step ASC, reason_fp ASC LIMIT ${limit + 1}`
      ).bind(...binds).all()).results || [];
      return json(200, { project, rows: rows.slice(0, limit), truncated: rows.length > limit, as_of: t });
    }),
  ],
];
