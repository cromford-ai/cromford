// mr-red routes — BH-9532 (C0, #9539): Mr Red's audit rows
// (schema.d/202611111407-bh-9532-mr-red.sql, table mr_red_actions).
//
// POST /api/mr-red/actions {lever, target, fingerprint, repo, project?,
//   target_kind?, approach?, state?, dry_run?, red_check?, evidence_json?}
//   records one action. action_key = sha256(lever|target|fingerprint|approach)
//   is computed here; the caller never sends it. One INSERT ... ON CONFLICT DO
//   NOTHING RETURNING; a conflict reads the row by key. The same key with the
//   same repo, project, target_kind, dry_run and red_check is 200
//   existing:true (nothing is written); any other value is 409 key_mismatch.
//   state is started (a lever will act), observed (no lever matched; terminal)
//   or not-configured.
// PATCH /api/mr-red/actions/:key {state?, evidence_json?, verified_red_at?,
//   verified_green_at?, green_since?, cleared_at?, returned_at?,
//   charged_minutes?, red_check?} — one SELECT and one UPDATE. evidence_json
//   merges into the row's. state=cleared needs verified_red_at AND
//   verified_green_at, from the body or the row: else 400 unverified.
// GET /api/mr-red/actions?repo=&lever=&state=&fingerprint=&target=&limit=&cursor=
//   the rows newest first (created_at DESC, id DESC), one statement. limit
//   1..PAGE_MAX (default PAGE_DEFAULT); cursor = <created_at>~<id> from the
//   last answer's next_cursor (null on the last page).
// Note: docs/notes/2026-11-11-BH-9532-mr-red.md.

import { json, d1Guarded } from "../lib/http.js";

const LEVER_RE = /^[a-z][a-z0-9_-]{0,39}$/;
const FP_RE = /^[0-9a-f]{64}$/;
const REPO_RE = /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/;
const NAME_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const KIND_RE = /^[a-z][a-z0-9_-]{0,19}$/;
const APPROACH_RE = /^[a-z0-9][a-z0-9_.:-]{0,63}$/;
const TIME_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const CURSOR_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)~(\d{1,15})$/;
const TEXT_MAX = 200;
// A request-shape bound, as DETAIL_MAX in staff-levers.js: one row's evidence
// JSON, serialized. It is not an operating limit.
const EVIDENCE_MAX = 16384;
// Page sizes of GET (the contract: limit <= 100). Page sizes, not knobs.
const PAGE_DEFAULT = 50;
const PAGE_MAX = 100;
const POST_STATES = new Set(["started", "observed", "not-configured"]);
const STATES = new Set(["started", "observed", "done", "failed", "dispatched", "dispatch-failed", "declined",
  "not-configured", "cleared", "returned"]);
const TIME_FIELDS = ["verified_red_at", "verified_green_at", "green_since", "cleared_at", "returned_at"];
const COLS = `id, action_key, fingerprint, project, repo, target_kind, target, lever, approach, dry_run, red_check,
  evidence_json, state, verified_red_at, verified_green_at, green_since, cleared_at, returned_at, charged_minutes,
  created_at, updated_at`;

const bad = (field) => json(400, { error: field });
const sha256 = async (s) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))]
  .map((b) => b.toString(16).padStart(2, "0")).join("");
const textOf = (v) => (typeof v === "string" && v.trim() !== "" && v.trim().length <= TEXT_MAX ? v.trim() : null);
// An optional field: absent or null is null, a valid value is kept, anything
// else is undefined (a 400).
const optional = (v, ok) => (v === undefined || v === null ? null : ok(v) ? v : undefined);
const dryOf = (v) => (v === undefined ? 0 : v === 0 || v === false ? 0 : v === 1 || v === true ? 1 : undefined);
const objOf = (v) => (v !== null && typeof v === "object" && !Array.isArray(v) ? v : undefined);
const evidenceOf = (s) => { try { return JSON.parse(s); } catch { return {}; } };
const actionOut = (r) => {
  const { evidence_json: e, ...rest } = r;
  return { ...rest, evidence: evidenceOf(e) };
};

// The statements, exported for the EXPLAIN test.
export const SQL = {
  insert: `INSERT INTO mr_red_actions (action_key, fingerprint, project, repo, target_kind, target, lever, approach,
             dry_run, red_check, evidence_json, state, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13)
           ON CONFLICT(action_key) DO NOTHING RETURNING ${COLS}`,
  byKey: `SELECT ${COLS} FROM mr_red_actions WHERE action_key = ?1`,
};

// listQuery(filters, cursor, n) -> { sql, binds }: one SELECT of n rows. The
// WHERE holds only the filters given, each a bound value; the text comes from
// this fixed list, never from the request.
export function listQuery(f, cursor, n) {
  const where = [];
  const binds = [];
  for (const k of ["repo", "lever", "state", "fingerprint", "target"]) {
    if (f[k] !== undefined && f[k] !== null) { binds.push(f[k]); where.push(`${k} = ?${binds.length}`); }
  }
  if (cursor) {
    binds.push(cursor[0], cursor[1]);
    where.push(`(created_at < ?${binds.length - 1} OR (created_at = ?${binds.length - 1} AND id < ?${binds.length}))`);
  }
  binds.push(n);
  const sql = `SELECT ${COLS} FROM mr_red_actions${where.length ? ` WHERE ${where.join(" AND ")}` : ""}
    ORDER BY created_at DESC, id DESC LIMIT ?${binds.length}`;
  return { sql, binds };
}

export const routes = [
  // ── POST /api/mr-red/actions — one action row, idempotent per action_key ──
  [
    "POST", "/api/mr-red/actions",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const lever = typeof b.lever === "string" && LEVER_RE.test(b.lever) ? b.lever : null;
      if (lever === null) return bad("lever");
      const target = textOf(b.target);
      if (target === null) return bad("target");
      const fp = typeof b.fingerprint === "string" && FP_RE.test(b.fingerprint) ? b.fingerprint : null;
      if (fp === null) return bad("fingerprint");
      const repo = typeof b.repo === "string" && REPO_RE.test(b.repo) ? b.repo : null;
      if (repo === null) return bad("repo");
      const project = optional(b.project, (v) => typeof v === "string" && NAME_RE.test(v));
      if (project === undefined) return bad("project");
      const kind = b.target_kind === undefined ? "pr" : typeof b.target_kind === "string" && KIND_RE.test(b.target_kind) ? b.target_kind : null;
      if (kind === null) return bad("target_kind");
      const approach = b.approach === undefined ? "none" : typeof b.approach === "string" && APPROACH_RE.test(b.approach) ? b.approach : null;
      if (approach === null) return bad("approach");
      const state = b.state === undefined ? "started" : POST_STATES.has(b.state) ? b.state : null;
      if (state === null) return bad("state");
      const dry = dryOf(b.dry_run);
      if (dry === undefined) return bad("dry_run");
      const redCheck = optional(b.red_check, (v) => textOf(v) !== null);
      if (redCheck === undefined) return bad("red_check");
      const ev = b.evidence_json === undefined ? {} : objOf(b.evidence_json);
      if (ev === undefined) return bad("evidence_json");
      const evText = JSON.stringify(ev);
      if (evText.length > EVIDENCE_MAX) return bad("evidence_json");
      const key = await sha256(`${lever}|${target}|${fp}|${approach}`);

      return d1Guarded("mr_red_actions", async () => {
        const made = await env.DB.prepare(SQL.insert)
          .bind(key, fp, project, repo, kind, target, lever, approach, dry, redCheck, evText, state, t).first();
        if (made) return json(200, { ok: true, existing: false, action: actionOut(made) });
        const row = await env.DB.prepare(SQL.byKey).bind(key).first();
        if (!row) return json(500, { error: "action_unresolved", action_key: key });
        const same = row.repo === repo && (row.project ?? null) === project && row.target_kind === kind
          && Number(row.dry_run) === dry && (row.red_check ?? null) === redCheck;
        if (!same) return json(409, { error: "key_mismatch", action: actionOut(row) });
        return json(200, { ok: true, existing: true, action: actionOut(row) });
      });
    },
  ],

  // ── PATCH /api/mr-red/actions/:key — the state and the verification ───────
  [
    "PATCH", /^\/api\/mr-red\/actions\/([^/]+)$/,
    async ({ env, t, body, m }) => {
      const key = decodeURIComponent(m[1]);
      if (!FP_RE.test(key)) return bad("action_key");
      const b = body && typeof body === "object" ? body : {};
      const state = b.state === undefined ? null : STATES.has(b.state) ? b.state : undefined;
      if (state === undefined) return bad("state");
      const times = {};
      for (const k of TIME_FIELDS) {
        const v = optional(b[k], (x) => typeof x === "string" && TIME_RE.test(x));
        if (v === undefined) return bad(k);
        times[k] = v;
      }
      const charged = optional(b.charged_minutes, (v) => Number.isInteger(v) && v >= 0);
      if (charged === undefined) return bad("charged_minutes");
      const redCheck = optional(b.red_check, (v) => textOf(v) !== null);
      if (redCheck === undefined) return bad("red_check");
      const ev = b.evidence_json === undefined ? null : objOf(b.evidence_json);
      if (ev === undefined) return bad("evidence_json");

      return d1Guarded("mr_red_actions", async () => {
        const row = await env.DB.prepare(SQL.byKey).bind(key).first();
        if (!row) return json(404, { error: "no such action", action_key: key });
        const red = times.verified_red_at ?? row.verified_red_at;
        const green = times.verified_green_at ?? row.verified_green_at;
        if (state === "cleared" && (!red || !green)) return json(400, { error: "unverified" });
        const evText = ev === null ? row.evidence_json : JSON.stringify({ ...evidenceOf(row.evidence_json), ...ev });
        if (evText.length > EVIDENCE_MAX) return bad("evidence_json");
        // sql-ident-ok: COLS is a module literal column list; every value binds as ?N
        const out = await env.DB.prepare(
          `UPDATE mr_red_actions SET state = ?2, evidence_json = ?3, verified_red_at = ?4, verified_green_at = ?5,
             green_since = ?6, cleared_at = ?7, returned_at = ?8, charged_minutes = ?9, red_check = ?10, updated_at = ?11
           WHERE action_key = ?1 RETURNING ${COLS}`
        ).bind(key, state ?? row.state, evText, red, green, times.green_since ?? row.green_since,
          times.cleared_at ?? row.cleared_at, times.returned_at ?? row.returned_at,
          charged ?? row.charged_minutes, redCheck ?? row.red_check, t).first();
        if (!out) return json(500, { error: "action_unresolved", action_key: key });
        return json(200, { ok: true, action: actionOut(out) });
      });
    },
  ],

  // ── GET /api/mr-red/actions — the rows, filtered, keyset paged ────────────
  [
    "GET", "/api/mr-red/actions",
    async ({ env, url }) => {
      const q = (k) => url.searchParams.get(k);
      const f = {};
      const checks = { repo: (v) => REPO_RE.test(v), lever: (v) => LEVER_RE.test(v), state: (v) => STATES.has(v),
        fingerprint: (v) => FP_RE.test(v), target: (v) => textOf(v) !== null };
      for (const [k, ok] of Object.entries(checks)) {
        const v = q(k);
        if (v === null) continue;
        if (!ok(v)) return bad(k);
        f[k] = k === "target" ? v.trim() : v;
      }
      const lq = q("limit");
      if (lq !== null && !/^\d{1,4}$/.test(lq)) return bad("limit");
      const limit = lq === null ? PAGE_DEFAULT : Math.min(Number(lq), PAGE_MAX);
      if (limit < 1) return bad("limit");
      const cq = q("cursor");
      let cursor = null;
      if (cq !== null) {
        const m = CURSOR_RE.exec(cq);
        if (!m) return bad("cursor");
        cursor = [m[1], Number(m[2])];
      }

      return d1Guarded("mr_red_actions", async () => {
        const { sql, binds } = listQuery(f, cursor, limit + 1);
        const { results } = await env.DB.prepare(sql).bind(...binds).all();
        const rows = (results || []).slice(0, limit);
        const more = (results || []).length > limit;
        const tail = rows[rows.length - 1];
        return json(200, {
          ok: true, actions: rows.map(actionOut), next_cursor: more && tail ? `${tail.created_at}~${tail.id}` : null,
        });
      });
    },
  ],
];
