// tests/lib/mc-budget.bh-6887.mjs — an HTTP server on 127.0.0.1 for
// tests/mc-budget.bh-6887-test.sh and tests/mc-locks-lease.bh-6887-test.sh, so
// the mc-budget routes, the project lease routes, the retention route and the
// merge conductor's lease and budget clients are driven over real curl against
// the REAL jobs worker (worker/jobs/src/index.js) on node:sqlite with the
// composed jobs schema applied. HARNESS_SECRET is 'fixture-harness-secret'.
// Same shape as tests/lib/project-lease.bh-6883.mjs.
//
//   node mc-budget.bh-6887.mjs <log>
//
// Test hooks (never worker routes):
//   GET /__row?project=&day=&kind=  the mc_budget row, or null
//   GET /__lease?lane=&project=     the project_leases row, or null
//   GET /__runs?rule=               the retention_runs rows of that rule
//   PUT /__setting {key, value}     writes a settings row
//   POST /__budget {project, day, kind, spent}
//                                   writes (upserts) one mc_budget row
//   POST /__lease {lane, project, holder, fence, lease_until}
//                                   writes (upserts) one project_leases row
//   PUT /__answer {path_prefix, status, body}
//                                   every later request whose path starts
//                                   with path_prefix answers that status and
//                                   body instead of the worker; {} clears it
//   GET /__eqp                      seeds 5,000 mc_budget rows and answers
//                                   {spend, give} EXPLAIN QUERY PLAN details
//                                   for the route's exported SQL
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// a suite can SKIP visibly, and on its own after 300 s.
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , log] = process.argv;
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
// Optional on purpose: with no route module the fixture still starts, so a
// suite shows one FAIL per case rather than one setup error.
const SQL = await import(`${ROOT}worker/jobs/src/routes/mc-budget.js`).catch(() => ({}));
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const db = new DatabaseSync(':memory:');
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };

const KINDS = ['rereview', 'rebase', 'merge'];
const seed = () => {
  const ins = db.prepare('INSERT OR IGNORE INTO mc_budget (project,day,kind,spent) VALUES (?,?,?,?)');
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    const d = String(1 + (i % 28)).padStart(2, '0');
    ins.run(`seed-p${Math.floor(i / 84)}`, `2026-09-${d}`, KINDS[Math.floor(i / 28) % 3], i % 5);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
};
const plan = (sql) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all().map((r) => r.detail);

let answer = null;

const handle = async (method, url, headers, body) => {
  const u = new URL(url, 'http://fixture.invalid');
  const path = u.pathname;
  const q = (k) => u.searchParams.get(k);
  if (path === '/__row') {
    return [200, JSON.stringify(db.prepare('SELECT * FROM mc_budget WHERE project=? AND day=? AND kind=?').get(q('project'), q('day'), q('kind')) ?? null)];
  }
  if (path === '/__lease' && method === 'GET') {
    return [200, JSON.stringify(db.prepare('SELECT * FROM project_leases WHERE lane=? AND project=?').get(q('lane'), q('project')) ?? null)];
  }
  if (path === '/__runs') {
    return [200, JSON.stringify(db.prepare('SELECT rule, dry_run, removed, error FROM retention_runs WHERE rule=?').all(q('rule')))];
  }
  if (path === '/__setting') {
    const b = JSON.parse(body || '{}');
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-17T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(b.key, String(b.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__budget') {
    const b = JSON.parse(body || '{}');
    db.prepare('INSERT INTO mc_budget (project,day,kind,spent) VALUES (?,?,?,?) ON CONFLICT(project,day,kind) DO UPDATE SET spent=excluded.spent').run(b.project, b.day, b.kind, b.spent);
    return [200, '{"ok":true}'];
  }
  if (path === '/__lease') {
    const b = JSON.parse(body || '{}');
    db.prepare(`INSERT INTO project_leases (lane,project,holder,fence,lease_until,acquired_at) VALUES (?,?,?,?,?,'2026-10-17T00:00:00Z')
      ON CONFLICT(lane,project) DO UPDATE SET holder=excluded.holder, fence=excluded.fence, lease_until=excluded.lease_until`)
      .run(b.lane, b.project, b.holder, b.fence, b.lease_until);
    return [200, '{"ok":true}'];
  }
  if (path === '/__answer') {
    const b = JSON.parse(body || '{}');
    answer = b.status === undefined ? null : b;
    return [200, '{"ok":true}'];
  }
  if (path === '/__eqp') {
    if (!SQL.SPEND_SQL) return [500, '{"error":"no exported SPEND_SQL"}'];
    seed();
    return [200, JSON.stringify({ spend: plan(SQL.SPEND_SQL), give: plan(SQL.GIVE_SQL) })];
  }
  if (answer && path.startsWith(answer.path_prefix || '/api/')) return [answer.status, answer.body || '{}'];
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
    try { [code, out] = await handle(req.method, req.url, req.headers, body); } catch (e) { out = String(e && e.message); }
    appendFileSync(log, `${req.method} ${req.url} ${code}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
