// alert-lines routes — alert lines a lane-run machine raised, for the hub to
// replay into its logs/ALERTS.log (BH-6889, BH-6881.5). Contract:
// docs/notes/2026-10-16-BH-6889-mc-manifest-alert-lines.md. Machine client:
// bin/lib/alert-line-remote.sh alr_post (bin/alert-line.sh with LANE_RUN_ID
// set). Hub client: alr_apply (bin/lane-snapshot-publish.sh). Table and
// settings rows: worker/jobs/schema.d/*-bh-6889-alert-lines.sql.
//
// POST /api/alert-lines {lane, project, line, stamp?, severity?, alertid?, run_id?}
//   ONE insert keyed on dedup_key = sha256(lane|project|run_id|line). A repeat
//   of the same payload adds no row. 200 {id, dup}.
// GET /api/alert-lines?unapplied=1&limit=n   (limit 1..500, default 200)
//   {lines:[...], truncated, as_of}, oldest id first. truncated is true when
//   more than `limit` unapplied rows exist.
// POST /api/alert-lines/applied {ids:[...]}   (1..500 ids)
//   Marks the rows applied. A row already applied is not counted again, so a
//   repeat answers {applied:0}. 200 {applied}.

import { d1Guarded, json } from "../lib/http.js";

const COLS = "id, lane, project, line, stamp, severity, alertid, dedup_key, created_at";

// Exported so the tests explain the exact statements.
export const INSERT_SQL = `INSERT INTO alert_lines (lane,project,line,stamp,severity,alertid,run_id,dedup_key,created_at)
VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
ON CONFLICT(dedup_key) DO NOTHING`;
export const BY_KEY_SQL = "SELECT id FROM alert_lines WHERE dedup_key=?1";
export const UNAPPLIED_SQL = `SELECT ${COLS} FROM alert_lines WHERE applied_at IS NULL ORDER BY id LIMIT ?1`;
export const APPLIED_SQL = `UPDATE alert_lines SET applied_at=?1
WHERE applied_at IS NULL AND id IN (SELECT value FROM json_each(?2))`;

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// "resolved" (BH-6892): a machine's retraction; the hub replay beats resolved:true.
const SEVERITIES = ["info", "warn", "critical", "resolved"];
const LINE_MAX = 2000;
const STAMP_MAX = 40;
const ID_MAX = 120;
const LIMIT_MAX = 500;
const LIMIT_DEF = 200;

const obj = (raw) => (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {});
const opt = (v) => (v === undefined || v === null || v === "" ? null : v);

// The validated line, or { error } for a 400. Each error starts with the field name.
function parseLine(raw) {
  const b = obj(raw);
  if (typeof b.lane !== "string" || !NAME_RE.test(b.lane)) return { error: "lane must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}" };
  if (typeof b.project !== "string" || !NAME_RE.test(b.project)) return { error: "project must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}" };
  const line = b.line;
  if (typeof line !== "string" || line.length < 1 || line.length > LINE_MAX || /[\r\n]/.test(line)) {
    return { error: `line must be 1..${LINE_MAX} chars with no newline` };
  }
  const stamp = opt(b.stamp);
  if (stamp !== null && (typeof stamp !== "string" || stamp.length > STAMP_MAX || !line.startsWith(`${stamp} `))) {
    return { error: `stamp must be at most ${STAMP_MAX} chars and the line must start with it and a space` };
  }
  const severity = opt(b.severity);
  if (severity !== null && !SEVERITIES.includes(severity)) return { error: `severity must be one of ${SEVERITIES.join(", ")}` };
  const alertid = opt(b.alertid);
  if (alertid !== null && (typeof alertid !== "string" || alertid.length > ID_MAX)) return { error: `alertid must be at most ${ID_MAX} chars` };
  const runId = opt(b.run_id);
  if (runId !== null && (typeof runId !== "string" || runId.length > ID_MAX)) return { error: `run_id must be at most ${ID_MAX} chars` };
  return { lane: b.lane, project: b.project, line, stamp, severity, alertid, runId };
}

async function sha256Hex(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

export const routes = [
  [
    "POST", "/api/alert-lines",
    ({ env, t, body }) => d1Guarded("alert_lines", async () => {
      const q = parseLine(body);
      if (q.error) return json(400, { error: q.error });
      const key = await sha256Hex(`${q.lane}|${q.project}|${q.runId ?? ""}|${q.line}`);
      const ins = await env.DB.prepare(INSERT_SQL)
        .bind(q.lane, q.project, q.line, q.stamp, q.severity, q.alertid, q.runId, key, t).run();
      const row = await env.DB.prepare(BY_KEY_SQL).bind(key).first();
      if (!row) return json(503, { error: "alert_lines write returned no row" });
      const changes = Number(ins?.meta?.changes ?? 0);
      return json(200, { id: Number(row.id), dup: changes === 0 });
    }),
  ],
  [
    "GET", "/api/alert-lines",
    ({ env, url, t }) => d1Guarded("alert_lines", async () => {
      if (url.searchParams.get("unapplied") !== "1") return json(400, { error: "unapplied=1 is required" });
      const lRaw = url.searchParams.get("limit");
      let limit = LIMIT_DEF;
      if (lRaw !== null) {
        if (!/^[0-9]{1,3}$/.test(lRaw) || Number(lRaw) < 1 || Number(lRaw) > LIMIT_MAX) {
          return json(400, { error: `limit must be 1..${LIMIT_MAX}` });
        }
        limit = Number(lRaw);
      }
      const { results } = await env.DB.prepare(UNAPPLIED_SQL).bind(limit + 1).all();
      const rows = results || [];
      return json(200, { lines: rows.slice(0, limit), truncated: rows.length > limit, as_of: t });
    }),
  ],
  [
    "POST", "/api/alert-lines/applied",
    ({ env, t, body }) => d1Guarded("alert_lines", async () => {
      const ids = obj(body).ids;
      if (!Array.isArray(ids) || ids.length < 1 || ids.length > LIMIT_MAX
        || !ids.every((x) => Number.isSafeInteger(x) && x > 0)) {
        return json(400, { error: `ids must be an array of 1..${LIMIT_MAX} positive integers` });
      }
      const r = await env.DB.prepare(APPLIED_SQL).bind(t, JSON.stringify(ids)).run();
      return json(200, { applied: Number(r?.meta?.changes ?? 0) });
    }),
  ],
];
