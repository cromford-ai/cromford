// alert-decisions routes — BH-6972 (BH-6546.2): the record of what
// bin/component-watch.sh decided on each open alert of a component, and what
// applying the decision did. Table: worker/jobs/schema.d/*-bh-6972-alert-decisions.sql.
// test/route-table.d/bh-6972-alert-decisions.txt pins this route list.
//
// POST /api/alerts/decisions  body {run_id, component, decisions:[{alert_id,
//   verdict, until?, reason, title?, outcome, issue?}]}
//   1..60 rows. Every field is checked first; one bad row is a 400 that writes
//   nothing (refused, never sliced). Then ONE batch of INSERTs, `at` = the
//   request time. 200 {written, as_of}.
//
// GET /api/alerts/decisions with exactly one of
//   ?alert_id=<id>[&limit=]      that alert's rows, newest first
//   ?alert_ids=<id,id,...>       the newest row of each id (1..50 ids)
//   ?component=<name>[&limit=]   that component's rows, newest first
//   limit is 1..200 (default 50), refused outside it; `truncated` is measured
//   from one extra row.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { ALERT_ID_RE, ALERT_COMPONENT_RE } from "./alerts.js";

export const AD_VERDICTS = ["resolve", "park", "ticket", "escalate"];
export const AD_OUTCOMES = ["applied", "noop", "deferred", "ticket-exists", "invalid"];
const AD_FAILED_RE = /^failed:[a-z0-9-]{1,60}$/;
const AD_RUN_RE = /^[A-Za-z0-9._:-]{1,80}$/;
// An `invalid` row records the verdict token the model gave, which is not one
// of the four by definition; it still has to be one plain token.
const AD_RAW_VERDICT_RE = /^[A-Za-z0-9._-]{1,40}$/;
const AD_ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const AD_ROWS_MAX = 60;
const AD_IDS_MAX = 50;
const AD_REASON_MAX = 500;
const AD_TITLE_MAX = 120;
const LIST_DEFAULT = 50;
const LIST_MAX = 200;
const COLS = "id, alert_id, component, run_id, verdict, until, reason, title, outcome, issue, at";

const guarded = (fn) => (ctx) =>
  d1Guarded("alert_decisions", async () => {
    await ensureTable(ctx.env, "alert_decisions");
    return fn(ctx);
  });

// row(d) -> the row to insert, or a string that says what is wrong with it.
function row(d, i) {
  if (!d || typeof d !== "object" || Array.isArray(d)) return `decisions[${i}] must be an object`;
  if (typeof d.alert_id !== "string" || !ALERT_ID_RE.test(d.alert_id)) return `decisions[${i}].alert_id must match ^[A-Za-z0-9_.-]{1,120}$`;
  const outcome = typeof d.outcome === "string" ? d.outcome : "";
  if (!AD_OUTCOMES.includes(outcome) && !AD_FAILED_RE.test(outcome)) {
    return `decisions[${i}].outcome must be one of ${AD_OUTCOMES.join("|")} or failed:<[a-z0-9-]{1,60}>`;
  }
  const verdict = typeof d.verdict === "string" ? d.verdict : "";
  const vOk = AD_VERDICTS.includes(verdict) || (outcome === "invalid" && AD_RAW_VERDICT_RE.test(verdict));
  if (!vOk) return `decisions[${i}].verdict must be one of ${AD_VERDICTS.join("|")}`;
  let until = null;
  if (d.until !== undefined && d.until !== null) {
    if (verdict !== "park") return `decisions[${i}].until is for a park only`;
    if (typeof d.until !== "string" || !AD_ISO_RE.test(d.until)) return `decisions[${i}].until must be YYYY-MM-DDTHH:MM:SSZ`;
    until = d.until;
  }
  if (typeof d.reason !== "string" || d.reason.trim() === "" || d.reason.length > AD_REASON_MAX) {
    return `decisions[${i}].reason must be 1..${AD_REASON_MAX} characters`;
  }
  let title = null;
  if (d.title !== undefined && d.title !== null) {
    if (typeof d.title !== "string" || d.title.length > AD_TITLE_MAX) return `decisions[${i}].title must be at most ${AD_TITLE_MAX} characters`;
    title = d.title || null;
  }
  let issue = null;
  if (d.issue !== undefined && d.issue !== null) {
    if (!Number.isInteger(d.issue) || d.issue < 1) return `decisions[${i}].issue must be a positive integer`;
    issue = d.issue;
  }
  return { alert_id: d.alert_id, verdict, until, reason: d.reason, title, outcome, issue };
}

// limitOf(raw) -> the page size, or null when it is not an integer 1..200.
function limitOf(raw) {
  if (raw === null) return LIST_DEFAULT;
  if (!/^\d+$/.test(raw)) return null;
  const n = Number(raw);
  return n >= 1 && n <= LIST_MAX ? n : null;
}

export const routes = [
  [
    "POST", "/api/alerts/decisions",
    guarded(async ({ env, t, body }) => {
      const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
      const runId = typeof b.run_id === "string" ? b.run_id : "";
      if (!AD_RUN_RE.test(runId)) return json(400, { error: "run_id must match ^[A-Za-z0-9._:-]{1,80}$" });
      const component = typeof b.component === "string" ? b.component : "";
      if (!ALERT_COMPONENT_RE.test(component)) return json(400, { error: "component must match ^[a-z][a-z0-9-]{0,63}$" });
      if (!Array.isArray(b.decisions) || b.decisions.length < 1 || b.decisions.length > AD_ROWS_MAX) {
        return json(400, { error: `decisions must be an array of 1..${AD_ROWS_MAX} rows` });
      }
      const rows = [];
      for (let i = 0; i < b.decisions.length; i++) {
        const r = row(b.decisions[i], i);
        if (typeof r === "string") return json(400, { error: r });
        rows.push(r);
      }
      await env.DB.batch(rows.map((r) => env.DB.prepare(
        `INSERT INTO alert_decisions (alert_id, component, run_id, verdict, until, reason, title, outcome, issue, at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)`
      ).bind(r.alert_id, component, runId, r.verdict, r.until, r.reason, r.title, r.outcome, r.issue, t)));
      return json(200, { written: rows.length, as_of: t });
    }),
  ],

  [
    "GET", "/api/alerts/decisions",
    guarded(async ({ env, url, t }) => {
      const q = url.searchParams;
      const given = ["alert_id", "alert_ids", "component"].filter((k) => q.get(k) !== null);
      if (given.length !== 1) return json(400, { error: "give exactly one of alert_id, alert_ids, component" });
      const limit = limitOf(q.get("limit"));
      if (limit === null) return json(400, { error: `limit must be an integer 1..${LIST_MAX}` });

      if (given[0] === "alert_ids") {
        const ids = q.get("alert_ids").split(",");
        if (ids.length < 1 || ids.length > AD_IDS_MAX || !ids.every((id) => ALERT_ID_RE.test(id))) {
          return json(400, { error: `alert_ids must be 1..${AD_IDS_MAX} comma-separated ids matching ^[A-Za-z0-9_.-]{1,120}$` });
        }
        // One window query over one index range per id: no per-row subquery.
        // sql-ident-ok: COLS is a module constant
        const rows = (await env.DB.prepare(
          `SELECT ${COLS} FROM (
             SELECT ${COLS}, ROW_NUMBER() OVER (PARTITION BY alert_id ORDER BY at DESC, id DESC) AS rn
             FROM alert_decisions WHERE alert_id IN (SELECT value FROM json_each(?1))
           ) WHERE rn = 1 ORDER BY alert_id`
        ).bind(JSON.stringify([...new Set(ids)])).all()).results || [];
        return json(200, { latest: rows, as_of: t });
      }

      const key = given[0];
      const v = q.get(key);
      if (key === "alert_id" && !ALERT_ID_RE.test(v)) return json(400, { error: "alert_id must match ^[A-Za-z0-9_.-]{1,120}$" });
      if (key === "component" && !ALERT_COMPONENT_RE.test(v)) return json(400, { error: "component must match ^[a-z][a-z0-9-]{0,63}$" });
      const col = key === "alert_id" ? "alert_id" : "component";
      // sql-ident-ok: COLS is a module constant; col is one of two literals chosen above
      const rows = (await env.DB.prepare(
        `SELECT ${COLS} FROM alert_decisions WHERE ${col} = ?1 ORDER BY at DESC, id DESC LIMIT ?2`
      ).bind(v, limit + 1).all()).results || [];
      return json(200, { decisions: rows.slice(0, limit), truncated: rows.length > limit, as_of: t });
    }),
  ],
];
