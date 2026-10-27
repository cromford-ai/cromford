// participants routes — BH-5349 (BH-5348.0): a machine outside the Fly pool
// asks to take part in tickets, the lead approves it, and participantAuth checks
// the token it holds (whoami today; the BH-5348 siblings' routes next). The table is participant_machines
// (schema.sql, and the self-create copy in CREATED_TABLES); it is NOT the pool's
// `machines` table, whose rows the pool reaper destroys.
//
// The machine generates its token locally and sends only its sha256, so the
// worker never holds the secret and no answer ever carries the hash.
//
// Two credentials on top of the bearer every /api/* route needs: approve, deny
// and revoke need the lead token (leadTokenOk, the POST /api/lead-reviews
// authority); whoami and participantAuth need the machine's own token in
// x-participant-token. Every status change is a compare-and-set, so two
// deciders cannot both win, and a repeat of the decision already on the row
// answers that row with `unchanged: true`.
//
// BH-5353 (BH-5348.4), for the Mission Control participants screen: the list
// rows carry `claims` (running lead_review_requests held under the row's name)
// and `last_result` (the newest of those with a verdict), and GET
// /api/participants/:id answers one row with its claims and results. Both
// answer `online_window_s`, the settings row lead_review_claim_stale_s (900
// when it is absent or not a positive integer), which the screen compares
// last_seen_at against. They read lead_review_requests, projects and that
// settings row, and write nothing.
import { d1Guarded, json, nowIso } from "../lib/http.js";
import { ensureColumns, ensureTable, strictInt } from "../lib/core.js";
import { leadTokenOk, optStr } from "./verdicts.js";

export const PARTICIPANT_ROLES = ["build", "fix", "lead-review"];
const STATUSES = ["pending", "approved", "denied", "revoked"];
const NAME_RE = /^[a-z0-9._-]{1,64}$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const LIST_MAX = 200;
const DETAIL_MAX = 50;
export const STALE_FALLBACK_S = 900;
const NO_LEAD = "needs the lead verdict token (x-lead-verdict-token)";

// One normalisation, used at write and at lookup (D17).
const normName = (v) => (typeof v === "string" ? v.trim().toLowerCase() : "");

// A JSON array of strings, or null when the column is absent or malformed.
function parseRoles(s) {
  try {
    const v = JSON.parse(s);
    return Array.isArray(v) && v.every((r) => typeof r === "string") ? v : null;
  } catch { return null; }
}
function parseKnobs(s) {
  try {
    const v = JSON.parse(s);
    return v && typeof v === "object" && !Array.isArray(v) ? v : {};
  } catch { return {}; }
}

// The row as any answer may show it: never token_sha256.
function publicRow(r) {
  const { token_sha256: _hash, ...rest } = r;
  return { ...rest, requested_roles: parseRoles(r.requested_roles) || [],
           granted_roles: parseRoles(r.granted_roles), knobs: parseKnobs(r.knobs) };
}

const getRow = (env, id) =>
  env.DB.prepare("SELECT * FROM participant_machines WHERE id=?1").bind(id).first();

const guarded = (fn) => (ctx) =>
  d1Guarded("participant_machines", async () => {
    await ensureTable(ctx.env, "participant_machines");
    return fn(ctx);
  });

// The online window, DB-driven: the settings row, else the documented fallback.
export async function staleWindow(env) {
  // first() with no column: the lead-reviews suites' D1 stand-ins take no argument.
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key='lead_review_claim_stale_s'").first();
  const n = strictInt(r ? r.value : null);
  return n !== null && n > 0 ? n : STALE_FALLBACK_S;
}

// lead_review_requests self-creates, and `participant` is an added column.
async function reviewTables(env) {
  await ensureTable(env, "lead_review_requests");
  await ensureColumns(env, "lead_review_requests");
  await ensureTable(env, "projects");
}

// A non-empty, duplicate-free list drawn from `allowed`; returns { err } or { v }.
function roleList(v, key, allowed) {
  if (!Array.isArray(v) || v.length === 0) return { err: `${key} must be a non-empty array of ${allowed.join(", ")}` };
  const bad = v.find((r) => !allowed.includes(r));
  if (bad !== undefined) return { err: `${key}: ${String(bad)} is not one of ${allowed.join(", ")}` };
  if (new Set(v).size !== v.length) return { err: `${key} has a duplicate role` };
  return { v };
}

// The deciding actor, self-declared beside the shared lead token.
function actorOf(body) {
  const a = body.actor;
  if (a === undefined || a === null) return { v: "lead-token" };
  const s = typeof a === "string" ? a.trim() : "";
  return s && s.length <= 128 ? { v: s } : { err: "actor must be a string, 1..128 chars" };
}

const sha256Hex = async (s) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))]
    .map((b) => b.toString(16).padStart(2, "0")).join("");

// The participant credential. Reads the row on EVERY call (no cache), so a
// revoke bites on the next request. `role` null means approved with any grant
// (whoami). A granted_roles that does not parse is no grant: fail closed.
// last_seen_at is stamped only on an ok answer.
export async function participantAuth(req, env, role) {
  const token = (req.headers.get("x-participant-token") || "").trim();
  if (!token) return { ok: false, status: 401, why: "needs x-participant-token" };
  await ensureTable(env, "participant_machines");
  const row = await env.DB.prepare("SELECT * FROM participant_machines WHERE token_sha256=?1")
    .bind(await sha256Hex(token)).first();
  if (!row) return { ok: false, status: 403, why: "unknown participant token" };
  if (row.status !== "approved") return { ok: false, status: 403, why: `participant is ${row.status}` };
  const granted = parseRoles(row.granted_roles);
  if (!granted || (role !== null && !granted.includes(role))) {
    return { ok: false, status: 403, why: `role ${role === null ? "any" : role} not granted` };
  }
  const t = nowIso();
  await env.DB.prepare("UPDATE participant_machines SET last_seen_at=?1 WHERE id=?2").bind(t, row.id).run();
  return { ok: true, machine: publicRow({ ...row, last_seen_at: t }) };
}

// approve | deny | revoke: lead token, the row, then one CAS from `from`.
// On a lost CAS the row is re-read: already at `to` (and, for approve, with
// the same grant) is the sealed answer; anything else is a 409 naming why.
function decision(verb, from, to, stamp) {
  return [
    "POST", new RegExp(`^\\/api\\/participants\\/([^/]+)\\/${verb}$`),
    guarded(async ({ req, env, t, body, m }) => {
      if (!leadTokenOk(req, env)) return json(403, { error: `${verb} ${NO_LEAD}` });
      const b = body || {};
      const id = decodeURIComponent(m[1]);
      const row = await getRow(env, id);
      if (!row) return json(404, { error: "no such participant" });
      const actor = actorOf(b);
      if (actor.err) return json(400, { error: actor.err });
      let granted = null;
      if (verb === "approve") {
        const g = roleList(b.granted_roles, "granted_roles", parseRoles(row.requested_roles) || []);
        if (g.err) return json(400, { error: `${g.err} (granted_roles must be a subset of requested_roles)` });
        granted = JSON.stringify(g.v);
      }
      const set = verb === "approve" ? `status=?1, ${stamp}_by=?2, ${stamp}_at=?3, granted_roles=?5`
                                     : `status=?1, ${stamp}_by=?2, ${stamp}_at=?3`;
      // sql-ident-ok: stamp and from are literals from the three decision() calls at the end of this file
      const stmt = env.DB.prepare(`UPDATE participant_machines SET ${set} WHERE id=?4 AND status='${from}'`);
      const res = await (verb === "approve" ? stmt.bind(to, actor.v, t, id, granted) : stmt.bind(to, actor.v, t, id)).run();
      const now = await getRow(env, id);
      if (res.meta.changes === 1) return json(200, { participant: publicRow(now) });
      if (now.status === to) {
        const same = verb !== "approve" ||
          JSON.stringify([...(parseRoles(now.granted_roles) || [])].sort()) === JSON.stringify([...JSON.parse(granted)].sort());
        if (same) return json(200, { participant: publicRow(now), unchanged: true });
        return json(409, { error: "participant is already approved with different granted_roles", participant: publicRow(now) });
      }
      return json(409, { error: `participant is ${now.status}; ${verb} needs ${from}`, participant: publicRow(now) });
    }),
  ];
}

export const routes = [
  [
    "POST", "/api/participants/request",
    guarded(async ({ env, t, body }) => {
      const b = body || {};
      const name = normName(b.name);
      if (!NAME_RE.test(name)) return json(400, { error: "name must be 1..64 chars of a-z 0-9 . _ - (trimmed, lowercased)" });
      const roles = roleList(b.requested_roles, "requested_roles", PARTICIPANT_ROLES);
      if (roles.err) return json(400, { error: roles.err });
      if (typeof b.token_sha256 !== "string" || !SHA_RE.test(b.token_sha256)) {
        return json(400, { error: "token_sha256 must be 64 lowercase hex chars" });
      }
      const owner = optStr(b, "owner", 128);
      if (!owner.ok) return json(400, { error: owner.err });
      const billing = optStr(b, "billing_account", 128);
      if (!billing.ok) return json(400, { error: billing.err });

      const taken = await env.DB.prepare("SELECT status FROM participant_machines WHERE name=?1").bind(name).first();
      if (taken) return json(409, { error: `name ${name} is already ${taken.status}` });
      const id = crypto.randomUUID();
      try {
        // status is a literal: no body field reaches it, or granted_roles.
        await env.DB.prepare(
          `INSERT INTO participant_machines (id, name, owner, requested_roles, token_sha256, billing_account, status, requested_at)
           VALUES (?1,?2,?3,?4,?5,?6,'pending',?7)`
        ).bind(id, name, owner.v, JSON.stringify(roles.v), b.token_sha256, billing.v, t).run();
      } catch (e) {
        const msg = String((e && e.message) || e);
        if (/UNIQUE constraint failed: participant_machines\.token_sha256/i.test(msg)) return json(409, { error: "token_sha256 is already enrolled" });
        if (/UNIQUE constraint failed: participant_machines\.name/i.test(msg)) return json(409, { error: `name ${name} is already taken` });
        throw e;
      }
      return json(201, { participant: publicRow(await getRow(env, id)) });
    }),
  ],

  // ?status= one of the four. Newest first; at most 200 rows, and `truncated`
  // is measured by reading one row past that.
  [
    "GET", "/api/participants",
    guarded(async ({ env, url }) => {
      const status = url.searchParams.get("status");
      if (status !== null && !STATUSES.includes(status)) return json(400, { error: `status must be one of ${STATUSES.join(", ")}` });
      const sql = `SELECT * FROM participant_machines ${status === null ? "" : "WHERE status=?1 "}ORDER BY requested_at DESC, id LIMIT ${LIST_MAX + 1}`;
      const stmt = env.DB.prepare(sql);
      const { results } = await (status === null ? stmt : stmt.bind(status)).all();
      const rows = results || [];
      await reviewTables(env);
      const counts = await env.DB.prepare(
        `SELECT participant, COUNT(*) AS n FROM lead_review_requests
         WHERE status='running' AND participant IS NOT NULL GROUP BY participant`
      ).all();
      const claims = new Map((counts.results || []).map((r) => [r.participant, Number(r.n)]));
      // The newest verdict-bearing row per participant (ties broken by id).
      const last = await env.DB.prepare(
        `SELECT l.participant, l.verdict, l.repo, l.pr, p.project, l.updated_at AS at
         FROM lead_review_requests l LEFT JOIN projects p ON p.repo = l.repo
         WHERE l.participant IS NOT NULL AND l.verdict IS NOT NULL
           AND l.id = (SELECT x.id FROM lead_review_requests x
                       WHERE x.participant = l.participant AND x.verdict IS NOT NULL
                       ORDER BY x.updated_at DESC, x.id DESC LIMIT 1)`
      ).all();
      const lastBy = new Map((last.results || []).map(({ participant, ...r }) => [participant, r]));
      return json(200, {
        participants: rows.slice(0, LIST_MAX).map((r) => ({
          ...publicRow(r), claims: claims.get(r.name) || 0, last_result: lastBy.get(r.name) || null,
        })),
        truncated: rows.length > LIST_MAX,
        online_window_s: await staleWindow(env),
      });
    }),
  ],

  [
    "GET", "/api/participants/whoami",
    guarded(async ({ req, env }) => {
      const a = await participantAuth(req, env, null);
      if (!a.ok) return json(a.status, { error: a.why });
      const { id, name, status, granted_roles, knobs } = a.machine;
      return json(200, { id, name, status, granted_roles, knobs });
    }),
  ],

  // One participant: its row, its running claims and its other review rows,
  // newest first, at most 50 between them (`truncated` reads one past that).
  // After /whoami on purpose: the router takes the first match.
  [
    "GET", /^\/api\/participants\/([^/]+)$/,
    guarded(async ({ env, m }) => {
      const row = await getRow(env, decodeURIComponent(m[1]));
      if (!row) return json(404, { error: "no such participant" });
      await reviewTables(env);
      // sql-ident-ok: DETAIL_MAX is a code constant
      const { results } = await env.DB.prepare(
        `SELECT l.id, l.repo, l.pr, l.head_sha, l.status, l.verdict, l.heartbeat_at, l.updated_at, p.project
         FROM lead_review_requests l LEFT JOIN projects p ON p.repo = l.repo
         WHERE l.participant = ?1 ORDER BY l.updated_at DESC, l.id LIMIT ${DETAIL_MAX + 1}`
      ).bind(row.name).all();
      const reviews = (results || []).slice(0, DETAIL_MAX);
      return json(200, {
        participant: publicRow(row),
        claims: reviews.filter((r) => r.status === "running"),
        results: reviews.filter((r) => r.status !== "running"),
        truncated: (results || []).length > DETAIL_MAX,
        online_window_s: await staleWindow(env),
      });
    }),
  ],

  decision("approve", "pending", "approved", "decided"),
  decision("deny", "pending", "denied", "decided"),
  decision("revoke", "approved", "revoked", "revoked"),
];
