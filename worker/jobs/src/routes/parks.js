// parks routes — the D1 copy of the blocked-resolver's candidate rows
// (BH-9075, BH-9067.3; docs/events-bh-9067/3-parks.md).
//
// A park is one (project, ck) row: a pool death or deferral (source queue) or
// a conductor BLOCKED_HUMAN / RED_TWICE (source conductor). Writers send rows
// through PUT /api/parks (bin/lib/parks-write.sh); the resolver reads the
// delta through GET /api/parks/changed (bin/lib/br/opt/parks.sh). The prune
// (GET/POST /api/parks/prune) deletes old done rows, dry run first, one
// retention_runs row per run. Table and indexes: schema.d/202611150806-bh-9075-parks.sql.
//
// Every limit is a settings row (parks.*), read once per request, with the
// code fallback below naming its row. The regexes are input-format rules, not
// knobs: they say what a project, a ck and a source look like.

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

const PROJECT_RE = /^[a-z0-9._-]{1,64}$/;
const CK_RE = /^[A-Za-z0-9._-]{1,200}$/;
const SOURCE_RE = /^[a-z-]{1,24}$/;
const SINCE_RE = /^(\d{1,16})(?::([A-Za-z0-9._-]{1,200}))?$/;
const STATES = new Set(["parked", "hotfix", "done"]);
const TEXT_MAX = 500;
const TEXT_COLS = ["source", "head", "reason", "url", "rec", "ticket", "writer"];

// [key, fallback, min, max]. The fallback is the seed value of the row.
const S_RETENTION_DAYS = ["parks.retention_days", 30, 0, 3650];
const S_RETENTION_BATCH = ["parks.retention_batch", 500, 1, 5000];
const S_PRUNE_DRY_RUN = ["parks.prune_dry_run", 1, 0, 1];
const S_PUT_MAX_ROWS = ["parks.put_max_rows", 100, 1, 1000];
const S_CHANGED_MAX_LIMIT = ["parks.changed_max_limit", 1000, 1, 10000];
const S_HOTFIX_MAX = ["parks.hotfix_max", 50, 1, 1000];

const COLS = "project, ck, source, state, head, reason, url, rec, ticket, updated_at, writer, parked_at";
// keep(col): a '-' on update keeps the stored value.
const keep = (c) => `${c} = CASE WHEN excluded.${c} = '-' THEN parks.${c} ELSE excluded.${c} END`;

// The statements, exported so the EXPLAIN test reads the shipped SQL.
// PUT_SQL: one statement over one bind (?1 = the JSON array of rows); the
// upsert is the PK autoindex. `WHERE true` is SQLite's parse rule for an
// INSERT ... SELECT with ON CONFLICT.
export const PUT_SQL =
  `INSERT INTO parks (${COLS})
   SELECT json_extract(j.value,'$.project'), json_extract(j.value,'$.ck'), json_extract(j.value,'$.source'),
          json_extract(j.value,'$.state'), json_extract(j.value,'$.head'), json_extract(j.value,'$.reason'),
          json_extract(j.value,'$.url'), json_extract(j.value,'$.rec'), json_extract(j.value,'$.ticket'),
          json_extract(j.value,'$.updated_at'), json_extract(j.value,'$.writer'), json_extract(j.value,'$.parked_at')
   FROM json_each(?1) j WHERE true
   ON CONFLICT(project, ck) DO UPDATE SET
     ${["source", "head", "reason", "url", "rec", "ticket"].map(keep).join(",\n     ")},
     state = excluded.state, updated_at = excluded.updated_at, writer = excluded.writer,
     parked_at = COALESCE(excluded.parked_at, parks.parked_at)
   WHERE excluded.updated_at >= parks.updated_at`;
// CHANGED_SQL: idx_parks_project_updated(project, updated_at, ck). ?2 is the
// cursor ts and ?3 the cursor ck (NULL = strict updated_at > ?2).
export const CHANGED_SQL =
  `SELECT ${COLS} FROM parks
   WHERE project = ?1 AND updated_at >= ?2 AND (updated_at > ?2 OR (?3 IS NOT NULL AND ck > ?3))
   ORDER BY updated_at, ck LIMIT ?4`;
// HOTFIX_SQL: idx_parks_state_updated(state, updated_at), state = 'hotfix'.
export const HOTFIX_SQL =
  `SELECT ${COLS} FROM parks
   WHERE state = 'hotfix' AND project = ?1 ORDER BY updated_at LIMIT ?2`;
// PRUNE_IDS_SQL: idx_parks_state_updated, state = 'done' AND updated_at < ?1.
export const PRUNE_IDS_SQL = `SELECT rowid FROM parks WHERE state = 'done' AND updated_at < ?1 ORDER BY updated_at LIMIT ?2`;
const PRUNE_COUNT_SQL = `SELECT COUNT(*) AS n FROM parks WHERE state = 'done' AND updated_at < ?1`;
const PRUNE_DELETE_SQL = `DELETE FROM parks WHERE rowid IN (${PRUNE_IDS_SQL})`;

const obj = (b) => (b && typeof b === "object" && !Array.isArray(b) ? b : null);
const bad = (error) => json(400, { error });
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// settings(env, specs) — one SELECT for the keys; a Map key -> int, each in
// range or its fallback (the shape of retention.js intSetting, kept local).
async function settings(env, specs) {
  const r = await env.DB.prepare(`SELECT key, value FROM settings WHERE key IN (SELECT value FROM json_each(?1))`)
    .bind(JSON.stringify(specs.map((s) => s[0]))).all();
  const byKey = new Map(((r && r.results) || []).map((x) => [x.key, String(x.value).trim()]));
  const out = new Map();
  for (const [key, def, min, max] of specs) {
    const v = byKey.get(key) ?? "";
    const n = /^\d+$/.test(v) ? Number(v) : NaN;
    out.set(key, Number.isSafeInteger(n) && n >= min && n <= max ? n : def);
  }
  return out;
}

// checkRow(r, i) — {error} for a bad row, else {row}. The row has
// a missing text field filled with '-' and a missing parked_at as null.
function checkRow(r, i) {
  const x = obj(r);
  if (!x) return { error: `rows[${i}] must be an object` };
  if (typeof x.project !== "string" || !PROJECT_RE.test(x.project)) return { error: `rows[${i}].project must be 1..64 chars of [a-z0-9._-]` };
  if (typeof x.ck !== "string" || !CK_RE.test(x.ck)) return { error: `rows[${i}].ck must be 1..200 chars of [A-Za-z0-9._-]` };
  if (!STATES.has(x.state)) return { error: `rows[${i}].state must be parked, hotfix or done` };
  if (!Number.isSafeInteger(x.updated_at) || x.updated_at <= 0) return { error: `rows[${i}].updated_at must be an integer > 0` };
  if (x.parked_at !== undefined && x.parked_at !== null && !Number.isSafeInteger(x.parked_at)) {
    return { error: `rows[${i}].parked_at must be null or an integer` };
  }
  const row = { project: x.project, ck: x.ck, state: x.state, updated_at: x.updated_at, parked_at: x.parked_at ?? null };
  for (const c of TEXT_COLS) {
    const v = x[c] === undefined || x[c] === null ? "-" : x[c];
    if (typeof v !== "string" || v.length === 0 || v.length > TEXT_MAX) return { error: `rows[${i}].${c} must be a string of 1..${TEXT_MAX} chars` };
    row[c] = v;
  }
  if (row.source !== "-" && !SOURCE_RE.test(row.source)) return { error: `rows[${i}].source must be '-' or 1..24 chars of [a-z-]` };
  return { row };
}

const shape = (r) => ({
  project: r.project, ck: r.ck, source: r.source, state: r.state, head: r.head, reason: r.reason,
  url: r.url, rec: r.rec, ticket: r.ticket, updated_at: Number(r.updated_at), writer: r.writer,
  parked_at: r.parked_at === null || r.parked_at === undefined ? null : Number(r.parked_at),
});

// prune(env, t, askDry) — one count or one batched delete, then ONE
// retention_runs row. A body can ask for a dry run; it can never force a real
// one (parks.prune_dry_run=1 wins).
async function prune(env, t, askDry) {
  const s = await settings(env, [S_RETENTION_DAYS, S_RETENTION_BATCH, S_PRUNE_DRY_RUN]);
  const days = s.get(S_RETENTION_DAYS[0]);
  const batch = s.get(S_RETENTION_BATCH[0]);
  const dryRun = askDry || s.get(S_PRUNE_DRY_RUN[0]) === 1;
  const started = iso(Date.now());
  const nowS = Math.floor(Date.parse(t) / 1000);
  const runId = `parks-${t}`;
  let cutoff = null, counted = 0, removed = 0, error = null;
  await ensureTable(env, "parks");
  if (days === 0) {
    error = "off";
  } else {
    const cut = nowS - days * 86400;
    cutoff = iso(cut * 1000);
    try {
      if (dryRun) {
        counted = Number((await env.DB.prepare(PRUNE_COUNT_SQL).bind(cut).first("n")) || 0);
      } else {
        const r = await env.DB.prepare(PRUNE_DELETE_SQL).bind(cut, batch).run();
        removed = Number((r && r.meta && r.meta.changes) || 0);
        counted = removed;
      }
    } catch (e) {
      error = String((e && e.message) || e).slice(0, 200);
    }
  }
  const backlog = removed === batch;
  await ensureTable(env, "retention_runs");
  await env.DB.prepare(
    `INSERT INTO retention_runs (run_id, rule, tbl, dry_run, cutoff, counted, removed, rolled_up, backlog, error, started_at, finished_at)
     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)`
  ).bind(runId, "parks.done", "parks", dryRun ? 1 : 0, cutoff, counted, removed, 0, backlog ? 1 : 0, error, started, iso(Date.now())).run();
  const out = { run_id: runId, dry_run: dryRun, counted, removed, backlog };
  if (error && error !== "off") return json(503, { ...out, error });
  return json(200, out);
}

export const routes = [
  // ── PUT /api/parks {rows:[...]} ─────────────────────────────────────────
  // Every row is checked before any statement. One write statement for the
  // whole batch. `upserted` is meta.changes: a row an older write lost to is
  // not counted.
  [
    "PUT", "/api/parks",
    ({ env, t, body }) => d1Guarded("parks", async () => {
      const b = obj(body);
      if (!b || !Array.isArray(b.rows)) return bad("body must be {rows:[...]}");
      const s = await settings(env, [S_PUT_MAX_ROWS]);
      const max = s.get(S_PUT_MAX_ROWS[0]);
      if (b.rows.length < 1 || b.rows.length > max) return bad(`rows must hold 1..${max} rows`);
      const rows = [];
      for (let i = 0; i < b.rows.length; i++) {
        const c = checkRow(b.rows[i], i);
        if (c.error) return bad(c.error);
        rows.push(c.row);
      }
      await ensureTable(env, "parks");
      const r = await env.DB.prepare(PUT_SQL).bind(JSON.stringify(rows)).run();
      return json(200, { upserted: Number((r && r.meta && r.meta.changes) || 0), as_of: t });
    }),
  ],

  // ── GET /api/parks/changed?project=&since=&limit=&hotfix=1 ─────────────
  // since is <ts> (strict updated_at > ts) or the keyset token <ts>:<ck>.
  // Every state is returned, done included (the client mirror removes it).
  // hotfix=1 adds the project's hotfix rows, whatever the cursor, read in
  // parallel with the page.
  [
    "GET", "/api/parks/changed",
    ({ env, t, url }) => d1Guarded("parks", async () => {
      const q = url.searchParams;
      const project = q.get("project");
      if (!project || !PROJECT_RE.test(project)) return bad("project must be 1..64 chars of [a-z0-9._-]");
      const since = q.get("since");
      const m = since === null ? null : SINCE_RE.exec(since);
      if (!m || !Number.isSafeInteger(Number(m[1]))) return bad("since must be <ts> or <ts>:<ck>");
      const ts = Number(m[1]);
      const ck = m[2] ?? null;
      const s = await settings(env, [S_CHANGED_MAX_LIMIT, S_HOTFIX_MAX]);
      const maxLimit = s.get(S_CHANGED_MAX_LIMIT[0]);
      let limit = maxLimit;
      const lq = q.get("limit");
      if (lq !== null) {
        if (!/^\d{1,6}$/.test(lq) || Number(lq) < 1 || Number(lq) > maxLimit) return bad(`limit must be 1..${maxLimit}`);
        limit = Number(lq);
      }
      const withHotfix = q.get("hotfix") === "1";
      await ensureTable(env, "parks");
      const page = env.DB.prepare(CHANGED_SQL).bind(project, ts, ck, limit).all();
      const hot = withHotfix
        ? env.DB.prepare(HOTFIX_SQL).bind(project, s.get(S_HOTFIX_MAX[0])).all()
        : Promise.resolve(null);
      const [p, h] = await Promise.all([page, hot]);
      const rows = ((p && p.results) || []).map(shape);
      const last = rows[rows.length - 1];
      const out = { rows };
      if (withHotfix) out.hotfix = ((h && h.results) || []).map(shape);
      out.next = last ? `${last.updated_at}:${last.ck}` : since;
      out.truncated = rows.length === limit;
      out.as_of = t;
      return json(200, out);
    }),
  ],

  // ── GET /api/parks/prune ─ always a dry run ─────────────────────────────
  [
    "GET", "/api/parks/prune",
    ({ env, t }) => d1Guarded("parks", () => prune(env, t, true)),
  ],

  // ── POST /api/parks/prune {dry_run?} ───────────────────────────────────
  [
    "POST", "/api/parks/prune",
    ({ env, t, body }) => d1Guarded("parks", () => prune(env, t, !!(body && body.dry_run === true))),
  ],
];
