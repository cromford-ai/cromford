// product-proposals routes — BH-2531: the product lane's proposal ledger as
// rows keyed (project, proposal_id).
//
// The box's file state/product-<project>.ledger.json stays the lane's working
// copy; this table is the record that survives the box. bin/lib/proposal-rows.sh
// is the only client: prow_restore rebuilds the file from GET, prow_put writes a
// ledger entry through PUT, and prow_get reads one row. No lane sources that
// client yet; the lane wiring is a sibling slice of BH-2531.
//
// The table ships in schema.sql, which bin/harness-sync.sh applies before
// `wrangler deploy`; every handler is d1Guarded so an unapplied table answers
// 503 "product_proposals schema not applied", never a bodiless 500.
//
// A missing row is 404 {"error":"proposal not found"} — that exact body, so the
// client can tell it from the router's own "unknown endpoint" 404 (a worker that
// predates this route), which must never read as "never posted".
//
// A PUT with `if_absent: true` inserts only when there is no row and never
// touches one that exists; the answer's `inserted` says which. It is the
// one-time backfill of ledger entries written before this table existed: a stale
// file entry must never overwrite a newer row (a `posting` claim, a `posted`).

import { json, d1Guarded } from "../lib/http.js";

const LIST_CAP = 1000;
const RECORD_MAX = 32000;
const SAFE = /^[A-Za-z0-9._-]{1,128}$/;

const rowOut = (r) => ({
  project: r.project, proposal_id: r.proposal_id, status: r.status,
  record: JSON.parse(r.record), actor: r.actor, created_at: r.created_at, updated_at: r.updated_at,
});

// The record as its JSON text, or null when it is not a JSON object. Refused,
// never truncated: a cut record restores as a proposal nobody wrote.
function recordText(v) {
  let obj = v;
  if (typeof v === "string") {
    try { obj = JSON.parse(v); } catch { return null; }
  }
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) return null;
  return JSON.stringify(obj);
}

export const routes = [
  [
    "GET", "/api/product-proposals",
    async ({ env, url, t }) => {
      const project = url.searchParams.get("project");
      const id = url.searchParams.get("proposal_id");
      if (!SAFE.test(project || "")) return json(400, { error: "project must match [A-Za-z0-9._-]{1,128}" });
      if (id !== null && !SAFE.test(id)) return json(400, { error: "proposal_id must match [A-Za-z0-9._-]{1,128}" });
      return d1Guarded("product_proposals", async () => {
        if (id !== null) {
          const row = await env.DB.prepare(
            "SELECT * FROM product_proposals WHERE project=?1 AND proposal_id=?2"
          ).bind(project, id).first();
          return row ? json(200, { proposal: rowOut(row) }) : json(404, { error: "proposal not found" });
        }
        // One past the cap, so `truncated` says the list really was cut.
        const res = await env.DB.prepare(
          "SELECT * FROM product_proposals WHERE project=?1 ORDER BY proposal_id LIMIT ?2"
        ).bind(project, LIST_CAP + 1).all();
        const rows = res.results || [];
        return json(200, {
          proposals: rows.slice(0, LIST_CAP).map(rowOut), truncated: rows.length > LIST_CAP, as_of: t,
        });
      });
    },
  ],

  [
    "PUT", "/api/product-proposals",
    async ({ env, t, body: raw }) => {
      // readBody answers the parsed JSON, which for a body of `null` or `7` is
      // not an object; that is a refused request, not a throw.
      const body = raw !== null && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
      const { project, proposal_id: id, status } = body;
      if (typeof project !== "string" || !SAFE.test(project)) return json(400, { error: "project must match [A-Za-z0-9._-]{1,128}" });
      if (typeof id !== "string" || !SAFE.test(id)) return json(400, { error: "proposal_id must match [A-Za-z0-9._-]{1,128}" });
      if (typeof status !== "string" || status === "" || status.length > 32) return json(400, { error: "status must be a string of 1-32 chars" });
      const record = recordText(body.record);
      if (record === null) return json(400, { error: "record must be a JSON object" });
      if (record.length > RECORD_MAX) return json(400, { error: "record is over " + RECORD_MAX + " chars" });
      const actor = typeof body.actor === "string" && body.actor !== "" ? body.actor.slice(0, 128) : null;
      const ifAbsent = body.if_absent === true;
      return d1Guarded("product_proposals", async () => {
        // sql-ident-ok: the ON CONFLICT clause is one of two literals picked by ifAbsent
        const res = await env.DB.prepare(
          "INSERT INTO product_proposals (project, proposal_id, status, record, actor, created_at, updated_at) "
          + "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6) "
          + (ifAbsent
            ? "ON CONFLICT(project, proposal_id) DO NOTHING"
            : "ON CONFLICT(project, proposal_id) DO UPDATE SET status=excluded.status, record=excluded.record, "
              + "actor=COALESCE(excluded.actor, product_proposals.actor), updated_at=excluded.updated_at")
        ).bind(project, id, status, record, actor, t).run();
        const row = await env.DB.prepare(
          "SELECT * FROM product_proposals WHERE project=?1 AND proposal_id=?2"
        ).bind(project, id).first();
        if (!row) return json(500, { error: "proposal row not found after upsert" });
        const out = { proposal: rowOut(row) };
        if (ifAbsent) out.inserted = Number(res?.meta?.changes || 0) > 0;
        return json(200, out);
      });
    },
  ],
];
