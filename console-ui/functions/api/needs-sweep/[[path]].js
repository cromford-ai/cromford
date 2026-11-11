// Cloudflare Pages Function: /api/needs-sweep/* — the hub's read and write path
// for closing parked build rows nobody closes (BH-9117).
//
// A builds row stays in a parked stage (plan_blocked, plan_deferred, plan_stale,
// plan_malformed) or in pr_created forever: no lane moves it when the ticket is
// rebuilt, merged or closed, and the stale sweep's feed takes non-parked stages
// only. bin/needs-sweep.sh (a daily hub lane) decides per row, from GitHub and
// the rows themselves, and closes what it decided through here. The write goes
// through the console's own CONSOLE_DB binding, so the hub keeps no D1 access
// (BH-3905), the same pattern as merge-pr/release.js (BH-4917).
//
// Machine-to-machine: the caller presents `Bearer <HARNESS_SECRET>`. No dash
// cookie buys this.
//
//   GET  /api/needs-sweep/candidates?after=<id>&limit=<n>
//        {rows:[{id,bkey,project,ticket_key,stage,pr_url,updated_at,newest_id}], next_after, done}
//        merged=0 rows in a NEEDS stage, by id. newest_id is the highest id of
//        the same project + ticket_key (null for a row with no ticket key).
//   POST /api/needs-sweep/apply
//        {apply, builds:[{id,to,updated_at,why}], commands_before:<ISO Z>|null}
//        -> {ok, apply, builds:{asked, changed}, commands:{changed}}
//        Each build UPDATE is guarded: still merged=0, still in a NEEDS stage,
//        and updated_at still the value the hub read. apply:false counts the
//        rows the same WHERE matches and writes nothing. `changed` is D1's
//        meta.changes, never the ask.
//   GET  /api/needs-sweep/count
//        {ok, needs:{alerts,commands,builds,proposals,total}, generated_at}
//        The NEEDS count Mission Control NOW shows (_lib/needs-count.js
//        needCounts), fleet-wide, in ONE statement. The clerk staff agent's
//        metric (bin/staff/clerk-lever.sh, BH-9420).
//
// Env (Pages project -> Settings): HARNESS_SECRET, CONSOLE_DB. Either missing
// answers 503 naming it. Optional knobs: NEEDS_SWEEP_PAGE_MAX (fallback 500),
// NEEDS_SWEEP_APPLY_MAX (fallback 100).

// The same NEEDS stages and the same count the cockpit shows on NOW (BH-9420).
import { NEEDS_STAGES, needCounts } from '../../_lib/needs-count.js';

const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
  });

// The terminal stages a sweep may write. All four are already terminal on
// every screen (cockpit TERMINAL_STAGES, lib/stages.js).
const TARGETS = { superseded: 0, stale: 0, pr_merged: 1, pr_closed: 0 };
// Transport bounds of this endpoint. Knobs: env NEEDS_SWEEP_PAGE_MAX (rows per
// candidates page) and NEEDS_SWEEP_APPLY_MAX (builds per apply call) on the
// Pages project; a missing or non-positive value is the fallback below. The
// rows-per-run and reads-per-run limits are settings rows the hub lane reads
// (console.needs.sweep_max_rows, console.needs.sweep_max_reads).
const PAGE_MAX_FALLBACK = 500;  // fallback; env NEEDS_SWEEP_PAGE_MAX
const APPLY_MAX_FALLBACK = 100; // fallback; env NEEDS_SWEEP_APPLY_MAX
const envWhole = (env, name, fallback) => {
  const raw = env && env[name] !== undefined && env[name] !== null ? String(env[name]).trim() : '';
  return /^\d+$/.test(raw) && Number(raw) > 0 ? Number(raw) : fallback;
};

const IN_NEEDS = NEEDS_STAGES.map(() => '?').join(',');
// A time column as epoch seconds. An unparseable text is NULL and never
// matches, and an INTEGER is never compared against TEXT.
const epochOf = (col) =>
  `(CASE typeof(${col}) WHEN 'integer' THEN ${col} WHEN 'real' THEN ${col} ELSE CAST(strftime('%s', ${col}) AS INTEGER) END)`;
const CMD_WHERE = `status = 'dead_letter' AND ${epochOf('COALESCE(updated_at, created_at)')} < ?`;

function sameSecret(sent, want) {
  if (typeof sent !== 'string' || sent.length !== want.length) return false;
  let d = 0;
  for (let i = 0; i < want.length; i++) d |= sent.charCodeAt(i) ^ want.charCodeAt(i);
  return d === 0;
}

const wholeOrNull = (raw) => {
  if (raw === null || raw === undefined || raw === '') return null;
  if (!/^\d+$/.test(String(raw))) return undefined;
  return Number(raw);
};

async function candidates(db, url, pageMax) {
  const after = wholeOrNull(url.searchParams.get('after'));
  if (after === undefined) return json(400, { error: 'after must be a whole number' });
  const lim = wholeOrNull(url.searchParams.get('limit'));
  if (lim === undefined) return json(400, { error: 'limit must be a whole number' });
  const limit = Math.min(Math.max(lim === null ? pageMax : lim, 1), pageMax);
  const r = await db
    .prepare(`SELECT b.id, b.bkey, b.project, b.ticket_key, b.stage, b.pr_url, b.updated_at, t.top AS newest_id
      FROM builds b
      LEFT JOIN (SELECT project, ticket_key, MAX(id) AS top FROM builds
        WHERE ticket_key IS NOT NULL AND ticket_key <> '' GROUP BY project, ticket_key) t
        ON t.project = b.project AND t.ticket_key = b.ticket_key
      WHERE b.merged = 0 AND b.stage IN (${IN_NEEDS}) AND b.id > ?
      ORDER BY b.id LIMIT ?`)
    .bind(...NEEDS_STAGES, after === null ? 0 : after, limit)
    .all();
  const rows = r.results || [];
  return json(200, {
    rows,
    next_after: rows.length ? rows[rows.length - 1].id : (after === null ? 0 : after),
    done: rows.length < limit
  });
}

const ISO_Z = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

function readApply(body, applyMax) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: 'body must be a JSON object' };
  if (typeof body.apply !== 'boolean') return { error: 'apply must be true or false' };
  const list = body.builds === undefined ? [] : body.builds;
  if (!Array.isArray(list)) return { error: 'builds must be an array' };
  if (list.length > applyMax) return { error: `at most ${applyMax} builds per call` };
  const builds = [];
  for (const b of list) {
    if (!b || typeof b !== 'object') return { error: 'each build must be an object' };
    if (!Number.isInteger(b.id) || b.id < 1) return { error: 'each build needs a positive whole id' };
    if (!Object.prototype.hasOwnProperty.call(TARGETS, b.to)) {
      return { error: `to must be one of ${Object.keys(TARGETS).join(', ')} (got ${JSON.stringify(b.to)})` };
    }
    if (b.updated_at !== null && typeof b.updated_at !== 'string' && typeof b.updated_at !== 'number') {
      return { error: 'each build needs the updated_at it was read with' };
    }
    builds.push({ id: b.id, to: b.to, updated_at: b.updated_at });
  }
  let before = null;
  if (body.commands_before !== undefined && body.commands_before !== null) {
    if (typeof body.commands_before !== 'string' || !ISO_Z.test(body.commands_before)) {
      return { error: 'commands_before must be an ISO UTC time (…Z) or null' };
    }
    before = Math.floor(Date.parse(body.commands_before) / 1000);
    if (!Number.isFinite(before)) return { error: 'commands_before is not a real time' };
  }
  return { apply: body.apply, builds, before };
}

const GUARD = `id = ? AND merged = 0 AND stage IN (${IN_NEEDS}) AND updated_at IS ?`;

async function apply(db, request, applyMax) {
  let body = null;
  try { body = JSON.parse(await request.text()); } catch { body = null; }
  const a = readApply(body, applyMax);
  if (a.error) return json(400, { error: a.error });

  let changed = 0;
  let commands = 0;
  if (a.apply) {
    const stmts = a.builds.map((b) => db
      .prepare(`UPDATE builds SET stage = ?, merged = ? WHERE ${GUARD}`)
      .bind(b.to, TARGETS[b.to], b.id, ...NEEDS_STAGES, b.updated_at));
    if (stmts.length) {
      const res = await db.batch(stmts);
      for (const r of res || []) changed += Number((r && r.meta && r.meta.changes) || 0);
    }
    if (a.before !== null) {
      const r = await db.prepare(`UPDATE commands SET status = 'expired' WHERE ${CMD_WHERE}`).bind(a.before).run();
      commands = Number((r && r.meta && r.meta.changes) || 0);
    }
  } else {
    // A dry run asks the same WHERE and writes nothing.
    const stmts = a.builds.map((b) => db
      .prepare(`SELECT COUNT(*) AS n FROM builds WHERE ${GUARD}`)
      .bind(b.id, ...NEEDS_STAGES, b.updated_at));
    if (stmts.length) {
      const res = await db.batch(stmts);
      for (const r of res || []) changed += Number((r && r.results && r.results[0] && r.results[0].n) || 0);
    }
    if (a.before !== null) {
      const r = await db.prepare(`SELECT COUNT(*) AS n FROM commands WHERE ${CMD_WHERE}`).bind(a.before).first();
      commands = Number((r && r.n) || 0);
    }
  }
  return json(200, { ok: true, apply: a.apply, builds: { asked: a.builds.length, changed }, commands: { changed: commands } });
}

export async function onRequest(context) {
  const { request, env, params } = context;
  const secret = typeof (env && env.HARNESS_SECRET) === 'string' ? env.HARNESS_SECRET.trim() : '';
  if (!secret) {
    return json(503, { error: 'HARNESS_SECRET is not set on this Pages project — the hub cannot sweep NEEDS rows' });
  }
  const auth = (request.headers.get('authorization') || '').trim();
  if (!auth.startsWith('Bearer ') || !sameSecret(auth.slice(7).trim(), secret)) {
    return json(401, { error: 'unauthorized' });
  }
  if (!env.CONSOLE_DB) {
    return json(503, { error: 'CONSOLE_DB is not bound on this Pages project — bind D1 harness-console-db as CONSOLE_DB' });
  }
  const parts = (Array.isArray(params && params.path) ? params.path : [(params && params.path) || ''])
    .filter((s) => s !== undefined && s !== null && s !== '');
  const route = parts.join('/');
  try {
    if (route === 'candidates') {
      if (request.method !== 'GET') return json(405, { error: `method ${request.method} not allowed on candidates` });
      return await candidates(env.CONSOLE_DB, new URL(request.url), envWhole(env, 'NEEDS_SWEEP_PAGE_MAX', PAGE_MAX_FALLBACK));
    }
    if (route === 'apply') {
      if (request.method !== 'POST') return json(405, { error: `method ${request.method} not allowed on apply` });
      return await apply(env.CONSOLE_DB, request, envWhole(env, 'NEEDS_SWEEP_APPLY_MAX', APPLY_MAX_FALLBACK));
    }
    if (route === 'count') {
      if (request.method !== 'GET') return json(405, { error: `method ${request.method} not allowed on count` });
      const needs = await needCounts(env.CONSOLE_DB);
      return json(200, { ok: true, needs, generated_at: new Date().toISOString() });
    }
    return json(404, { error: `no such route: /api/needs-sweep/${route}` });
  } catch (e) {
    return json(502, { error: `harness database call failed — ${e && e.message ? e.message : 'unknown error'}` });
  }
}
