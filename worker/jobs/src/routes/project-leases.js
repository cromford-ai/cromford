// project-leases routes — one lease per (lane, project) with a fence token
// (BH-6883, BH-6881.1). Contract and knob:
// docs/notes/2026-10-15-BH-6883-project-lease.md. Shell client:
// bin/lib/project-lease.sh.
//
// POST /api/project-leases/acquire {lane, project, holder, ttl_s?}: ONE
// statement. It inserts the row at fence 1, or takes a row whose lease_until
// has passed (fence + 1), or extends the caller's own live lease (same
// fence). 200 {fence, lease_until, as_of}; a live lease of another holder is
// 409 `held`, and the answer never names that holder.
// POST /api/project-leases/renew {lane, project, holder, fence, ttl_s?}: ONE
// statement, only while holder AND fence match and the lease is live. Else 409
// `lost`, nothing written.
// POST /api/project-leases/release {lane, project, holder, fence}: ONE
// statement sets lease_until to now (an earlier lease_until is kept), only
// while holder AND fence match. A retried release answers 200 again. Else 409
// `lost`, nothing written.
//
// The clock is the worker's `t`; a box never sends a time. A row is never
// deleted, so the fence only increases.

import { d1Guarded, json } from "../lib/http.js";
import { isoPlusSeconds, laneName, leaseWon, strictInt } from "../lib/core.js";

// The settings row, its bounds and the documented code fallback.
const TTL = { key: "project_lease.ttl_s", def: 180, min: 10, max: 900 };

// Exported so tests/lib/project-lease.bh-6883.mjs explains the exact statements.
export const ACQUIRE_SQL = `INSERT INTO project_leases (lane,project,holder,fence,lease_until,acquired_at) VALUES (?1,?2,?3,1,?4,?5)
ON CONFLICT(lane,project) DO UPDATE SET
  fence = CASE WHEN project_leases.lease_until <= excluded.acquired_at THEN project_leases.fence+1 ELSE project_leases.fence END,
  acquired_at = CASE WHEN project_leases.lease_until <= excluded.acquired_at THEN excluded.acquired_at ELSE project_leases.acquired_at END,
  holder = excluded.holder, lease_until = excluded.lease_until
WHERE project_leases.lease_until <= excluded.acquired_at OR project_leases.holder = excluded.holder
RETURNING fence, lease_until`;
export const RENEW_SQL = "UPDATE project_leases SET lease_until=?1 WHERE lane=?2 AND project=?3 AND holder=?4 AND fence=?5 AND lease_until > ?6";
export const RELEASE_SQL = "UPDATE project_leases SET lease_until = CASE WHEN lease_until > ?1 THEN ?1 ELSE lease_until END WHERE lane=?2 AND project=?3 AND holder=?4 AND fence=?5";

// A settings integer in [min, max], else the fallback. Same rule as
// routes/lane-runs-lease.js.
async function settingInt(env, { key, def, min, max }) {
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first();
  const s = r ? String(r.value).trim() : "";
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= min && n <= max ? n : def;
}

// The validated request, or { error } for a 400. Runs before any statement.
// A JSON body that is not an object (`null`, an array) has no fields.
function parse(raw, { fence }) {
  const body = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const lane = laneName(body.lane), project = laneName(body.project), holder = laneName(body.holder);
  if (!lane || !project || !holder) return { error: "lane, project and holder are required and must match [A-Za-z0-9._-]{1,64}" };
  const out = { lane, project, holder };
  if (fence) {
    const f = strictInt(body.fence);
    if (f === null || f < 1) return { error: "fence must be an integer >= 1" };
    out.fence = f;
  }
  return out;
}

// The lease length: the body's ttl_s when sent (10..900, else a 400, never a
// clamp), else the settings row.
async function ttlSeconds(env, raw) {
  const body = raw && typeof raw === "object" ? raw : {};
  if (body.ttl_s === undefined || body.ttl_s === null) return settingInt(env, TTL);
  const n = typeof body.ttl_s === "string" || typeof body.ttl_s === "number" ? strictInt(body.ttl_s) : null;
  return n !== null && n >= TTL.min && n <= TTL.max ? n : null;
}
const TTL_ERROR = `ttl_s must be an integer in ${TTL.min}..${TTL.max}`;

export const routes = [
  [
    "POST", "/api/project-leases/acquire",
    ({ env, t, body }) => d1Guarded("project_leases", async () => {
      const q = parse(body, { fence: false });
      if (q.error) return json(400, { error: q.error });
      const ttl = await ttlSeconds(env, body);
      if (ttl === null) return json(400, { error: TTL_ERROR });
      const until = isoPlusSeconds(t, ttl);
      const row = await env.DB.prepare(ACQUIRE_SQL).bind(q.lane, q.project, q.holder, until, t).first();
      if (row) return json(200, { fence: Number(row.fence), lease_until: row.lease_until, as_of: t });
      return json(409, { error: "held", as_of: t });
    }),
  ],
  [
    "POST", "/api/project-leases/renew",
    ({ env, t, body }) => d1Guarded("project_leases", async () => {
      const q = parse(body, { fence: true });
      if (q.error) return json(400, { error: q.error });
      const ttl = await ttlSeconds(env, body);
      if (ttl === null) return json(400, { error: TTL_ERROR });
      const until = isoPlusSeconds(t, ttl);
      const r = await env.DB.prepare(RENEW_SQL).bind(until, q.lane, q.project, q.holder, q.fence, t).run();
      if (leaseWon(r)) return json(200, { fence: q.fence, lease_until: until, as_of: t });
      return json(409, { error: "lost", as_of: t });
    }),
  ],
  [
    "POST", "/api/project-leases/release",
    ({ env, t, body }) => d1Guarded("project_leases", async () => {
      const q = parse(body, { fence: true });
      if (q.error) return json(400, { error: q.error });
      const r = await env.DB.prepare(RELEASE_SQL).bind(t, q.lane, q.project, q.holder, q.fence).run();
      if (leaseWon(r)) return json(200, { released: true, fence: q.fence, as_of: t });
      return json(409, { error: "lost", as_of: t });
    }),
  ],
];
