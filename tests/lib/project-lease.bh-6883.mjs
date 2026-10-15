// tests/lib/project-lease.bh-6883.mjs — an HTTP server on 127.0.0.1 for
// tests/project-lease.bh-6883-test.sh, so the project lease routes and
// bin/lib/project-lease.sh are driven over real curl against the REAL jobs
// worker (worker/jobs/src/index.js) on node:sqlite with the composed jobs schema
// applied. HARNESS_SECRET is 'fixture-harness-secret'. Same shape as
// tests/lib/lane-run-lease.bh-6125.mjs.
//
//   node project-lease.bh-6883.mjs <log>
//
// Test hooks (never worker routes):
//   GET /__row?lane=&project=    the project_leases row, or null
//   GET /__count?lane=&project=  {n}: rows for that (lane, project)
//   POST /__expire {lane, project}
//                                sets that row's lease_until to 2000-01-01
//   PUT /__setting {key, value}  writes a settings row
//   POST /__drop                 drops project_leases (the routes answer 503)
//   PUT /__answer {status, body}
//                                every later /api/project-leases/* POST
//                                answers that status and body instead of the
//                                worker; {} clears it
//   GET /__eqp                   seeds 5,000 project_leases rows and answers
//                                {acquire, renew, release} EXPLAIN QUERY PLAN
//                                details for the route's exported SQL, plus
//                                {index_list} from PRAGMA index_list
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// the suite can SKIP visibly, and on its own after 180 s.
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
const SQL = await import(`${ROOT}worker/jobs/src/routes/project-leases.js`).catch(() => ({}));
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const db = new DatabaseSync(':memory:');
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };

const LANES = ['merge-conductor', 'blocked-resolver', 'review', 'build', 'triage', 'ci-repair', 'rebase'];
const seed = () => {
  const ins = db.prepare("INSERT OR IGNORE INTO project_leases (lane,project,holder,fence,lease_until,acquired_at) VALUES (?,?,?,?,?,?)");
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    ins.run(LANES[i % LANES.length], `seed-p${Math.floor(i / LANES.length)}`, `box-${i % 13}`, 1 + (i % 9),
      '2026-10-15T00:03:00Z', '2026-10-15T00:00:00Z');
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
};
const plan = (sql) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all().map((r) => r.detail);

let answer = null;

const handle = async (method, url, headers, body) => {
  const u = new URL(url, 'http://fixture.invalid');
  const path = u.pathname;
  if (path === '/__row' || path === '/__count') {
    const lane = u.searchParams.get('lane'); const project = u.searchParams.get('project');
    if (path === '/__count') {
      return [200, JSON.stringify(db.prepare('SELECT COUNT(*) AS n FROM project_leases WHERE lane=? AND project=?').get(lane, project))];
    }
    return [200, JSON.stringify(db.prepare('SELECT * FROM project_leases WHERE lane=? AND project=?').get(lane, project) ?? null)];
  }
  if (path === '/__expire') {
    const b = JSON.parse(body || '{}');
    const r = db.prepare("UPDATE project_leases SET lease_until='2000-01-01T00:00:00Z' WHERE lane=? AND project=?").run(b.lane, b.project);
    return [200, JSON.stringify({ changes: Number(r.changes) })];
  }
  if (path === '/__setting') {
    const b = JSON.parse(body || '{}');
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-15T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(b.key, String(b.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__drop') {
    db.exec('DROP TABLE project_leases');
    return [200, '{"ok":true}'];
  }
  if (path === '/__answer') {
    const b = JSON.parse(body || '{}');
    answer = b.status === undefined ? null : b;
    return [200, '{"ok":true}'];
  }
  if (answer && method === 'POST' && path.startsWith('/api/project-leases/')) return [answer.status, answer.body || '{}'];
  if (path === '/__eqp') {
    if (!SQL.ACQUIRE_SQL) return [500, '{"error":"no exported ACQUIRE_SQL"}'];
    seed();
    return [200, JSON.stringify({
      acquire: plan(SQL.ACQUIRE_SQL), renew: plan(SQL.RENEW_SQL), release: plan(SQL.RELEASE_SQL),
      index_list: db.prepare('PRAGMA index_list(project_leases)').all(),
    })];
  }
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
setTimeout(() => process.exit(0), 180000).unref();
