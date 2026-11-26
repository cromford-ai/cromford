// owner approvals routes — BH-9262 C1. The owner-approval inbox
// (schema.d/202611252112-bh-9262-owner-approvals.sql). The hub holds neither
// owner proof (lib/owner-proof.js), so when bin/archie.sh delegate or
// bin/box-request.sh meets a proof-required 403 it files the request here with
// the fleet bearer. A row grants nothing: the owner runs the action from the
// console (OwnerApprovalsPanel on /machines) through the existing proved
// route, and then decides the row. The worker never replays a stored payload.
//
// POST /api/owner-approvals   body {kind, payload, actor, via, dedupe_key}
//   kind box_command: payload holds only BOX_KEYS, each a string or an
//     integer; type is an OWNER_ONLY type and target a string.
//   kind archie_delegation: payload is exactly {class, min_streak}; class as
//     routes/archie-autonomy.js reads it, min_streak a positive integer.
//   Payload JSON over owner_approvals.payload_max_bytes → 400. A bad field → 400.
//   INSERT OR IGNORE on UNIQUE (kind, dedupe_key) → 201 {id, approval,
//   deduped:false} for a new row, 200 {..., deduped:true} for an existing one.
// GET /api/owner-approvals[?status=pending|expired|approved|declined|all]
//   Default pending: pending rows younger than owner_approvals.pending_ttl_h,
//   newest first. At most owner_approvals.list_limit rows → 200 {approvals,
//   truncated, as_of}. A pending row past the TTL reads as status `expired`
//   (computed here, never written).
// POST /api/owner-approvals/:id/decide   body {decision, result_ref?}
//   Always needs ownerProof (the human token or the Pages box-ops proof); it
//   does not read owner_proof_mode, because no legacy caller exists. No proof
//   → 403 {error:"human_proof_required"}. decision approved | declined,
//   result_ref a string ≤ 200 or null, else 400. Unknown id → 404. A
//   compare-and-set on status='pending' inside the TTL: 200 {ok, approval};
//   a decided row → 409 already_decided; a row past the TTL → 409 expired.
//   decided_by is the Access identity (box-ops) or `human-token`.

import { json, d1Guarded } from "../lib/http.js";
import { isoPlusSeconds } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";
import { OWNER_ONLY } from "../lib/box-command-types.js";
import { normActor } from "../lib/box-command-args.js";
import { ownerProof } from "../lib/owner-proof.js";
import { classOf } from "./archie-autonomy.js";

// Fallbacks of the settings rows seeded in
// schema.d/202611252112-bh-9262-owner-approvals.sql. The row wins when it parses.
const PENDING_TTL_H = 72;        // owner_approvals.pending_ttl_h
const LIST_LIMIT = 50;           // owner_approvals.list_limit
const PAYLOAD_MAX_BYTES = 4096;  // owner_approvals.payload_max_bytes
// result_ref is input validation of one text cell, not a limit on work, so it
// is not a settings row (as in suite-quarantine.js). The payload's values are
// bounded as a whole by owner_approvals.payload_max_bytes.
const REF_MAX = 200;
const KEY_RE = /^[A-Za-z0-9._:@-]{1,200}$/;
const VIA_RE = /^[a-z]{1,16}:[A-Za-z0-9._@-]{0,64}$/;
const BOX_KEYS = new Set(["box", "type", "target", "account", "project", "vcpus", "mem_gb", "disk_gb", "cap", "reason"]);
const KINDS = new Set(["box_command", "archie_delegation"]);
const LISTS = new Set(["pending", "expired", "approved", "declined", "all"]);

const COLS = "id, kind, dedupe_key, payload, actor, via, status, created_at, decided_at, decided_by, result_ref";
export const SQL = {
  insert: `INSERT OR IGNORE INTO owner_approvals (kind, dedupe_key, payload, actor, via, status, created_at)
           VALUES (?1,?2,?3,?4,?5,'pending',?6)`,
  byKey: `SELECT ${COLS} FROM owner_approvals WHERE kind=?1 AND dedupe_key=?2`,
  byId: `SELECT ${COLS} FROM owner_approvals WHERE id=?1`,
  listPending: `SELECT ${COLS} FROM owner_approvals WHERE status='pending' AND created_at >= ?1
                ORDER BY created_at DESC, id DESC LIMIT ?2`,
  listExpired: `SELECT ${COLS} FROM owner_approvals WHERE status='pending' AND created_at < ?1
                ORDER BY created_at DESC, id DESC LIMIT ?2`,
  listStatus: `SELECT ${COLS} FROM owner_approvals WHERE status=?1
               ORDER BY created_at DESC, id DESC LIMIT ?2`,
  listAll: `SELECT ${COLS} FROM owner_approvals ORDER BY created_at DESC, id DESC LIMIT ?1`,
  decide: `UPDATE owner_approvals SET status=?1, decided_at=?2, decided_by=?3, result_ref=?4
           WHERE id=?5 AND status='pending' AND created_at >= ?6`,
};

const bad = (error) => json(400, { error });
const changes = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isInt = (v) => typeof v === "number" && Number.isSafeInteger(v);

async function knobs(env) {
  const { byKey } = await settingsRows(env);
  return {
    ttlH: intSetting(byKey, "owner_approvals.pending_ttl_h", PENDING_TTL_H, 1, 8760),
    limit: intSetting(byKey, "owner_approvals.list_limit", LIST_LIMIT, 1, 1000),
    maxBytes: intSetting(byKey, "owner_approvals.payload_max_bytes", PAYLOAD_MAX_BYTES, 64, 65536),
  };
}

// → the payload to store, or {error}.
function checkPayload(kind, p) {
  if (!isObj(p)) return { error: "payload must be an object" };
  if (kind === "archie_delegation") {
    const keys = Object.keys(p);
    if (keys.length !== 2 || !("class" in p) || !("min_streak" in p)) return { error: "payload must be exactly {class, min_streak}" };
    const c = classOf(p.class);
    if (!c) return { error: "payload.class must match [a-z][a-z0-9-]{1,40}" };
    if (!isInt(p.min_streak) || p.min_streak <= 0) return { error: "payload.min_streak must be a positive integer" };
    return { payload: { class: c, min_streak: p.min_streak } };
  }
  for (const [k, v] of Object.entries(p)) {
    if (!BOX_KEYS.has(k)) return { error: `payload key ${k} is not allowed (only ${[...BOX_KEYS].join(", ")})` };
    if (!(isInt(v) || typeof v === "string")) return { error: `payload.${k} must be a string or an integer` };
  }
  if (!OWNER_ONLY.has(p.type)) return { error: `payload.type must be one of ${[...OWNER_ONLY].join(", ")}` };
  if (typeof p.target !== "string" || !p.target) return { error: "payload.target is required" };
  return { payload: p };
}

function shape(row, cutoff) {
  if (!row) return row;
  let payload = row.payload;
  try { payload = JSON.parse(row.payload); } catch { /* the raw string, never a failed read */ }
  const status = row.status === "pending" && row.created_at < cutoff ? "expired" : row.status;
  return { ...row, payload, status };
}

export const routes = [
  ["POST", "/api/owner-approvals", ({ env, t, body }) => d1Guarded("owner_approvals", async () => {
    const b = isObj(body) ? body : {};
    if (!KINDS.has(b.kind)) return bad(`kind must be one of ${[...KINDS].join(", ")}`);
    if (typeof b.dedupe_key !== "string" || !KEY_RE.test(b.dedupe_key)) return bad("dedupe_key must match [A-Za-z0-9._:@-]{1,200}");
    const actor = b.actor === undefined || b.actor === null || b.actor === "" ? null : normActor(b.actor);
    if (actor === "") return bad("actor must match [a-z0-9._@-]{1,96}");
    const via = b.via === undefined || b.via === null || b.via === "" ? null : b.via;
    if (via !== null && !(typeof via === "string" && VIA_RE.test(via))) return bad("via must be <transport>:<user>");
    const p = checkPayload(b.kind, b.payload);
    if (p.error) return bad(p.error);
    const k = await knobs(env);
    const text = JSON.stringify(p.payload);
    if (new TextEncoder().encode(text).length > k.maxBytes) return bad(`payload is over ${k.maxBytes} bytes`);
    const ins = await env.DB.prepare(SQL.insert).bind(b.kind, b.dedupe_key, text, actor, via, t).run();
    const row = await env.DB.prepare(SQL.byKey).bind(b.kind, b.dedupe_key).first();
    if (!row) return json(503, { error: "owner_approvals unavailable", detail: "the row was not readable after its insert" });
    const deduped = changes(ins) === 0;
    const cutoff = isoPlusSeconds(t, -k.ttlH * 3600);
    return json(deduped ? 200 : 201, { id: row.id, approval: shape(row, cutoff), deduped });
  })],

  ["GET", "/api/owner-approvals", ({ env, t, url }) => d1Guarded("owner_approvals", async () => {
    const status = url.searchParams.get("status") || "pending";
    if (!LISTS.has(status)) return bad(`status must be one of ${[...LISTS].join(", ")}`);
    const k = await knobs(env);
    const cutoff = isoPlusSeconds(t, -k.ttlH * 3600);
    // One row past the cap tells a full list from a cut one.
    const n = k.limit + 1;
    const stmt = status === "pending" ? env.DB.prepare(SQL.listPending).bind(cutoff, n)
      : status === "expired" ? env.DB.prepare(SQL.listExpired).bind(cutoff, n)
      : status === "all" ? env.DB.prepare(SQL.listAll).bind(n)
      : env.DB.prepare(SQL.listStatus).bind(status, n);
    const rows = (await stmt.all()).results || [];
    return json(200, { approvals: rows.slice(0, k.limit).map((r) => shape(r, cutoff)), truncated: rows.length > k.limit, as_of: t });
  })],

  ["POST", /^\/api\/owner-approvals\/(\d+)\/decide$/, ({ req, env, t, body, m }) => d1Guarded("owner_approvals", async () => {
    // The proof first: a caller without one learns nothing about the row.
    const proof = await ownerProof(req, env);
    if (!proof.ok) return json(403, { error: "human_proof_required" });
    const b = isObj(body) ? body : {};
    if (b.decision !== "approved" && b.decision !== "declined") return bad("decision must be approved or declined");
    const ref = b.result_ref === undefined ? null : b.result_ref;
    if (ref !== null && !(typeof ref === "string" && ref.length <= REF_MAX)) return bad(`result_ref must be a string of at most ${REF_MAX} characters, or null`);
    const id = Number(m[1]);
    const k = await knobs(env);
    const cutoff = isoPlusSeconds(t, -k.ttlH * 3600);
    const by = proof.via === "box-ops" ? proof.identity : "human-token";
    const res = await env.DB.prepare(SQL.decide).bind(b.decision, t, by, ref, id, cutoff).run();
    const row = shape(await env.DB.prepare(SQL.byId).bind(id).first(), cutoff);
    if (!row) return json(404, { error: "not_found" });
    if (changes(res) > 0) return json(200, { ok: true, approval: row });
    if (row.status === "expired") return json(409, { error: "expired", approval: row });
    return json(409, { error: "already_decided", approval: row });
  })],
];
