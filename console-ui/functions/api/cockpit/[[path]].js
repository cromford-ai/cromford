// Cloudflare Pages Function: /api/cockpit/* -> the console worker's own D1.
//
// This is the port of the three old-cockpit views Mission Control never had:
//
//   /            "Now · Harness"  -> /api/cockpit/now
//   /history     past runs        -> /api/cockpit/history  (+ /history/builds)
//   /needs       needs a human    -> /api/cockpit/needs
//   /p/<project> the deep half    -> /api/cockpit/project/<name>
//
// WHY D1 AND NOT A PROXY — the same answer functions/api/ideas/ gives, re-checked
// for these routes: the console worker server-renders them as HTML and exposes no
// JSON for them. Probed off-cookie, /history and /needs answer 403 (a real route,
// refusing the session) while /api/dash/history, /api/dash/needs, /api/dash/runs
// and /api/dash/events all answer 404 (no such route) — so there is nothing to
// forward to. Scraping the HTML would be a data source nobody could change
// safely, and the worker is not ours to extend from here, so this reads the rows
// the worker's own beats already wrote. Reads only: every statement is a SELECT.
//
// AUTHORISATION IS DELEGATED, ON PURPOSE — same rule as coord/ and ideas/. The
// `dash` cookie is minted and validated by the console worker; this function
// never learns its shape. The incoming cookie is presented to the worker's own
// authed endpoint and only a 200 buys the read, so there is one definition of
// "signed in" and rotating DASH_SECRET revokes this in the same moment.
// (Inlined rather than shared, matching ideas/: a Pages Function that imports
// across the functions/ tree is a build-time risk taken for 20 lines, and the
// two live copies are on production paths this branch should not touch.)
//
// Binding this needs (Pages project -> Settings -> Bindings -> D1):
//   CONSOLE_DB -> harness-console-db
// Without it every call answers 503 saying that, rather than 401ing as though
// the operator were signed out.

const CONSOLE = 'https://harness-console.operator.workers.dev';
const AUTH_PROBE = '/api/dash/fleet';

const seen = new Map();
const TTL_MS = 60000;

async function signedIn(cookie) {
  if (!cookie) return false;
  const now = Date.now();
  const hit = seen.get(cookie);
  if (hit && now - hit.at < TTL_MS) return hit.ok;
  let ok = false;
  try {
    const res = await fetch(CONSOLE + AUTH_PROBE, { headers: { cookie }, redirect: 'manual' });
    ok = res.status === 200;
  } catch {
    // The console being unreachable is NOT a grant. It fails closed.
    ok = false;
  }
  seen.set(cookie, { ok, at: now });
  return ok;
}

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
  });

// Project names arrive from the URL and from query strings, so they are
// untrusted: refuse anything outside the character set fleet.conf itself mints
// rather than sanitising it into something that still queries.
const SAFE = /^[A-Za-z0-9._-]+$/;

// `Number(null)` is 0, not NaN — so an absent parameter has to be checked for
// BEFORE it is coerced, or every unparameterised list clamps to one row. It did:
// /now answered with a single run and a single event until this was fixed.
const clampLimit = (raw, fallback, max) => {
  if (raw === null || raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(Math.max(Math.trunc(n), 1), max);
};

// A cursor is an id, and an id we cannot read is not "page 1" — it is a bad
// request. Silently ignoring it would replay the first page forever.
const cursorFrom = (raw) => {
  if (raw === null || raw === undefined || raw === '') return null;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return undefined;
  return Math.trunc(n);
};

// The event log is 87% `flags` rows (one per flag scrape, ~193k of 221k) plus
// the raw webhook and fleet_status beats. An activity feed made of those is a
// feed of nothing, so the noisy types are excluded at the query rather than
// fetched and thrown away in the browser.
// Every needs list is capped at the same number, so one constant says how far
// the table can be trusted to be the whole story.
const LIST_CAP = 200;

const FEED_NOISE = ['flags', 'fleet_status', 'webhook'];

// `stale` is the sweep's own terminal stage for a build nobody finished.
// `superseded`/`abandoned`: a PR the blocked-resolver closed unmerged (BH-389).
// `pr_closed`: BH-3971: reconcile's closed-unmerged terminal (HC-36/BH-866).
const TERMINAL_STAGES = ['pr_merged', 'tier2_sweep_merged', 'stale', 'superseded', 'abandoned', 'pr_closed'];
// Stopped, not progressing: these are the stages that ask for a human.
const PARKED_STAGES = ['plan_blocked', 'plan_deferred', 'plan_stale', 'plan_malformed'];
// A build waiting on a merge is waiting on a person too, so `pr_created` joins
// the parked stages on NEEDS.
const NEEDS_STAGES = [...PARKED_STAGES, 'pr_created'];
// What is left, neither finished nor waiting, is the UNFINISHED build rows. They
// are not "building now": rows are never closed when a build is abandoned,
// parked, superseded or restarted (BH-3479 read "planning 40m" after
// ABANDONED, TK-3355 appeared twice, and the tile said 60 against 11 running
// jobs). Whether one is building is decided by the jobs ledger, joined in the
// browser (lib/cockpit.js buildingNow/staleBuilds); a row with no running job
// is shown on NEEDS as stale.
const MOVING_EXCLUDE = [...TERMINAL_STAGES, ...NEEDS_STAGES];

async function now(db, url) {
  const feedLimit = clampLimit(url.searchParams.get('events'), 40, 200);
  const runLimit = clampLimit(url.searchParams.get('runs'), 25, 200);

  const boards = await db
    .prepare(`SELECT project, paused, automerge, last_run_at, last_rc, last_summary,
      disk, mem, updated_at FROM boards ORDER BY project`)
    .all();

  const unfinished = await db
    .prepare(`SELECT id, bkey, project, ticket_key, stage, tier, verdict, pr_url, merged, updated_at
      FROM builds
      WHERE merged = 0 AND stage NOT IN (${MOVING_EXCLUDE.map(() => '?').join(',')})
      ORDER BY updated_at DESC LIMIT ${LIST_CAP}`)
    .bind(...MOVING_EXCLUDE)
    .all();
  const unfinishedRows = unfinished.results || [];

  const recentRuns = await db
    .prepare(`SELECT id, rkey, project, kind, rc, summary, started_at, finished_at
      FROM runs ORDER BY id DESC LIMIT ?`)
    .bind(runLimit)
    .all();

  const feed = await db
    .prepare(`SELECT id, ts, project, type, detail FROM events
      WHERE type NOT IN (${FEED_NOISE.map(() => '?').join(',')})
      ORDER BY id DESC LIMIT ?`)
    .bind(...FEED_NOISE, feedLimit)
    .all();

  const counts = await needCounts(db);

  return json({
    boards: boards.results || [],
    // Unfinished build rows (the name predates the jobs join). Capped at
    // LIST_CAP, and the payload says when the cap is what ended the list.
    active_builds: unfinishedRows,
    active_builds_truncated: unfinishedRows.length === LIST_CAP,
    recent_runs: recentRuns.results || [],
    events: feed.results || [],
    // The feed is filtered, so it says which types it dropped rather than
    // letting an operator read it as "everything that happened".
    events_excluding: FEED_NOISE,
    needs: counts,
    generated_at: new Date().toISOString()
  });
}

// One build row per ticket: the newest (highest id) row of each (project,
// ticket_key). A ticket is a parked build only when that newest row is parked
// or pr_created; older attempts behind it never count. A row with no ticket key
// is its own group. The subquery is not correlated (SQLite runs it once as a
// LIST SUBQUERY) and carries no project scope: MAX(id) per (project, ticket) is
// the same answer scoped or not, so the binds stay as they were.
const NEWEST_PER_TICKET = `id IN (SELECT MAX(id) FROM builds GROUP BY project,
  CASE WHEN ticket_key IS NULL OR ticket_key = '' THEN 'id:' || id ELSE ticket_key END)`;

// The counts must be scoped to whatever the lists are scoped to. A strip
// reporting 229 fleet-wide items above a table showing 9 for one project is a
// screen contradicting itself, and the bigger number is the one people read.
// The builds number is tickets, not rows (NEWEST_PER_TICKET).
async function needCounts(db, project = null) {
  const scope = project ? ' AND project = ?' : '';
  const row = await db
    .prepare(`SELECT
      (SELECT COUNT(*) FROM alerts WHERE resolved = 0${scope}) AS alerts,
      (SELECT COUNT(*) FROM commands WHERE status IN ('dead_letter','failed')${scope}) AS commands,
      (SELECT COUNT(*) FROM builds WHERE merged = 0 AND stage IN (${NEEDS_STAGES.map(() => '?').join(',')})${scope}
        AND ${NEWEST_PER_TICKET}) AS builds,
      (SELECT COUNT(*) FROM proposals WHERE status = 'gate_pending'${scope}) AS proposals`)
    .bind(...(project ? [project] : []), ...(project ? [project] : []),
      ...NEEDS_STAGES, ...(project ? [project] : []), ...(project ? [project] : []))
    .first();
  const n = (v) => Number(v || 0);
  const c = {
    alerts: n(row && row.alerts),
    commands: n(row && row.commands),
    builds: n(row && row.builds),
    proposals: n(row && row.proposals)
  };
  c.total = c.alerts + c.commands + c.builds + c.proposals;
  return c;
}

// Everything on this route is something a person has to decide or unstick. It
// is four different questions, so it answers as four lists rather than one
// flattened stream that would have to invent a shared shape.
async function needs(db, url) {
  const project = url.searchParams.get('project');
  if (project && !SAFE.test(project)) return json({ error: 'bad project' }, 400);
  const projClause = (col) => (project ? ` AND ${col} = ?` : '');
  const projBind = project ? [project] : [];

  const alerts = await db
    .prepare(`SELECT id, akey, ts, project, line FROM alerts
      WHERE resolved = 0${projClause('project')} ORDER BY id DESC LIMIT ${LIST_CAP}`)
    .bind(...projBind)
    .all();

  const commands = await db
    .prepare(`SELECT id, ckey, type, project, status, attempts, result, created_at, updated_at
      FROM commands WHERE status IN ('dead_letter','failed')${projClause('project')}
      ORDER BY id DESC LIMIT ${LIST_CAP}`)
    .bind(...projBind)
    .all();

  const builds = await db
    .prepare(`SELECT id, bkey, project, ticket_key, stage, tier, verdict, pr_url, merged, updated_at
      FROM builds
      WHERE merged = 0 AND stage IN (${NEEDS_STAGES.map(() => '?').join(',')})${projClause('project')}
        AND ${NEWEST_PER_TICKET}
      ORDER BY updated_at DESC LIMIT ${LIST_CAP}`)
    .bind(...NEEDS_STAGES, ...projBind)
    .all();

  // The same unfinished rows /now reads; the screen joins them against the jobs
  // ledger and lists the ones with no running job as stale.
  const unfinished = await db
    .prepare(`SELECT id, bkey, project, ticket_key, stage, tier, verdict, pr_url, merged, updated_at
      FROM builds
      WHERE merged = 0 AND stage NOT IN (${MOVING_EXCLUDE.map(() => '?').join(',')})${projClause('project')}
      ORDER BY updated_at DESC LIMIT ${LIST_CAP}`)
    .bind(...MOVING_EXCLUDE, ...projBind)
    .all();

  const proposals = await db
    .prepare(`SELECT pkey, project, slug, title, summary, score, status, updated_at
      FROM proposals WHERE status = 'gate_pending'${projClause('project')}
      ORDER BY score DESC LIMIT ${LIST_CAP}`)
    .bind(...projBind)
    .all();

  return json({
    project: project || null,
    alerts: alerts.results || [],
    commands: commands.results || [],
    builds: builds.results || [],
    proposals: proposals.results || [],
    unfinished_builds: unfinished.results || [],
    counts: await needCounts(db, project),
    // Each list is capped at 200. When the cap is what ended it, the counts are
    // the truth and the table is a slice — the screen has to be able to say so.
    truncated: {
      alerts: (alerts.results || []).length === LIST_CAP,
      commands: (commands.results || []).length === LIST_CAP,
      builds: (builds.results || []).length === LIST_CAP,
      proposals: (proposals.results || []).length === LIST_CAP,
      unfinished_builds: (unfinished.results || []).length === LIST_CAP
    },
    generated_at: new Date().toISOString()
  });
}

// Cursor pagination on the id, never OFFSET: `runs` grows by ~250 rows a day and
// an OFFSET page re-reads everything above it.
async function history(db, url) {
  const where = ['1=1'];
  const binds = [];
  const project = url.searchParams.get('project');
  const kind = url.searchParams.get('kind');
  const outcome = url.searchParams.get('outcome');
  if (project) {
    if (!SAFE.test(project)) return json({ error: 'bad project' }, 400);
    where.push('project = ?'); binds.push(project);
  }
  if (kind) {
    if (!SAFE.test(kind)) return json({ error: 'bad kind' }, 400);
    where.push('kind = ?'); binds.push(kind);
  }
  if (outcome === 'ok') where.push('rc = 0');
  else if (outcome === 'failed') where.push('(rc IS NULL OR rc <> 0)');
  else if (outcome) return json({ error: 'outcome must be ok or failed' }, 400);

  const before = cursorFrom(url.searchParams.get('before'));
  if (before === undefined) return json({ error: 'before must be a run id' }, 400);
  const limit = clampLimit(url.searchParams.get('limit'), 100, 500);

  const pageWhere = where.slice();
  const pageBinds = binds.slice();
  if (before !== null) { pageWhere.push('id < ?'); pageBinds.push(before); }

  const rows = await db
    .prepare(`SELECT id, rkey, project, kind, rc, summary, started_at, finished_at
      FROM runs WHERE ${pageWhere.join(' AND ')} ORDER BY id DESC LIMIT ?`)
    .bind(...pageBinds, limit)
    .all();
  const results = rows.results || [];

  // The total is for the FILTER, not the table: a filtered page that reported
  // the whole ledger's size would misstate how much is left to page through.
  const totalRow = await db
    .prepare(`SELECT COUNT(*) AS n, SUM(CASE WHEN rc = 0 THEN 0 ELSE 1 END) AS failed
      FROM runs WHERE ${where.join(' AND ')}`)
    .bind(...binds)
    .first();

  return json({
    runs: results,
    total: Number((totalRow && totalRow.n) || 0),
    failed: Number((totalRow && totalRow.failed) || 0),
    // A full page is not proof there is another one, but it is the only honest
    // "there may be more"; the next call settles it.
    next_cursor: results.length === limit ? results[results.length - 1].id : null,
    generated_at: new Date().toISOString()
  });
}

async function buildHistory(db, url) {
  const where = ['1=1'];
  const binds = [];
  const project = url.searchParams.get('project');
  if (project) {
    if (!SAFE.test(project)) return json({ error: 'bad project' }, 400);
    where.push('project = ?'); binds.push(project);
  }
  const before = cursorFrom(url.searchParams.get('before'));
  if (before === undefined) return json({ error: 'before must be a build id' }, 400);
  const limit = clampLimit(url.searchParams.get('limit'), 100, 500);

  const pageWhere = where.slice();
  const pageBinds = binds.slice();
  if (before !== null) { pageWhere.push('id < ?'); pageBinds.push(before); }

  const rows = await db
    .prepare(`SELECT id, bkey, project, ticket_key, stage, tier, verdict, pr_url, merged, updated_at
      FROM builds WHERE ${pageWhere.join(' AND ')} ORDER BY id DESC LIMIT ?`)
    .bind(...pageBinds, limit)
    .all();
  const results = rows.results || [];

  const totalRow = await db
    .prepare(`SELECT COUNT(*) AS n, SUM(merged) AS merged FROM builds WHERE ${where.join(' AND ')}`)
    .bind(...binds)
    .first();

  return json({
    builds: results,
    total: Number((totalRow && totalRow.n) || 0),
    merged: Number((totalRow && totalRow.merged) || 0),
    next_cursor: results.length === limit ? results[results.length - 1].id : null,
    generated_at: new Date().toISOString()
  });
}

// The half of the old per-project page Mission Control does not already render
// from /api/dash/p/<project>: the whole-ledger totals behind the last 20 rows,
// and the company map — a 17KB per-project brief that lives only in this D1 and
// has never had a screen.
async function project(db, name) {
  const board = await db
    .prepare(`SELECT project, paused, automerge, last_run_at, last_rc, last_summary,
      disk, mem, updated_at FROM boards WHERE project = ?`)
    .bind(name)
    .first();

  const runStats = await db
    .prepare(`SELECT COUNT(*) AS runs,
      SUM(CASE WHEN rc = 0 THEN 0 ELSE 1 END) AS failed,
      MIN(started_at) AS first_run_at, MAX(started_at) AS last_run_at
      FROM runs WHERE project = ?`)
    .bind(name)
    .first();

  const byKind = await db
    .prepare('SELECT kind, COUNT(*) AS n FROM runs WHERE project = ? GROUP BY kind ORDER BY n DESC')
    .bind(name)
    .all();

  const byStage = await db
    .prepare('SELECT stage, COUNT(*) AS n FROM builds WHERE project = ? GROUP BY stage ORDER BY n DESC')
    .bind(name)
    .all();

  const map = await db
    .prepare('SELECT project, content, updated_at, length(content) AS bytes FROM company_maps WHERE project = ?')
    .bind(name)
    .first();

  // `board` is null for a name that never beat: that is "no such project here",
  // and it must not read as a project with zero of everything.
  if (!board && Number((runStats && runStats.runs) || 0) === 0 && !map) {
    return json({ error: `no rows for project ${name}` }, 404);
  }

  return json({
    project: name,
    board: board || null,
    run_stats: {
      runs: Number((runStats && runStats.runs) || 0),
      failed: Number((runStats && runStats.failed) || 0),
      first_run_at: (runStats && runStats.first_run_at) || null,
      last_run_at: (runStats && runStats.last_run_at) || null,
      by_kind: byKind.results || []
    },
    build_stats: { by_stage: byStage.results || [] },
    company_map: map || null,
    generated_at: new Date().toISOString()
  });
}

export async function onRequest(context) {
  const { request, env, params } = context;
  const url = new URL(request.url);

  if (!env.CONSOLE_DB) {
    return json({
      error: 'CONSOLE_DB is not bound on this Pages project — the NOW / HISTORY / NEEDS views have no harness database to read (bind D1 harness-console-db as CONSOLE_DB)'
    }, 503);
  }

  const cookie = request.headers.get('cookie') || '';
  if (!(await signedIn(cookie))) {
    // The same shape src/api.js already treats as "not signed in".
    return json({ error: 'unauthorized' }, 403);
  }

  // Read-only by construction: pausing a board, resuming it and forcing a
  // triage still go through /api/dash/action, which mints a `commands` row the
  // boxes claim. Nothing here writes, so nothing here can mint one.
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return json({ error: `method ${request.method} not allowed on /api/cockpit — these views are read-only` }, 405);
  }

  const parts = (Array.isArray(params.path) ? params.path : [params.path || ''])
    .filter((s) => s !== undefined && s !== null && s !== '');

  try {
    if (parts.length === 1 && parts[0] === 'now') return await now(env.CONSOLE_DB, url);
    if (parts.length === 1 && parts[0] === 'needs') return await needs(env.CONSOLE_DB, url);
    if (parts.length === 1 && parts[0] === 'history') return await history(env.CONSOLE_DB, url);
    if (parts.length === 2 && parts[0] === 'history' && parts[1] === 'builds') {
      return await buildHistory(env.CONSOLE_DB, url);
    }
    if (parts.length === 2 && parts[0] === 'project') {
      if (!SAFE.test(parts[1])) return json({ error: 'bad project' }, 400);
      return await project(env.CONSOLE_DB, parts[1]);
    }
    return json({ error: `no such cockpit route: /api/cockpit/${parts.join('/')}` }, 404);
  } catch (e) {
    // A D1 error is the database's answer, not a signed-out answer: keep them
    // distinguishable or the screen tells the operator to log in again forever.
    return json({ error: `harness database read failed — ${e && e.message ? e.message : 'unknown error'}` }, 502);
  }
}
