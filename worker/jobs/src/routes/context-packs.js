// context-packs routes — the map a split parent hands its children (BH-3493).
//
// When a ticket splits, the parent's plan already paid to read the code. The
// parent publishes that reading once per child (bin/lib/context-pack.sh
// cp_put) and the child fetches it before it plans (cp_fetch), so it starts
// warm instead of re-reading the same files. The shell side fails open: a 404
// here means "plan in full, as before".
//
// BEARER-ONLY, both verbs: every entry in ROUTES sits behind `bearerOk` in
// src/index.js. A pack over CONTEXT_PACK_MAX_BYTES is a 413 and nothing is
// stored — never a slice, because half a map misleads the planner that trusts
// it. Every refusal happens before the first D1 statement.

import { json } from "../lib/http.js";
import {
  CONTEXT_PACK_MAX_BYTES, CONTEXT_PACK_INDEX_COLS, CONTEXT_PACK_COLS,
  ensureTable, laneName,
} from "../lib/core.js";

const KEY_RULE = "must match [A-Za-z0-9._-]{1,64}";

export const routes = [
  // Upsert on (project, ticket_key): a re-published pack REPLACES the old one,
  // and a re-sent POST (bin/lib/jobs/req.sh retries a lost reply) lands the
  // same row. created_at survives; box survives a POST that omits it.
  [
    "POST", "/api/context-packs",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      if (!project) return json(400, { error: `project is required and ${KEY_RULE}` });
      const key = laneName(body.ticket_key || body.key);
      if (!key) return json(400, { error: `ticket_key is required and ${KEY_RULE}` });
      const parent = laneName(body.parent_key);
      if (!parent) return json(400, { error: `parent_key is required and ${KEY_RULE}` });
      // Exact compare, like every key in this worker: cp_fetch ignores a row
      // whose parent is itself, so storing one would be a pack nobody reads.
      if (parent === key) return json(400, { error: "parent_key must differ from ticket_key" });
      const packMd = typeof body.pack_md === "string" ? body.pack_md : "";
      if (!packMd.trim()) return json(400, { error: "pack_md must be a non-empty pack" });
      // Measured in BYTES, which is what the cap is named for.
      const bytes = new TextEncoder().encode(packMd).length;
      if (bytes > CONTEXT_PACK_MAX_BYTES) {
        return json(413, { error: "context pack too large", bytes, max: CONTEXT_PACK_MAX_BYTES });
      }
      // Optional and NOT validated as a sha: the contract lists no 400 for it,
      // and cp_put reads any 4xx as "refused".
      const str = (v, n) => (v === undefined || v === null || v === "" ? null : String(v).slice(0, n));
      const baseSha = str(String(body.base_sha ?? "").trim().toLowerCase(), 64);
      // The table creates itself before the first statement that needs it.
      await ensureTable(env, "context_packs");
      await env.DB.prepare(
        `INSERT INTO context_packs
           (project, ticket_key, parent_key, base_sha, pack_md, bytes, box, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?8)
         ON CONFLICT(project, ticket_key) DO UPDATE SET
           parent_key=?3, base_sha=?4, pack_md=?5, bytes=?6, box=COALESCE(?7, box), updated_at=?8`
      ).bind(project, key, parent, baseSha, packMd, bytes, str(body.box, 64), t).run();
      // The row WITHOUT its pack: the publisher has the pack on disk already.
      // sql-ident-ok: CONTEXT_PACK_INDEX_COLS is a const column list in lib/core.js
      const row = await env.DB.prepare(
        `SELECT ${CONTEXT_PACK_INDEX_COLS} FROM context_packs WHERE project=?1 AND ticket_key=?2`
      ).bind(project, key).first();
      return json(200, { context_pack: row });
    },
  ],

  // One pack, WITH its body — cp_fetch's read, once per child plan. `key` is
  // required: there is no index read in the contract, and bodies reach 64 KB.
  // A 404 means nothing was published for this child, not an outage.
  [
    "GET", "/api/context-packs",
    async ({ env, url, t }) => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: `project is required and ${KEY_RULE}` });
      const key = laneName(url.searchParams.get("key") || url.searchParams.get("ticket_key"));
      if (!key) return json(400, { error: `key is required and ${KEY_RULE}` });
      // The READ creates it too: an honest 404 on a fresh D1, never a 500.
      await ensureTable(env, "context_packs");
      // sql-ident-ok: CONTEXT_PACK_COLS is a const column list in lib/core.js
      const row = await env.DB.prepare(
        `SELECT ${CONTEXT_PACK_COLS} FROM context_packs WHERE project=?1 AND ticket_key=?2`
      ).bind(project, key).first();
      if (!row) return json(404, { error: "no such context pack" });
      return json(200, { context_pack: row, as_of: t });
    },
  ],
];
