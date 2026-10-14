// lane-snapshots routes — blocked-resolver inputs off the hub (BH-6047).
//
// A lane placed `fly` runs on a machine that has none of the hub's state
// files. The hub publishes that state as ONE read-only tar.gz per
// (lane, project), base64-encoded and split into parts so each request stays
// under the worker's body limit. The machine fetches the current generation,
// runs the lane, and posts what it changed as ONE write-back row. The hub
// applies the write-backs in id order and acks them. The shell side is
// bin/lib/lane-run-inputs.sh.
//
// The contract:
//   * PUT  …/<lane>/<project>/parts/<n>   {sha, b64}  stages one part (upsert).
//   * POST …/<lane>/<project>/commit      {sha, parts, applied_through} flips
//     lane_snapshots to that sha in ONE statement, but only when parts
//     0..parts-1 of that sha are all staged (else 409 parts_missing). Staged
//     parts of any other sha of this (lane, project) are then deleted. A commit
//     of the current sha only refreshes published_at and applied_through.
//   * GET  …/<lane>/<project>             the current generation, its age on
//     the SERVER clock (machine clock skew never counts), and the write-backs
//     the hub has not folded in yet (id > applied_through, not rejected).
//   * GET  …/<lane>/<project>/parts/<n>?sha=  one part.
//   * POST …/<lane>/<project>/writebacks  {run_id, machine, sha, b64}; a replay
//     of the same (lane, project, run_id, sha) is the same row and the same id.
//   * GET  …/<lane>/<project>/writebacks  the hub's unapplied list.
//   * GET  …/<lane>/<project>/writebacks/<id>  one write-back.
//   * POST …/<lane>/<project>/writebacks/ack  {through, rejected?} stamps the
//     rows, then prunes this (lane, project)'s rows stamped over 7 days ago.
//
// Every list is capped by the settings row lane_snapshot.max_pending and says
// `truncated` when it hit the cap, so a reader never takes a short list for
// the whole one. Every handler runs inside d1Guarded, so a worker whose D1
// lacks the tables answers 503 "lane_snapshots schema not applied", not 500.
// Lane and project come from the path and are validated in the handler, so a
// bad name is a 400, never the router's 404.

import { d1Guarded, json } from "../lib/http.js";
import { isoPlusSeconds, laneName } from "../lib/core.js";

const PROJECT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const B64_RE = /^[A-Za-z0-9+/=]+$/;
const B64_MAX_CHARS = 1400000;
const PART_N_MAX = 255;
const PARTS_MAX = 256;
const REJECTED_MAX = 1000;
const PRUNE_AFTER_S = 604800;
// The settings row and its documented code fallback.
const MAX_PENDING_KEY = "lane_snapshot.max_pending";
const MAX_PENDING_DEFAULT = 500;
const MAX_PENDING_MIN = 1;
const MAX_PENDING_MAX = 10000;

const BASE = "^\\/api\\/lane-snapshots\\/([^/]+)\\/([^/]+)";
const T = "lane_snapshots";
// The write-back predicates, module constants so every query that splices one
// in is checkably literal SQL (checks/sql-command-injection shape (a)).
const WB_PENDING = "lane=?1 AND project=?2 AND id > ?3 AND rejected_at IS NULL";
const WB_OPEN = "lane=?1 AND project=?2 AND id <= ?3 AND applied_at IS NULL AND rejected_at IS NULL";

// { lane, project } or { err } (a 400 response).
function target(m) {
  const lane = laneName(m[1]);
  const project = PROJECT_RE.test(m[2]) ? m[2] : "";
  if (!lane || !project) {
    return { err: json(400, { error: "lane must match [A-Za-z0-9._-]{1,64} and project ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$" }) };
  }
  return { lane, project };
}

// null when b64 is good, else the error response.
function b64Err(b64) {
  if (typeof b64 !== "string" || b64 === "") return json(400, { error: "b64 must be a non-empty base64 string" });
  if (b64.length > B64_MAX_CHARS) return json(413, { error: "too_large", max_chars: B64_MAX_CHARS });
  if (!B64_RE.test(b64)) return json(400, { error: "b64 must match [A-Za-z0-9+/=]+" });
  return null;
}

const shaOk = (v) => typeof v === "string" && SHA_RE.test(v);
const SHA_ERR = "sha must be 64 lower-case hex characters (sha256)";

// An integer from a path segment or a body field, or NaN.
function intOf(v) {
  if (typeof v === "number") return Number.isInteger(v) ? v : NaN;
  if (typeof v === "string" && /^\d+$/.test(v)) return Number(v);
  return NaN;
}

async function maxPending(env) {
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(MAX_PENDING_KEY).first();
  const s = r ? String(r.value).trim() : "";
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= MAX_PENDING_MIN && n <= MAX_PENDING_MAX ? n : MAX_PENDING_DEFAULT;
}

export const routes = [
  [
    "PUT", new RegExp(BASE + "\\/parts\\/([^/]+)$"),
    ({ env, body, m }) => d1Guarded(T, async () => {
      const g = target(m);
      if (g.err) return g.err;
      const n = intOf(m[3]);
      if (!(n >= 0 && n <= PART_N_MAX)) return json(400, { error: `n must be an integer 0..${PART_N_MAX}` });
      if (!shaOk(body.sha)) return json(400, { error: SHA_ERR });
      const bad = b64Err(body.b64);
      if (bad) return bad;
      await env.DB.prepare(
        `INSERT INTO lane_snapshot_parts (lane, project, sha, n, b64) VALUES (?1,?2,?3,?4,?5)
         ON CONFLICT(lane, project, sha, n) DO UPDATE SET b64=excluded.b64`
      ).bind(g.lane, g.project, body.sha, n, body.b64).run();
      return json(200, { ok: true, sha: body.sha, n });
    }),
  ],

  [
    "POST", new RegExp(BASE + "\\/commit$"),
    ({ env, t, body, m }) => d1Guarded(T, async () => {
      const g = target(m);
      if (g.err) return g.err;
      if (!shaOk(body.sha)) return json(400, { error: SHA_ERR });
      const parts = body.parts;
      if (!Number.isInteger(parts) || parts < 1 || parts > PARTS_MAX) {
        return json(400, { error: `parts must be an integer 1..${PARTS_MAX}` });
      }
      const through = body.applied_through;
      if (!Number.isInteger(through) || through < 0) return json(400, { error: "applied_through must be an integer >= 0" });
      const staged = (await env.DB.prepare(
        "SELECT n, length(b64) AS len FROM lane_snapshot_parts WHERE lane=?1 AND project=?2 AND sha=?3 AND n < ?4"
      ).bind(g.lane, g.project, body.sha, parts).all()).results || [];
      const have = new Set(staged.map((r) => Number(r.n)));
      const missing = [];
      for (let i = 0; i < parts; i++) if (!have.has(i)) missing.push(i);
      if (missing.length) return json(409, { error: "parts_missing", missing });
      const bytes = staged.reduce((a, r) => a + Number(r.len), 0);
      const prev = await env.DB.prepare("SELECT sha FROM lane_snapshots WHERE lane=?1 AND project=?2")
        .bind(g.lane, g.project).first();
      await env.DB.prepare(
        `INSERT INTO lane_snapshots (lane, project, sha, parts, bytes, applied_through, published_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7)
         ON CONFLICT(lane, project) DO UPDATE SET sha=excluded.sha, parts=excluded.parts,
           bytes=excluded.bytes, applied_through=excluded.applied_through, published_at=excluded.published_at`
      ).bind(g.lane, g.project, body.sha, parts, bytes, through, t).run();
      await env.DB.prepare(
        "DELETE FROM lane_snapshot_parts WHERE lane=?1 AND project=?2 AND (sha <> ?3 OR n >= ?4)"
      ).bind(g.lane, g.project, body.sha, parts).run();
      return json(200, {
        sha: body.sha, parts, bytes, applied_through: through, published_at: t,
        changed: !prev || prev.sha !== body.sha,
      });
    }),
  ],

  [
    "GET", new RegExp(BASE + "$"),
    ({ env, t, m }) => d1Guarded(T, async () => {
      const g = target(m);
      if (g.err) return g.err;
      const row = await env.DB.prepare(
        "SELECT sha, parts, bytes, applied_through, published_at FROM lane_snapshots WHERE lane=?1 AND project=?2"
      ).bind(g.lane, g.project).first();
      if (!row) return json(404, { error: "no_snapshot" });
      const through = Number(row.applied_through);
      const cap = await maxPending(env);
      const wb = (await env.DB.prepare(`SELECT id, sha FROM lane_snapshot_writebacks WHERE ${WB_PENDING} ORDER BY id LIMIT ?4`)
        .bind(g.lane, g.project, through, cap + 1).all()).results || [];
      const cnt = await env.DB.prepare(`SELECT COUNT(*) AS n FROM lane_snapshot_writebacks WHERE ${WB_PENDING}`)
        .bind(g.lane, g.project, through).first();
      return json(200, {
        sha: row.sha, parts: Number(row.parts), bytes: Number(row.bytes), applied_through: through,
        published_at: row.published_at,
        age_s: Math.max(0, Math.floor((Date.parse(t) - Date.parse(row.published_at)) / 1000)),
        writebacks: wb.slice(0, cap).map((r) => ({ id: Number(r.id), sha: r.sha })),
        pending: Number(cnt ? cnt.n : 0),
        truncated: wb.length > cap,
      });
    }),
  ],

  [
    "GET", new RegExp(BASE + "\\/parts\\/([^/]+)$"),
    ({ env, url, m }) => d1Guarded(T, async () => {
      const g = target(m);
      if (g.err) return g.err;
      const n = intOf(m[3]);
      if (!(n >= 0 && n <= PART_N_MAX)) return json(400, { error: `n must be an integer 0..${PART_N_MAX}` });
      const sha = url.searchParams.get("sha");
      if (!shaOk(sha)) return json(400, { error: SHA_ERR });
      const row = await env.DB.prepare(
        "SELECT b64 FROM lane_snapshot_parts WHERE lane=?1 AND project=?2 AND sha=?3 AND n=?4"
      ).bind(g.lane, g.project, sha, n).first();
      if (!row) return json(404, { error: "no_part" });
      return json(200, { sha, n, b64: row.b64 });
    }),
  ],

  [
    "POST", new RegExp(BASE + "\\/writebacks$"),
    ({ env, t, body, m }) => d1Guarded(T, async () => {
      const g = target(m);
      if (g.err) return g.err;
      const runId = laneName(body.run_id);
      const machine = laneName(body.machine);
      if (!runId || !machine) return json(400, { error: "run_id and machine are required and must match [A-Za-z0-9._-]{1,64}" });
      if (!shaOk(body.sha)) return json(400, { error: SHA_ERR });
      const bad = b64Err(body.b64);
      if (bad) return bad;
      const r = await env.DB.prepare(
        `INSERT OR IGNORE INTO lane_snapshot_writebacks (lane, project, run_id, machine, sha, b64, created_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7)`
      ).bind(g.lane, g.project, runId, machine, body.sha, body.b64, t).run();
      if (((r && r.meta && Number(r.meta.changes)) || 0) > 0) return json(201, { id: Number(r.meta.last_row_id) });
      const old = await env.DB.prepare(
        "SELECT id FROM lane_snapshot_writebacks WHERE lane=?1 AND project=?2 AND run_id=?3 AND sha=?4"
      ).bind(g.lane, g.project, runId, body.sha).first();
      if (!old) return json(503, { error: "lane_snapshots write-back not stored" });
      return json(200, { id: Number(old.id), replay: true });
    }),
  ],

  [
    "GET", new RegExp(BASE + "\\/writebacks$"),
    ({ env, m }) => d1Guarded(T, async () => {
      const g = target(m);
      if (g.err) return g.err;
      const cap = await maxPending(env);
      const rows = (await env.DB.prepare(
        `SELECT id, sha, run_id, machine FROM lane_snapshot_writebacks
         WHERE lane=?1 AND project=?2 AND applied_at IS NULL AND rejected_at IS NULL ORDER BY id LIMIT ?3`
      ).bind(g.lane, g.project, cap + 1).all()).results || [];
      return json(200, {
        writebacks: rows.slice(0, cap).map((r) => ({ id: Number(r.id), sha: r.sha, run_id: r.run_id, machine: r.machine })),
        truncated: rows.length > cap,
      });
    }),
  ],

  [
    "GET", new RegExp(BASE + "\\/writebacks\\/(\\d+)$"),
    ({ env, m }) => d1Guarded(T, async () => {
      const g = target(m);
      if (g.err) return g.err;
      const id = Number(m[3]);
      const row = await env.DB.prepare(
        "SELECT id, sha, b64 FROM lane_snapshot_writebacks WHERE id=?1 AND lane=?2 AND project=?3"
      ).bind(id, g.lane, g.project).first();
      if (!row) return json(404, { error: "no_writeback" });
      return json(200, { id: Number(row.id), sha: row.sha, b64: row.b64 });
    }),
  ],

  [
    "POST", new RegExp(BASE + "\\/writebacks\\/ack$"),
    ({ env, t, body, m }) => d1Guarded(T, async () => {
      const g = target(m);
      if (g.err) return g.err;
      const through = body.through;
      if (!Number.isInteger(through) || through < 0) return json(400, { error: "through must be an integer >= 0" });
      const rej = body.rejected === undefined || body.rejected === null ? [] : body.rejected;
      if (!Array.isArray(rej) || rej.length > REJECTED_MAX || !rej.every((x) => Number.isInteger(x))) {
        return json(400, { error: `rejected must be an array of at most ${REJECTED_MAX} integer ids` });
      }
      let rejected = 0;
      if (rej.length) {
        const r = await env.DB.prepare(
          `UPDATE lane_snapshot_writebacks SET rejected_at=?4
           WHERE ${WB_OPEN} AND id IN (SELECT value FROM json_each(?5))`
        ).bind(g.lane, g.project, through, t, JSON.stringify(rej)).run();
        rejected = Number(r.meta.changes) || 0;
      }
      const a = await env.DB.prepare(`UPDATE lane_snapshot_writebacks SET applied_at=?4 WHERE ${WB_OPEN}`)
        .bind(g.lane, g.project, through, t).run();
      const cut = isoPlusSeconds(t, -PRUNE_AFTER_S);
      const p = await env.DB.prepare(
        "DELETE FROM lane_snapshot_writebacks WHERE lane=?1 AND project=?2 AND (applied_at < ?3 OR rejected_at < ?3)"
      ).bind(g.lane, g.project, cut).run();
      return json(200, { applied: Number(a.meta.changes) || 0, rejected, pruned: Number(p.meta.changes) || 0 });
    }),
  ],
];
