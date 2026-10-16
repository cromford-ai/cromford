// ticket-edges routes — dependency edges and HOLD/RESUME comments as rows
// (BH-6977, BH-6547.1). Contract: docs/notes/2026-10-15-BH-6977-ticket-edges.md.
// Shell client: bin/lib/ticket-edges.sh. Tables and settings rows:
// worker/jobs/schema.d/202610152135-bh-6977-ticket-edges.sql. Nothing reads
// these rows for a dispatch decision yet.
//
// POST /api/ticket-edges {project, parent, child, kind, source, planned_files?}
//   ONE upsert on (project, parent, child). source=dep-verify sets kind,
//   source, verified_at and at. Any other source sets at (and planned_files
//   when sent), and sets kind and source only while verified_at is NULL, so a
//   plan re-run does not undo a checked verdict. 200 {ok, id, kind, verified_at}.
// GET /api/ticket-edges?project=&parent=|child=   {edges:[...]}, ORDER BY id, LIMIT 500.
// POST /api/ticket-holds {project, ticket, state, by, at, comment_id}
//   ONE upsert on (project, ticket, comment_id): an edited comment changes its
//   own row. 200 {ok, id, state}.
// GET /api/ticket-holds?project=&ticket=   {holds:[...]}, newest first, LIMIT 200.

import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";

const EDGE_COLS = "id, project, parent, child, kind, planned_files, source, verified_at, at";
const HOLD_COLS = "id, project, ticket, state, by, at, comment_id";

// Exported so the tests explain the exact statements.
export const EDGE_PUT_SQL = `INSERT INTO ticket_edges (project,parent,child,kind,planned_files,source,verified_at,at)
VALUES (?1,?2,?3,?4,?5,?6,NULL,?7)
ON CONFLICT(project,parent,child) DO UPDATE SET
  at = excluded.at,
  planned_files = COALESCE(excluded.planned_files, ticket_edges.planned_files),
  kind = CASE WHEN ticket_edges.verified_at IS NULL THEN excluded.kind ELSE ticket_edges.kind END,
  source = CASE WHEN ticket_edges.verified_at IS NULL THEN excluded.source ELSE ticket_edges.source END
RETURNING id, kind, verified_at`;
export const EDGE_VERDICT_SQL = `INSERT INTO ticket_edges (project,parent,child,kind,planned_files,source,verified_at,at)
VALUES (?1,?2,?3,?4,?5,'dep-verify',?6,?6)
ON CONFLICT(project,parent,child) DO UPDATE SET
  at = excluded.at,
  planned_files = COALESCE(excluded.planned_files, ticket_edges.planned_files),
  kind = excluded.kind, source = 'dep-verify', verified_at = excluded.verified_at
RETURNING id, kind, verified_at`;
export const EDGES_BY_PARENT_SQL = `SELECT ${EDGE_COLS} FROM ticket_edges WHERE project=?1 AND parent=?2 ORDER BY id LIMIT 500`;
export const EDGES_BY_CHILD_SQL = `SELECT ${EDGE_COLS} FROM ticket_edges WHERE project=?1 AND child=?2 ORDER BY id LIMIT 500`;
export const EDGES_BY_PROJECT_SQL = `SELECT ${EDGE_COLS} FROM ticket_edges INDEXED BY ux_ticket_edges_pc WHERE project=?1 ORDER BY id LIMIT 500`;
export const HOLD_PUT_SQL = `INSERT INTO ticket_holds (project,ticket,state,by,at,comment_id) VALUES (?1,?2,?3,?4,?5,?6)
ON CONFLICT(project,ticket,comment_id) DO UPDATE SET state = excluded.state, by = excluded.by, at = excluded.at
RETURNING id, state`;
export const HOLDS_SQL = `SELECT ${HOLD_COLS} FROM ticket_holds WHERE project=?1 AND ticket=?2 ORDER BY at DESC, id DESC LIMIT 200`;

const NUM_RE = /^[1-9][0-9]{0,8}$/;
const COMMENT_ID_RE = /^[1-9][0-9]{0,19}$/;
const LOGIN_RE = /^[A-Za-z0-9_.[\]-]{1,64}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/;
const KINDS = ["hard", "soft"];
const SOURCES = ["planner", "decompose", "dep-verify", "human"];
const FILES_MAX = 500;
const FILE_LEN_MAX = 300;

const obj = (raw) => (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {});
// A string or a number, as its string, else "".
const str = (v) => (typeof v === "string" || typeof v === "number" ? String(v).trim() : "");
const num = (v) => (NUM_RE.test(str(v)) ? str(v) : "");

// The validated edge, or { error } for a 400. Runs before any statement.
function parseEdge(raw) {
  const b = obj(raw);
  const project = laneName(b.project);
  if (!project) return { error: "project is required and must match [A-Za-z0-9._-]{1,64}" };
  const parent = num(b.parent), child = num(b.child);
  if (!parent || !child) return { error: "parent and child must be issue numbers (1..999999999)" };
  if (parent === child) return { error: "parent and child must differ" };
  if (!KINDS.includes(b.kind)) return { error: "kind must be hard or soft" };
  if (!SOURCES.includes(b.source)) return { error: `source must be one of ${SOURCES.join(", ")}` };
  let files = null;
  if (b.planned_files !== undefined && b.planned_files !== null) {
    const f = b.planned_files;
    if (!Array.isArray(f) || f.length > FILES_MAX
      || !f.every((p) => typeof p === "string" && p.length > 0 && p.length <= FILE_LEN_MAX)) {
      return { error: `planned_files must be an array of at most ${FILES_MAX} non-empty strings of at most ${FILE_LEN_MAX} chars` };
    }
    files = JSON.stringify(f);
  }
  return { project, parent, child, kind: b.kind, source: b.source, files };
}

function parseHold(raw) {
  const b = obj(raw);
  const project = laneName(b.project);
  if (!project) return { error: "project is required and must match [A-Za-z0-9._-]{1,64}" };
  const ticket = num(b.ticket);
  if (!ticket) return { error: "ticket must be an issue number (1..999999999)" };
  if (b.state !== "hold" && b.state !== "resume") return { error: "state must be hold or resume" };
  const by = str(b.by);
  if (!LOGIN_RE.test(by)) return { error: "by must match [A-Za-z0-9_.[]-]{1,64}" };
  const at = str(b.at);
  if (!ISO_RE.test(at) || Number.isNaN(Date.parse(at))) return { error: "at must be an ISO time (YYYY-MM-DDTHH:MM:SSZ)" };
  const commentId = str(b.comment_id);
  if (!COMMENT_ID_RE.test(commentId)) return { error: "comment_id must be a GitHub comment id" };
  return { project, ticket, state: b.state, by, at, commentId };
}

// planned_files is stored as JSON text and answered as the array it was.
function edgeOut(r) {
  let files = null;
  if (r.planned_files !== null && r.planned_files !== undefined) {
    try { files = JSON.parse(r.planned_files); } catch { files = null; }
  }
  return { ...r, planned_files: files };
}

export const routes = [
  [
    "POST", "/api/ticket-edges",
    ({ env, t, body }) => d1Guarded("ticket_edges", async () => {
      const q = parseEdge(body);
      if (q.error) return json(400, { error: q.error });
      const row = q.source === "dep-verify"
        ? await env.DB.prepare(EDGE_VERDICT_SQL).bind(q.project, q.parent, q.child, q.kind, q.files, t).first()
        : await env.DB.prepare(EDGE_PUT_SQL).bind(q.project, q.parent, q.child, q.kind, q.files, q.source, t).first();
      if (!row) return json(503, { error: "ticket_edges write returned no row" });
      return json(200, { ok: true, id: Number(row.id), kind: row.kind, verified_at: row.verified_at ?? null });
    }),
  ],
  [
    "GET", "/api/ticket-edges",
    ({ env, url }) => d1Guarded("ticket_edges", async () => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project is required" });
      const pRaw = url.searchParams.get("parent"), cRaw = url.searchParams.get("child");
      if ((pRaw !== null && !num(pRaw)) || (cRaw !== null && !num(cRaw))) {
        return json(400, { error: "parent and child must be issue numbers" });
      }
      if (pRaw !== null && cRaw !== null) return json(400, { error: "send parent or child, not both" });
      const stmt = pRaw !== null ? env.DB.prepare(EDGES_BY_PARENT_SQL).bind(project, num(pRaw))
        : cRaw !== null ? env.DB.prepare(EDGES_BY_CHILD_SQL).bind(project, num(cRaw))
          : env.DB.prepare(EDGES_BY_PROJECT_SQL).bind(project);
      const { results } = await stmt.all();
      return json(200, { edges: (results || []).map(edgeOut) });
    }),
  ],
  [
    "POST", "/api/ticket-holds",
    ({ env, body }) => d1Guarded("ticket_holds", async () => {
      const q = parseHold(body);
      if (q.error) return json(400, { error: q.error });
      const row = await env.DB.prepare(HOLD_PUT_SQL).bind(q.project, q.ticket, q.state, q.by, q.at, q.commentId).first();
      if (!row) return json(503, { error: "ticket_holds write returned no row" });
      return json(200, { ok: true, id: Number(row.id), state: row.state });
    }),
  ],
  [
    "GET", "/api/ticket-holds",
    ({ env, url }) => d1Guarded("ticket_holds", async () => {
      const project = laneName(url.searchParams.get("project"));
      const ticket = num(url.searchParams.get("ticket"));
      if (!project || !ticket) return json(400, { error: "project and ticket are required" });
      const { results } = await env.DB.prepare(HOLDS_SQL).bind(project, ticket).all();
      return json(200, { holds: results || [] });
    }),
  ],
];
