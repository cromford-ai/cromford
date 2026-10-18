// scheduler routes — the scheduler's inputs, its agreement record and its
// ready set (BH-6978, BH-6547.2; BH-6979, BH-6547.3). Contracts:
// docs/notes/2026-10-16-BH-6978-scheduler-shadow.md and
// docs/notes/2026-10-17-BH-6979-scheduler-enforce.md. Writer: bin/scheduler.sh
// (hub lane, */5). Tables and settings rows:
// worker/jobs/schema.d/202610170424-bh-6978-scheduler-shadow.sql and
// worker/jobs/schema.d/202610170717-bh-6979-scheduler-ready.sql. Nothing here
// dispatches: in scheduler.mode=enforce, bin/lib/sched-gate.sh reads the
// ready set and the pool and run-build act on it.
//
// GET /api/scheduler/holds?project=
//   {holds:[{ticket, state, by, at}]}: the latest ticket_holds row per ticket,
//   ORDER BY ticket, LIMIT 1000.
// POST /api/scheduler/diffs {project, at, mode: shadow|enforce, counts:{candidates,
//   ready, not_ready, unknown, in_flight, compared, agreed, idle}, partial?,
//   diffs:[{ticket, scheduler_says, lanes_did, reason, reason_class}],
//   verdicts?:[{ticket, ready: yes|no|unknown|in-flight, reason}]}
//   Every field is checked before any statement; one bad field is a 400 and
//   nothing is written. ONE batch: the tick insert, each diff insert and (when
//   verdicts is sent) ONE json_each insert of every verdict, all ON CONFLICT
//   DO NOTHING, so a retried POST for the same (project, at) writes nothing
//   new. 200 {ok:true, tick_written:0|1, diffs_written:n[, verdicts_written:n]}.
// GET /api/scheduler/ready?project=
//   {ok:true, project, at, mode, candidates, complete, verdicts:[{ticket,
//   ready, reason}]}: the newest tick's set, ordered by ticket number, in ONE
//   statement. complete = verdicts.length === candidates. No tick:
//   {ok:true, project, at:null, complete:false, verdicts:[]}.
// GET /api/scheduler/agreement?day=YYYY-MM-DD[&project=]
//   {ok:true, day, from, to, projects:[{project, ticks, compared, agreed,
//   idle, rate, top:[{reason_class, n}]}]}. rate = agreed/compared to 3
//   places, null when compared is 0. top: at most 5, n descending, ties by
//   reason_class. The two reads run in parallel.

import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { dayWindow } from "../lib/daily-digest/shape.js";

// Exported so the tests explain the exact statements.
export const HOLDS_LATEST_SQL = `SELECT ticket, state, by, at FROM (
  SELECT ticket, state, by, at, ROW_NUMBER() OVER (PARTITION BY ticket ORDER BY at DESC, id DESC) rn
  FROM ticket_holds WHERE project=?1
) WHERE rn=1 ORDER BY ticket LIMIT 1000`;
export const TICK_INSERT_SQL = `INSERT INTO sched_ticks (project,at,mode,candidates,ready,not_ready,unknown,in_flight,compared,agreed,idle,partial)
VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
ON CONFLICT(project,at) DO NOTHING`;
export const DIFF_INSERT_SQL = `INSERT INTO sched_diffs (project,ticket,scheduler_says,lanes_did,reason,reason_class,at)
VALUES (?1,?2,?3,?4,?5,?6,?7)
ON CONFLICT(project,ticket,at) DO NOTHING`;
export const READY_INSERT_SQL = `INSERT INTO sched_ready (project,at,ticket,ready,reason)
SELECT ?1, ?2, json_extract(j.value,'$[0]'), json_extract(j.value,'$[1]'), json_extract(j.value,'$[2]')
FROM json_each(?3) j WHERE true
ON CONFLICT(project,at,ticket) DO NOTHING`;
// The CTE runs once (uncorrelated); the join is an index range of the newest tick.
export const READY_SQL = `WITH t AS (SELECT at, mode, candidates FROM sched_ticks WHERE project=?1 ORDER BY at DESC LIMIT 1)
SELECT t.at, t.mode, t.candidates, r.ticket, r.ready, r.reason
FROM t LEFT JOIN sched_ready r ON r.project=?1 AND r.at=t.at
ORDER BY CAST(r.ticket AS INTEGER) LIMIT 1001`;
export const AGREE_TICKS_SQL = `SELECT project, COUNT(*) ticks, SUM(compared) compared, SUM(agreed) agreed, SUM(idle) idle
FROM sched_ticks INDEXED BY idx_sched_ticks_at WHERE at>=?1 AND at<?2 AND (?3 IS NULL OR project=?3)
GROUP BY project ORDER BY project LIMIT 500`;
export const AGREE_TOP_SQL = `SELECT project, reason_class, COUNT(*) n
FROM sched_diffs INDEXED BY idx_sched_diffs_at WHERE at>=?1 AND at<?2 AND (?3 IS NULL OR project=?3)
GROUP BY project, reason_class ORDER BY project, n DESC, reason_class LIMIT 500`;

const COUNT_KEYS = ["candidates", "ready", "not_ready", "unknown", "in_flight", "compared", "agreed", "idle"];
const COUNT_MAX = 100000;
const DIFFS_MAX = 200;
const VERDICTS_MAX = 1000;
const MODES = new Set(["shadow", "enforce"]);
const READY_VALUES = new Set(["yes", "no", "unknown", "in-flight"]);
const AHEAD_MAX_MS = 600e3;
const TOP_MAX = 5;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const TICKET_RE = /^[1-9][0-9]{0,8}$/;
const CLASS_RE = /^[a-z:+-]{1,80}$/;
const PARTIAL_RE = /^[a-z0-9,:+-]{1,200}$/;
const REASON_MAX = 200;

const obj = (raw) => (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : null);

// The validated tick, or { error } for a 400. Runs before any statement.
function parseTick(raw, nowIso) {
  const b = obj(raw);
  if (!b) return { error: "body must be a JSON object" };
  const project = laneName(b.project);
  if (!project) return { error: "project is required and must match [A-Za-z0-9._-]{1,64}" };
  const at = typeof b.at === "string" ? b.at : "";
  const atMs = Date.parse(at);
  if (!ISO_RE.test(at) || Number.isNaN(atMs)) return { error: "at must be an ISO time (YYYY-MM-DDTHH:MM:SSZ)" };
  if (atMs - Date.parse(nowIso) > AHEAD_MAX_MS) return { error: "at is more than 600 s ahead of the worker clock" };
  if (!MODES.has(b.mode)) return { error: "mode must be shadow or enforce" };
  const c = obj(b.counts);
  if (!c) return { error: "counts must be an object" };
  const counts = [];
  for (const k of COUNT_KEYS) {
    const v = c[k];
    if (!Number.isInteger(v) || v < 0 || v > COUNT_MAX) return { error: `counts.${k} must be an integer 0..${COUNT_MAX}` };
    counts.push(v);
  }
  let partial = null;
  if (b.partial !== undefined && b.partial !== null && b.partial !== "") {
    if (typeof b.partial !== "string" || !PARTIAL_RE.test(b.partial)) return { error: "partial must match [a-z0-9,:+-]{1,200}" };
    partial = b.partial;
  }
  if (!Array.isArray(b.diffs) || b.diffs.length > DIFFS_MAX) return { error: `diffs must be an array of at most ${DIFFS_MAX}` };
  const diffs = [];
  for (const [i, raw2] of b.diffs.entries()) {
    const d = obj(raw2);
    if (!d) return { error: `diffs[${i}] must be an object` };
    const ticket = typeof d.ticket === "string" || typeof d.ticket === "number" ? String(d.ticket) : "";
    if (!TICKET_RE.test(ticket)) return { error: `diffs[${i}].ticket must be an issue number (1..999999999)` };
    if (d.scheduler_says !== "ready" && d.scheduler_says !== "not-ready") return { error: `diffs[${i}].scheduler_says must be ready or not-ready` };
    if (typeof d.lanes_did !== "string" || !CLASS_RE.test(d.lanes_did)) return { error: `diffs[${i}].lanes_did must match [a-z:+-]{1,80}` };
    if (typeof d.reason_class !== "string" || !CLASS_RE.test(d.reason_class)) return { error: `diffs[${i}].reason_class must match [a-z:+-]{1,80}` };
    if (typeof d.reason !== "string" || d.reason.length < 1 || d.reason.length > REASON_MAX) return { error: `diffs[${i}].reason must be 1..${REASON_MAX} chars` };
    diffs.push([ticket, d.scheduler_says, d.lanes_did, d.reason, d.reason_class]);
  }
  let verdicts = null;
  if (b.verdicts !== undefined) {
    if (!Array.isArray(b.verdicts) || b.verdicts.length > VERDICTS_MAX) return { error: `verdicts must be an array of at most ${VERDICTS_MAX}` };
    verdicts = [];
    for (const [i, raw2] of b.verdicts.entries()) {
      const v = obj(raw2);
      if (!v) return { error: `verdicts[${i}] must be an object` };
      const ticket = typeof v.ticket === "string" || typeof v.ticket === "number" ? String(v.ticket) : "";
      if (!TICKET_RE.test(ticket)) return { error: `verdicts[${i}].ticket must be an issue number (1..999999999)` };
      if (!READY_VALUES.has(v.ready)) return { error: `verdicts[${i}].ready must be yes, no, unknown or in-flight` };
      if (typeof v.reason !== "string" || v.reason.length > REASON_MAX) return { error: `verdicts[${i}].reason must be 0..${REASON_MAX} chars` };
      if (v.ready !== "yes" && v.reason.length < 1) return { error: `verdicts[${i}].reason is required unless ready is yes` };
      verdicts.push([ticket, v.ready, v.reason]);
    }
  }
  return { project, at, mode: b.mode, counts, partial, diffs, verdicts };
}

const changes = (r) => Number((r && r.meta && r.meta.changes) || 0);

export const routes = [
  [
    "GET", "/api/scheduler/holds",
    ({ env, url }) => d1Guarded("ticket_holds", async () => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project is required" });
      const { results } = await env.DB.prepare(HOLDS_LATEST_SQL).bind(project).all();
      return json(200, { holds: (results || []).map((r) => ({ ticket: r.ticket, state: r.state, by: r.by, at: r.at })) });
    }),
  ],
  [
    "POST", "/api/scheduler/diffs",
    ({ env, t, body }) => d1Guarded("sched_diffs", async () => {
      const q = parseTick(body, t);
      if (q.error) return json(400, { error: q.error });
      const stmts = [
        env.DB.prepare(TICK_INSERT_SQL).bind(q.project, q.at, q.mode, ...q.counts, q.partial),
        ...q.diffs.map((d) => env.DB.prepare(DIFF_INSERT_SQL).bind(q.project, d[0], d[1], d[2], d[3], d[4], q.at)),
      ];
      if (q.verdicts) stmts.push(env.DB.prepare(READY_INSERT_SQL).bind(q.project, q.at, JSON.stringify(q.verdicts)));
      const res = await env.DB.batch(stmts);
      const diffsWritten = res.slice(1, 1 + q.diffs.length).reduce((s, r) => s + changes(r), 0);
      const out = { ok: true, tick_written: changes(res[0]) ? 1 : 0, diffs_written: diffsWritten };
      if (q.verdicts) out.verdicts_written = changes(res[res.length - 1]);
      return json(200, out);
    }),
  ],
  [
    "GET", "/api/scheduler/ready",
    ({ env, url }) => d1Guarded("sched_ready", async () => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project is required" });
      const { results } = await env.DB.prepare(READY_SQL).bind(project).all();
      const rows = results || [];
      if (rows.length === 0) return json(200, { ok: true, project, at: null, complete: false, verdicts: [] });
      const verdicts = rows.filter((r) => r.ticket !== null && r.ticket !== undefined)
        .map((r) => ({ ticket: r.ticket, ready: r.ready, reason: r.reason }));
      const candidates = Number(rows[0].candidates);
      return json(200, {
        ok: true, project, at: rows[0].at, mode: rows[0].mode, candidates,
        complete: verdicts.length === candidates, verdicts,
      });
    }),
  ],
  [
    "GET", "/api/scheduler/agreement",
    ({ env, url, t }) => d1Guarded("sched_ticks", async () => {
      const w = dayWindow(url.searchParams.get("day"), t);
      if (!w) return json(400, { error: "day must be YYYY-MM-DD, not after today (UTC)" });
      const pRaw = url.searchParams.get("project");
      const project = pRaw === null ? null : laneName(pRaw);
      if (project === "") return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const [ticks, top] = await Promise.all([
        env.DB.prepare(AGREE_TICKS_SQL).bind(w.from, w.to, project).all(),
        env.DB.prepare(AGREE_TOP_SQL).bind(w.from, w.to, project).all(),
      ]);
      const tops = new Map();
      for (const r of top.results || []) {
        const list = tops.get(r.project) || [];
        if (list.length < TOP_MAX) list.push({ reason_class: r.reason_class, n: Number(r.n) });
        tops.set(r.project, list);
      }
      const projects = (ticks.results || []).map((r) => {
        const compared = Number(r.compared || 0), agreed = Number(r.agreed || 0);
        return {
          project: r.project, ticks: Number(r.ticks), compared, agreed, idle: Number(r.idle || 0),
          rate: compared > 0 ? Math.round((agreed / compared) * 1000) / 1000 : null,
          top: tops.get(r.project) || [],
        };
      });
      return json(200, { ok: true, day: w.day, from: w.from, to: w.to, projects });
    }),
  ],
];
