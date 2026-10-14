// worker/jobs/test/lib/d1-volume.bh-6727.js — a node:sqlite D1 seeded at the
// live row counts of 2026-10-14 17:05Z (BH-6727), for EXPLAIN QUERY PLAN tests.
// Live: wakes 206,176; cost_rows 95,272; jobs 49,170; job_heartbeats 46,459;
// ledgers 26,520. Sizes scale with VOLUME_SCALE (default 1) so a quick local
// run can shrink them; the plan a test asserts does not depend on the scale.
//
// The rows are synthetic: every value comes from the row number (no
// Math.random). Times are relative to NOW, the wall clock floored to the hour,
// because the routes under test read their windows off the server clock.
import { openDb, d1 } from './d1-sqlite.bh-1030.js';

export const LIVE = { wakes: 206176, cost_rows: 95272, jobs: 49170, job_heartbeats: 46459, ledgers: 26520 };
const NOW_MS = Math.floor(Date.now() / 3600e3) * 3600e3;  // determinism: ok the single anchor; every seeded time is an offset from it
export const NOW_ISO = new Date(NOW_MS).toISOString().replace(/\.\d{3}Z$/, 'Z');
// isoAgo(hours) — NOW minus that many hours, in the worker's ISO shape.
export const isoAgo = (h) => new Date(NOW_MS - h * 3600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const PROJECTS = ['alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel', 'india', 'juliet', 'kilo', 'lima', 'mike'];
const KINDS = ['build', 'triage', 'lead-review', 'fix', 'qa'];
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
// row i of n spread evenly over the last `days` days, newest last
const at = (i, n, days) => iso(NOW_MS - Math.floor(((n - 1 - i) / n) * days * 86400e3));

export async function openVolumeDb(scale = Number(process.env.VOLUME_SCALE) || 1) {
  const opened = await openDb();
  if (!opened) return null;
  const { db } = opened;
  const n = Object.fromEntries(Object.entries(LIVE).map(([k, v]) => [k, Math.max(50, Math.round(v * scale))]));
  db.exec('BEGIN');
  const job = db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, issue_created_at, first_spawn_at)
                          VALUES (?,?,?,?,?,?,?,?,?,?,?)`);
  const beat = db.prepare('INSERT INTO job_heartbeats (job_id, beat_at, box) VALUES (?,?,?)');
  const art = db.prepare(`INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, created_at, updated_at) VALUES (?,?,?,?,?)`);
  for (let i = 0; i < n.jobs; i++) {
    const p = PROJECTS[i % PROJECTS.length], kind = KINDS[i % KINDS.length];
    const created = at(i, n.jobs, 60), id = `${kind}-${p}-${i}`, ticket = `T-${Math.floor(i / 7)}`;
    const status = i > n.jobs - 40 ? 'running' : (i % 11 === 0 ? 'failed' : 'done');
    job.run(id, p, ticket, kind, `box-${i % 9}`, 'done', status, created, created,
      kind === 'build' ? created : null, kind === 'build' ? created : null);
    if (i < n.job_heartbeats) beat.run(id, created, `box-${i % 9}`);
    if (kind === 'build') art.run(id, 'pr_url', `https://github.com/o/${p}/pull/${i}`, created, created);
  }
  const led = db.prepare('INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES (?,?,?,?,?)');
  for (let i = 0; i < n.ledgers; i++) {
    const ts = at(i, n.ledgers, 60);
    if (i % 2 === 0) {
      // Merge m names a build job (every 5th job is a build), newest merge to
      // newest build, so a recent merge window names recent tickets.
      const M = Math.ceil(n.ledgers / 2), m = i / 2;
      const jj = Math.floor(((n.jobs - 1) - (M - 1 - m) * 5) / 5) * 5;
      const key = jj >= 0 ? `https://github.com/o/${PROJECTS[jj % PROJECTS.length]}/pull/${jj}` : `https://github.com/o/x/pull/none-${m}`;
      led.run('merge', key, 'merged', ts, ts);
    } else {
      led.run(i % 3 ? 'pr_state' : 'deploy', `k-${i}`, i % 3 ? 'open' : 'verified', ts, ts);
    }
  }
  const wake = db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < n.wakes; i++) {
    const ts = at(i, n.wakes, 7);
    wake.run(`o/${PROJECTS[i % PROJECTS.length]}`, ['pr', 'checks', 'push'][i % 3], String(i), 'e', ts.slice(0, 16), ts);
  }
  const cost = db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, cost_usd, inserted_at) VALUES (?,?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < n.cost_rows; i++) {
    const ts = at(i, n.cost_rows, 30);
    cost.run(`box-${i % 9}`, `h${i}`, i, ts, PROJECTS[i % PROJECTS.length], 'build', 'claude', 0.01, ts);
  }
  db.exec('COMMIT');

  return { ...opened, n };
}

// plan(db, sql, ...binds) — EXPLAIN QUERY PLAN detail lines, in order.
export function plan(db, sql, ...binds) {
  return db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
}
// fullScans(lines, tables) — the plan lines that SCAN one of `tables` with no index.
export function fullScans(lines, tables) {
  return lines.filter((l) => tables.some((t) => new RegExp(`^SCAN (${t})( AS \\w+)?$`).test(l) || new RegExp(`^SCAN (${t})\\b(?!.*USING)`).test(l)));
}

// capturingD1(db, log) — the D1 shim, plus a record of every READ it runs:
// log gets {sql, binds} for each first()/all(), so a test can EXPLAIN the
// worker's real statements with the binds the route used.
export function capturingD1(db, log) {
  const inner = d1(db);
  return {
    prepare(sql) {
      const s = inner.prepare(sql);
      let binds = [];
      const api = {
        bind(...v) { binds = v; s.bind(...v); return api; },
        first(col) { log.push({ sql, binds }); return s.first(col); },
        all() { log.push({ sql, binds }); return s.all(); },
        run() { return s.run(); },
      };
      return api;
    },
    batch(stmts) { return inner.batch(stmts); },
  };
}
