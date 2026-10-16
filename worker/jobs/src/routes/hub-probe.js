// hub-probe routes — BH-3448 (BH-3434.1): the hub-probe request ledger over
// hub_probe_requests (worker/jobs/schema.sql). The shapes are the BH-3447
// contract, which the bin/lib/jobs/hub-probe.sh verbs already send and read:
//
//   POST /api/hub-probe            {project, ticket_key, probe, args, requested_by}
//                                  -> {created: boolean, row: {...}}
//                                  INSERT ... ON CONFLICT DO NOTHING on the key
//                                  (project, ticket_key, probe, args_hash). A key
//                                  is requested once ever: a re-request of a
//                                  finished row answers the stored row untouched.
//   POST /api/hub-probe/claim      {claimed_by, n}            -> {rows: [...]}
//                                  at most n (1..100, never clamped) pending rows,
//                                  oldest first, moved to claimed in ONE
//                                  UPDATE ... RETURNING, so two claims never
//                                  return the same row.
//   POST /api/hub-probe/result     {id, result: pass|fail|rejected|pending,
//                                   http_status, output, note} -> {ok: true}
//                                  only from claimed, otherwise 409 (404 for an
//                                  unknown id). `pending` needs a note and puts
//                                  the row back with the claim cleared, so a
//                                  deferred row does not count against today's
//                                  claims. `status` is read when `result` is absent.
//   POST /api/hub-probe/commented  {id}                       -> {ok: true}
//                                  stamps commented_at only where it is NULL, and
//                                  answers ok either way.
//   GET  /api/hub-probe?project=&ticket=   -> {rows: [...] (at most 200), truncated}
//
// args_hash IS COMPUTED HERE AND ONLY HERE: sha256 hex of the canonical args
// JSON (object keys sorted at every depth, array order kept). An args_hash in
// the body is ignored. output is cut to 4096 UTF-8 bytes here, on a character
// boundary, not by the caller.
//
// There is no CREATED_TABLES entry: a D1 the schema apply never reached
// answers 503 "hub_probe_requests schema not applied" through d1Guarded.
import { d1Guarded, json } from "../lib/http.js";
import { laneName, str } from "../lib/core.js";

const TABLE = "hub_probe_requests";
export const HP_ARGS_MAX = 2048;
export const HP_OUTPUT_MAX_BYTES = 4096;
export const HP_LIST_MAX = 200;
export const HP_CLAIM_MAX = 100;
const TICKET_RE = /^[A-Za-z0-9._-]{1,64}$/;
export const PROBE_RE = /^[a-z][a-z0-9-]{0,31}$/;
const TERMINAL = new Set(["pass", "fail", "rejected"]);

export function canonical(v) {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (v && typeof v === "object") {
    return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
  }
  return JSON.stringify(v);
}

async function sha256Hex(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// The longest prefix of `s` that is at most `max` UTF-8 bytes and ends on a
// character boundary: back off any continuation bytes (10xxxxxx) at the cut.
export function utf8Cut(s, max) {
  const bytes = new TextEncoder().encode(s);
  if (bytes.length <= max) return s;
  let end = max;
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
  return new TextDecoder().decode(bytes.subarray(0, end));
}

// A positive integer id, or null. A JSON number only: "7" is not an id.
function idOf(v) {
  return Number.isInteger(v) && v > 0 ? v : null;
}

function ticketOf(v) {
  const s = typeof v === "string" ? v : "";
  return TICKET_RE.test(s) ? s : "";
}

const BAD_PROJECT = "project must match [A-Za-z0-9._-]{1,64}";
const BAD_TICKET = "ticket_key must match [A-Za-z0-9._-]{1,64}";
const BAD_PROBE = "probe must match [a-z][a-z0-9-]{0,31}";

// 404 when the id is unknown, else 409 with the status the row is actually in.
async function lostCas(env, id) {
  // sql-ident-ok: TABLE is a module constant
  const status = await env.DB.prepare(`SELECT status FROM ${TABLE} WHERE id=?1`).bind(id).first("status");
  if (status === null) return json(404, { error: `no hub_probe_requests row ${id}` });
  return json(409, { error: `row ${id} is ${status}, not claimed`, status });
}

export const routes = [
  [
    "POST", "/api/hub-probe",
    async ({ env, t, body }) => d1Guarded(TABLE, async () => {
      const b = body && typeof body === "object" ? body : {};
      const project = laneName(b.project);
      if (!project) return json(400, { error: BAD_PROJECT });
      const ticket = ticketOf(b.ticket_key);
      if (!ticket) return json(400, { error: BAD_TICKET });
      const probe = typeof b.probe === "string" && PROBE_RE.test(b.probe) ? b.probe : "";
      if (!probe) return json(400, { error: BAD_PROBE });
      if (b.args === undefined) return json(400, { error: "args is required" });
      const argsJson = canonical(b.args);
      if (argsJson.length > HP_ARGS_MAX) return json(400, { error: `args must be at most ${HP_ARGS_MAX} characters as JSON` });
      const hash = await sha256Hex(argsJson);
      // sql-ident-ok: TABLE is a module constant
      const res = await env.DB.prepare(
        `INSERT INTO ${TABLE} (project, ticket_key, probe, args_json, args_hash, requested_by, requested_at) `
        + "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) "
        + "ON CONFLICT(project, ticket_key, probe, args_hash) DO NOTHING"
      ).bind(project, ticket, probe, argsJson, hash, str(b.requested_by, 64), t).run();
      // sql-ident-ok: TABLE is a module constant
      const row = await env.DB.prepare(
        `SELECT * FROM ${TABLE} WHERE project=?1 AND ticket_key=?2 AND probe=?3 AND args_hash=?4`
      ).bind(project, ticket, probe, hash).first();
      if (!row) return json(503, { error: "hub_probe_requests row not readable after write" });
      return json(200, { created: res.meta.changes === 1, row });
    }),
  ],

  [
    "POST", "/api/hub-probe/claim",
    async ({ env, t, body }) => d1Guarded(TABLE, async () => {
      const b = body && typeof body === "object" ? body : {};
      const by = str(b.claimed_by, 64);
      if (!by) return json(400, { error: "claimed_by is required" });
      const n = b.n;
      if (!Number.isInteger(n) || n < 1 || n > HP_CLAIM_MAX) {
        return json(400, { error: `n must be an integer from 1 to ${HP_CLAIM_MAX}` });
      }
      // sql-ident-ok: TABLE is a module constant
      const rows = (await env.DB.prepare(
        `UPDATE ${TABLE} SET status='claimed', claimed_by=?1, claimed_at=?2 `
        + `WHERE status='pending' AND id IN (SELECT id FROM ${TABLE} WHERE status='pending' ORDER BY requested_at, id LIMIT ?3) `
        + "RETURNING *"
      ).bind(by, t, n).all()).results || [];
      rows.sort((x, y) => (x.requested_at < y.requested_at ? -1 : x.requested_at > y.requested_at ? 1 : x.id - y.id));
      return json(200, { rows });
    }),
  ],

  [
    "POST", "/api/hub-probe/result",
    async ({ env, t, body }) => d1Guarded(TABLE, async () => {
      const b = body && typeof body === "object" ? body : {};
      const id = idOf(b.id);
      if (!id) return json(400, { error: "id must be a positive integer" });
      const outcome = b.result ?? b.status;
      if (!TERMINAL.has(outcome) && outcome !== "pending") {
        return json(400, { error: "result must be pass, fail, rejected or pending" });
      }
      const note = str(b.note, 500);
      let res;
      if (outcome === "pending") {
        if (!note) return json(400, { error: "a pending result needs a note" });
        // sql-ident-ok: TABLE is a module constant
        res = await env.DB.prepare(
          `UPDATE ${TABLE} SET status='pending', claimed_by=NULL, claimed_at=NULL, note=?1 WHERE id=?2 AND status='claimed'`
        ).bind(note, id).run();
      } else {
        const hs = b.http_status ?? null;
        if (hs !== null && !Number.isInteger(hs)) return json(400, { error: "http_status must be an integer or null" });
        const output = utf8Cut(b.output === undefined || b.output === null ? "" : String(b.output), HP_OUTPUT_MAX_BYTES);
        // sql-ident-ok: TABLE is a module constant
        res = await env.DB.prepare(
          `UPDATE ${TABLE} SET status=?1, http_status=?2, output=?3, finished_at=?4, note=COALESCE(?5, note) `
          + "WHERE id=?6 AND status='claimed'"
        ).bind(outcome, hs, output, t, note, id).run();
      }
      if (res.meta.changes !== 1) return lostCas(env, id);
      return json(200, { ok: true });
    }),
  ],

  [
    "POST", "/api/hub-probe/commented",
    async ({ env, t, body }) => d1Guarded(TABLE, async () => {
      const b = body && typeof body === "object" ? body : {};
      const id = idOf(b.id);
      if (!id) return json(400, { error: "id must be a positive integer" });
      // sql-ident-ok: TABLE is a module constant
      const res = await env.DB.prepare(
        `UPDATE ${TABLE} SET commented_at=?1 WHERE id=?2 AND commented_at IS NULL`
      ).bind(t, id).run();
      if (res.meta.changes !== 1) {
        // sql-ident-ok: TABLE is a module constant
        const seen = await env.DB.prepare(`SELECT id FROM ${TABLE} WHERE id=?1`).bind(id).first("id");
        if (seen === null) return json(404, { error: `no hub_probe_requests row ${id}` });
      }
      return json(200, { ok: true });
    }),
  ],

  [
    "GET", "/api/hub-probe",
    async ({ env, url }) => d1Guarded(TABLE, async () => {
      const q = url.searchParams;
      const project = laneName(q.get("project"));
      if (!project) return json(400, { error: BAD_PROJECT });
      const ticket = ticketOf(q.get("ticket"));
      if (!ticket) return json(400, { error: "ticket must match [A-Za-z0-9._-]{1,64}" });
      // sql-ident-ok: TABLE is a module constant
      const rows = (await env.DB.prepare(
        `SELECT * FROM ${TABLE} WHERE project=?1 AND ticket_key=?2 ORDER BY requested_at, id LIMIT ?3`
      ).bind(project, ticket, HP_LIST_MAX + 1).all()).results || [];
      return json(200, { rows: rows.slice(0, HP_LIST_MAX), truncated: rows.length > HP_LIST_MAX });
    }),
  ],
];
