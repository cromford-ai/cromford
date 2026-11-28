// tests/lib/custody.bh-9554.mjs — an HTTP server on 127.0.0.1 for the BH-9554
// custody suites (tests/custody-{schema,lease,db-down}.bh-9554-test.sh). It
// runs the REAL jobs worker (worker/jobs/src/index.js) on node:sqlite with the
// composed jobs schema applied, so the /api/custody routes and
// bin/lib/jobs/custody.sh are driven over real curl. HARNESS_SECRET is
// 'fixture-harness-secret'. Same shape as tests/lib/project-lease.bh-6883.mjs.
//
//   node custody.bh-9554.mjs <log>
//
// Test hooks (never worker routes):
//   GET  /__row?project=&ticket=     the ticket_custody row, or null
//   GET  /__actions?project=&ticket= the custody_actions rows, oldest first
//   GET  /__columns?table=           PRAGMA table_info names
//   GET  /__indexes?table=           PRAGMA index_list
//   GET  /__setting?key=             the settings row, or null
//   PUT  /__setting {key, value}     writes a settings row
//   POST /__age {project, ticket, set:{col: <seconds from now> | null | text}}
//                                    moves times on one row; a number is an
//                                    offset in seconds from now, and due_at is
//                                    recomputed with the route's dueOf
//   POST /__seed {n, projects}       seeds n rows (1/3 settled, mixed due
//                                    times) in one transaction, then ANALYZE
//   GET  /__explain                  EXPLAIN QUERY PLAN details of the
//                                    route's exported DUE_SQL, ROW_SQL,
//                                    GAPS_SQL and the two retention id reads
//   POST /__sql {sql, params}        one statement: a SELECT answers its rows,
//                                    anything else {changes}
//   GET  /__count?table=             {n}
//   PUT  /__answer {status, body}    every later /api/custody/* request answers
//                                    that status and body instead of the
//                                    worker; {} clears it
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// the suite can SKIP visibly, and on its own after 300 s.
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , log] = process.argv;
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
// Optional on purpose: with no route module the fixture still starts, so the
// suite shows one FAIL per case rather than one setup error.
const SQL = await import(`${ROOT}worker/jobs/src/routes/custody.js`).catch(() => ({}));
const RET = (await import(`${ROOT}worker/jobs/src/routes/retention.d/bh-9554-custody.js`).catch(() => ({ default: [] }))).default;
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const db = new DatabaseSync(':memory:');
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const rel = (s) => iso(Date.now() + s * 1000); // determinism: ok the fixture ages rows relative to the worker's own server clock
const plan = (sql) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all().map((r) => r.detail);
const ident = (v) => (/^[a-z_]{1,40}$/.test(String(v)) ? v : null);

const seed = ({ n = 50000, projects = 8 }) => {
  const ins = db.prepare(`INSERT INTO ticket_custody (project, ticket, state, owner_lane, lease_expires_at, next_action,
    deadline_at, due_at, attempt, ladder_rung, rev, settled_at, created_at, updated_at)
    VALUES (?,?,?,?,?,?,?,?,0,0,1,?,?,?)`);
  db.exec('BEGIN');
  for (let i = 0; i < n; i++) {
    const settled = i % 3 === 0;
    // due times spread from 10 days ago to 10 days ahead
    const dl = rel(((i * 7919) % 1728000) - 864000);
    const ls = settled ? null : rel(((i * 104729) % 1728000) - 864000);
    const due = settled ? null : (dl < ls ? dl : ls);
    ins.run(`seed-p${i % projects}`, `S-${i}`, 'building', settled ? null : `lane-${i % 5}`, ls, settled ? null : 'reoffer',
      settled ? null : dl, due, settled ? rel(-86400 * (i % 20)) : null, rel(-86400 * 30), rel(-86400));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  return n;
};

let answer = null;

const handle = async (method, url, headers, body) => {
  const u = new URL(url, 'http://fixture.invalid');
  const path = u.pathname;
  const q = (k) => u.searchParams.get(k);
  const b = () => JSON.parse(body || '{}');
  if (path === '/__row') {
    return [200, JSON.stringify(db.prepare('SELECT * FROM ticket_custody WHERE project=? AND ticket=?').get(q('project'), q('ticket')) ?? null)];
  }
  if (path === '/__actions') {
    return [200, JSON.stringify(db.prepare('SELECT * FROM custody_actions WHERE project=? AND ticket=? ORDER BY id').all(q('project'), q('ticket')))];
  }
  if (path === '/__columns' || path === '/__indexes') {
    const t = ident(q('table')); if (!t) return [400, '{"error":"table"}'];
    const prag = path === '/__columns' ? 'table_info' : 'index_list';
    return [200, JSON.stringify(db.prepare(`PRAGMA ${prag}(${t})`).all())];
  }
  if (path === '/__count') {
    const t = ident(q('table')); if (!t) return [400, '{"error":"table"}'];
    return [200, JSON.stringify(db.prepare(`SELECT COUNT(*) AS n FROM ${t}`).get())];
  }
  if (path === '/__setting' && method === 'GET') {
    return [200, JSON.stringify(db.prepare('SELECT key, value FROM settings WHERE key=?').get(q('key')) ?? null)];
  }
  if (path === '/__setting') {
    const x = b();
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-11-12T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(x.key, String(x.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__age') {
    const x = b();
    const row = db.prepare('SELECT * FROM ticket_custody WHERE project=? AND ticket=?').get(x.project, x.ticket);
    if (!row) return [404, '{"error":"no_row"}'];
    const next = { ...row };
    for (const [c, v] of Object.entries(x.set || {})) {
      if (!ident(c) || !(c in row)) return [400, `{"error":"${c}"}`];
      next[c] = typeof v === 'number' ? rel(v) : v;
    }
    next.due_at = SQL.dueOf ? SQL.dueOf(next.deadline_at, next.lease_expires_at) : null;
    const cols = Object.keys(next).filter((c) => c !== 'id');
    db.prepare(`UPDATE ticket_custody SET ${cols.map((c) => `${c}=?`).join(',')} WHERE id=?`).run(...cols.map((c) => next[c]), row.id);
    return [200, JSON.stringify(db.prepare('SELECT * FROM ticket_custody WHERE id=?').get(row.id))];
  }
  if (path === '/__seed') return [200, JSON.stringify({ seeded: seed(b()) })];
  if (path === '/__sql') {
    const x = b();
    const st = db.prepare(x.sql);
    if (/^\s*SELECT\b/i.test(x.sql)) return [200, JSON.stringify(st.all(...(x.params || [])))];
    return [200, JSON.stringify({ changes: Number(st.run(...(x.params || [])).changes) })];
  }
  if (path === '/__explain') {
    if (!SQL.DUE_SQL) return [500, '{"error":"no exported DUE_SQL"}'];
    const ret = Object.fromEntries(RET.map((r) => [r.rule, plan(r.ids.replace('?1', "'2026-01-01T00:00:00Z'").replace('?2', '500'))]));
    return [200, JSON.stringify({
      due: plan(SQL.DUE_SQL.replace('?1', "'2026-11-12T00:00:00Z'").replace('?2', '201')),
      row: plan(SQL.ROW_SQL.replace('?1', "'seed-p1'").replace('?2', "'S-1'")),
      gaps_owner: plan(SQL.GAPS_SQL[0]), gaps_deadline: plan(SQL.GAPS_SQL[1]),
      gaps_project_owner: plan(SQL.GAPS_PROJECT_SQL[0].replace('?1', "'seed-p1'")),
      gaps_project_deadline: plan(SQL.GAPS_PROJECT_SQL[1].replace('?1', "'seed-p1'")),
      retention: ret,
    })];
  }
  if (path === '/__answer') {
    const x = b();
    answer = x.status === undefined ? null : x;
    return [200, '{"ok":true}'];
  }
  if (answer && path.startsWith('/api/custody/')) return [answer.status, answer.body ?? '{}'];
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  const req = new Request(`http://jobs.fixture.invalid${url}`, {
    method, headers: h, body: method === 'GET' || method === 'HEAD' ? undefined : body,
  });
  const res = await worker.fetch(req, env);
  return [res.status, await res.text()];
};

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    const body = Buffer.concat(chunks).toString('utf8');
    let code = 599; let out = '';
    try { [code, out] = await handle(req.method, req.url, req.headers, body); } catch (e) { out = JSON.stringify({ error: String(e && e.message) }); }
    appendFileSync(log, `${req.method} ${req.url} ${code}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
