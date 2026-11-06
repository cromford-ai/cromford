// harness-jobs — the hosted Board API's shared parts (BH-8918): the SQL of
// every hot read, the token check, the knobs, the Idempotency-Key store and the
// row-to-contract shape. The routes are ../routes/hosted-board.js (OPEN family)
// and ../routes/hosted-board-admin.js (gated). The SQL constants are exported so
// test/hosted-board-explain.bh-8918.test.js runs EXPLAIN QUERY PLAN on the same
// strings. Each names its index in schema.d/*-bh-8918-hosted-board.sql.
//
// THE CONTRACT is docs/BOARD-API-CONTRACT.md. Doc: docs/HOSTED-BOARD.md.

import { json } from "./http.js";

// ── SQL ─────────────────────────────────────────────────────────────────────
export const TOKEN_SQL = "SELECT project, role, actor_name, revoked_at FROM hosted_board_tokens WHERE token_hash=?1";
export const BOARDS_SQL = "SELECT id, name, key_prefix FROM hosted_board_boards WHERE project=?1 AND archived_at IS NULL ORDER BY id";
export const BOARD_SQL = "SELECT id, name, key_prefix FROM hosted_board_boards WHERE project=?1 AND id=?2 AND archived_at IS NULL";
const LIST_COLS = `id, number, key, title, status, waiting_on, triage_verdict, type, priority, labels, assignee_kind,
  assignee_id, parent_id, depends_on, source, external_id, external_url, comment_count, reporter_id, reporter_name,
  last_activity_at, turn_changed_at, created_at, updated_at`;
export const LIST_SQL = `SELECT ${LIST_COLS} FROM hosted_board_tickets
  WHERE project=?1 AND board_id=?2 AND archived_at IS NULL ORDER BY updated_at DESC, id DESC LIMIT ?3`;
// The page after a cursor row (?3 its updated_at, ?4 its id), in the same order.
export const LIST_AFTER_SQL = `SELECT ${LIST_COLS} FROM hosted_board_tickets
  WHERE project=?1 AND board_id=?2 AND archived_at IS NULL AND (updated_at < ?3 OR (updated_at = ?3 AND id < ?4))
  ORDER BY updated_at DESC, id DESC LIMIT ?5`;
export const CURSOR_SQL = "SELECT updated_at FROM hosted_board_tickets WHERE id=?1 AND project=?2 AND board_id=?3";
export const TICKET_BY_ID_SQL = "SELECT * FROM hosted_board_tickets WHERE id=?1 AND project=?2 AND archived_at IS NULL";
export const TICKET_BY_KEY_SQL = "SELECT * FROM hosted_board_tickets WHERE project=?1 AND key=?2 AND archived_at IS NULL";
export const DEPS_SQL = "SELECT id, key, status FROM hosted_board_tickets WHERE project=?1 AND id IN (SELECT value FROM json_each(?2))";
export const CHILDREN_SQL = `SELECT parent_id, id, key, status FROM hosted_board_tickets
  WHERE project=?1 AND parent_id IN (SELECT value FROM json_each(?2)) AND archived_at IS NULL ORDER BY number`;
export const COMMENTS_SQL = `SELECT id, author_id, author_name, body, is_internal, created_at FROM hosted_board_comments
  WHERE project=?1 AND ticket_id=?2 AND archived_at IS NULL ORDER BY created_at, id`;
export const MAX_NUMBER_SQL = "SELECT COALESCE(MAX(number), 0) AS n FROM hosted_board_tickets WHERE project=?1 AND board_id=?2";
export const IDEM_READ_SQL = "SELECT request_hash, status, response_body FROM hosted_board_idem WHERE project=?1 AND idem_key=?2";
export const IDEM_INSERT_SQL = `INSERT INTO hosted_board_idem (project, idem_key, method, path, request_hash, status, response_body, created_at)
  VALUES (?1,?2,?3,?4,?5,?6,?7,?8)`;
export const EVENT_INSERT_SQL = "INSERT INTO hosted_board_events (project, ticket_id, kind, actor, payload, at) VALUES (?1,?2,?3,?4,?5,?6)";

export const PROJECT_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;
export const STATUSES = new Set(["todo", "in_progress", "review", "done", "closed"]);
export const TURNS = new Set(["team", "client"]);
export const ASSIGNEE_KINDS = new Set(["person", "agent"]);

// ── knobs (BH-7945) ─────────────────────────────────────────────────────────
// Each fallback is the seed of the settings row it names
// (schema.d/202611040340-bh-8918-hosted-board.sql).
export const KNOB_DEFAULTS = {
  "hosted_board.list_page_max": 500,          // row hosted_board.list_page_max
  "hosted_board.title_max_chars": 300,        // row hosted_board.title_max_chars
  "hosted_board.description_max_chars": 20000, // row hosted_board.description_max_chars
  "hosted_board.comment_max_chars": 5000,     // row hosted_board.comment_max_chars
  "hosted_board.depends_on_max": 50,          // row hosted_board.depends_on_max
  "hosted_board.create_retries": 3,           // row hosted_board.create_retries
};
const KNOB_KEYS = Object.keys(KNOB_DEFAULTS);
const KNOBS_SQL = `SELECT key, value FROM settings WHERE key IN (${KNOB_KEYS.map((_, i) => `?${i + 1}`).join(",")})`;

// One read of the six rows. A value that is not an integer >= 1 is the
// fallback. Each handler calls this once, so it is one statement per request.
export async function knobs(env) {
  const rows = (await env.DB.prepare(KNOBS_SQL).bind(...KNOB_KEYS).all()).results || [];
  const out = { ...KNOB_DEFAULTS };
  for (const r of rows) {
    const v = String(r.value ?? "").trim();
    if (/^\d+$/.test(v) && Number(v) >= 1) out[r.key] = Number(v);
  }
  return {
    listPageMax: out["hosted_board.list_page_max"],
    titleMax: out["hosted_board.title_max_chars"],
    descriptionMax: out["hosted_board.description_max_chars"],
    commentMax: out["hosted_board.comment_max_chars"],
    dependsOnMax: out["hosted_board.depends_on_max"],
    createRetries: out["hosted_board.create_retries"],
  };
}

// ── hashing ─────────────────────────────────────────────────────────────────
export async function sha256Hex(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ── auth ────────────────────────────────────────────────────────────────────
// -> { role, actorId, actorName } or null. The bearer is matched exactly: no
// trim, no case fold (D17). HARNESS_SECRET is refused BEFORE any read, so a row
// that holds its hash opens nothing. Allowed: a live system token on its own
// project, or a live operator token (project '*') on any project.
export async function authHostedBoard(req, env, project) {
  const m = /^Bearer (.+)$/.exec(req.headers.get("authorization") || "");
  if (!m) return null;
  const token = m[1];
  if (typeof env.HARNESS_SECRET === "string" && env.HARNESS_SECRET !== "" && token === env.HARNESS_SECRET) return null;
  const row = await env.DB.prepare(TOKEN_SQL).bind(await sha256Hex(token)).first();
  if (!row || row.revoked_at !== null) return null;
  const ok = (row.role === "system" && row.project === project) || (row.role === "operator" && row.project === "*");
  if (!ok) return null;
  return { role: row.role, actorId: row.role, actorName: row.actor_name };
}

export const unauthorized = () => json(401, { error: "unauthorized" });

// ── Idempotency-Key ─────────────────────────────────────────────────────────
// idemBegin -> { replay: Response } when the key answered before with the same
// request, { conflict: Response } when it answered a different one, or
// { hash } when the caller must write (idemStatement first in its batch).
export async function idemBegin(env, project, key, method, path, rawBody) {
  const hash = await sha256Hex(`${method}\n${path}\n${rawBody}`);
  const row = await env.DB.prepare(IDEM_READ_SQL).bind(project, key).first();
  if (!row) return { hash };
  if (row.request_hash !== hash) return { conflict: json(409, { error: "idempotency_key_reused" }) };
  return { replay: storedResponse(row) };
}

function storedResponse(row) {
  return new Response(row.response_body, { status: Number(row.status), headers: { "content-type": "application/json" } });
}

export function idemStatement(env, project, key, method, path, hash, status, body, t) {
  return env.DB.prepare(IDEM_INSERT_SQL).bind(project, key, method, path, hash, status, JSON.stringify(body), t);
}

// A batch whose idem row lost the race to a twin: re-read and replay (same
// request) or 409 (another request). null when the error is not that.
export async function idemRaceAnswer(env, project, key, hash, err) {
  if (!key || !/UNIQUE constraint failed: hosted_board_idem/.test(String(err && err.message))) return null;
  const row = await env.DB.prepare(IDEM_READ_SQL).bind(project, key).first();
  if (!row) return null;
  if (row.request_hash !== hash) return json(409, { error: "idempotency_key_reused" });
  return storedResponse(row);
}

// ── shapes ──────────────────────────────────────────────────────────────────
function parseArray(text) {
  try {
    const v = JSON.parse(text);
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

// The ids every row's dependsOn and the row ids, for the two batch reads.
export function depIdsOf(rows) {
  const ids = new Set();
  for (const r of rows) for (const d of parseArray(r.depends_on)) ids.add(String(d));
  return [...ids];
}

// Reads the dependsOn targets and the children of `rows` in ONE batch (two
// statements), never per row. -> { deps: Map id->row, children: Map parent->[rows] }
export async function relations(env, project, rows) {
  const depIds = depIdsOf(rows);
  const parentIds = rows.map((r) => r.id);
  if (rows.length === 0) return { deps: new Map(), children: new Map() };
  const [d, c] = await env.DB.batch([
    env.DB.prepare(DEPS_SQL).bind(project, JSON.stringify(depIds)),
    env.DB.prepare(CHILDREN_SQL).bind(project, JSON.stringify(parentIds)),
  ]);
  const deps = new Map((d.results || []).map((r) => [r.id, r]));
  const children = new Map();
  for (const r of c.results || []) {
    if (!children.has(r.parent_id)) children.set(r.parent_id, []);
    children.get(r.parent_id).push({ id: r.id, key: r.key, status: r.status });
  }
  return { deps, children };
}

// The contract shape of one ticket row. `full` adds the description. blocked is
// true when any dependsOn entry is not `done` or no longer resolves.
export function ticketOut(row, rel, full = false) {
  const dependsOn = parseArray(row.depends_on).map((id) => {
    const d = rel.deps.get(String(id));
    return d ? { id: d.id, key: d.key, status: d.status } : { id: String(id), key: null, status: null };
  });
  const out = {
    id: row.id,
    key: row.key,
    number: Number(row.number),
    title: row.title,
  };
  if (full) out.description = row.description ?? null;
  Object.assign(out, {
    status: row.status,
    waitingOn: row.waiting_on,
    triageVerdict: row.triage_verdict === "" || row.triage_verdict === undefined ? null : row.triage_verdict,
    commentCount: Number(row.comment_count),
    priority: row.priority,
    type: row.type,
    labels: parseArray(row.labels),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    lastActivityAt: row.last_activity_at,
    turnChangedAt: row.turn_changed_at ?? null,
    reporter: { userId: row.reporter_id ?? null, name: row.reporter_name ?? null },
    assignee: row.assignee_kind ? { kind: row.assignee_kind, id: row.assignee_id } : null,
    source: row.source,
    externalId: row.external_id ?? null,
    externalUrl: row.external_url ?? null,
    parentId: row.parent_id === "" || row.parent_id === undefined ? null : row.parent_id,
    dependsOn,
    children: rel.children.get(row.id) || [],
    blocked: dependsOn.some((d) => d.status !== "done"),
  });
  return out;
}

export function commentOut(row) {
  return {
    id: row.id,
    author: { userId: row.author_id, name: row.author_name },
    body: row.body,
    createdAt: row.created_at,
    isInternal: Number(row.is_internal) === 1,
  };
}
