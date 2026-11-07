// tests/lib/wakes-worker.bh-9074.mjs — an HTTP server on 127.0.0.1 for the
// BH-9074 suites (tests/pool-wake-poll.bh-9074-test.sh,
// tests/lane-wake-calendar.bh-9074-test.sh, tests/orc-monitor.bh-9074-test.sh).
// The lanes are driven over real curl against the REAL jobs worker
// (worker/jobs/src/index.js, every route family in test/route-table.d, so the
// contract's lane-wakes routes are there when the tree has them) on node:sqlite
// with the jobs schema composed from worker/jobs/schema.d/. HARNESS_SECRET is
// 'fixture-harness-secret'. The same shape as tests/lib/mc-wake-worker.bh-6975.mjs.
//
//   node wakes-worker.bh-9074.mjs <log>
//
// Test hooks (never worker routes):
//   PUT /__wake {repo, kind, key, event}  one wakes row (its own minute bucket);
//                     answers {id}
//   PUT /__setting {key, value}           one settings row
//   GET /__wakes?repo=<repo>              {n, ids} of that repo's wakes rows
//   PUT /__answer {path, status, body}    every later request whose pathname is
//                     <path> gets this answer instead of the route's (a
//                     mis-filtered worker); DELETE /__answer clears it
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
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
const db = new DatabaseSync(':memory:');
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };
const AT = '2026-11-09T10:00:00Z';
let bucket = 0;
const answers = new Map();

const fetchWorker = async (method, path, headers, body) => {
  const req = new Request(`http://jobs.fixture.invalid${path}`, {
    method, headers, body: method === 'GET' || method === 'HEAD' ? undefined : body,
  });
  const res = await worker.fetch(req, env);
  return [res.status, await res.text()];
};

const handle = async (method, path, headers, body) => {
  const b = () => JSON.parse(body || '{}');
  const url = new URL(`http://x${path}`);
  if (url.pathname === '/__wake' && method === 'PUT') {
    const r = b();
    bucket += 1;
    const res = db.prepare(`INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)`)
      .run(r.repo, r.kind, String(r.key), r.event || null, `fixture-${bucket}`, AT);
    return [200, JSON.stringify({ id: Number(res.lastInsertRowid) })];
  }
  if (url.pathname === '/__setting' && method === 'PUT') {
    const r = b();
    db.prepare(`INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES (?,?,?,?,?)`)
      .run(r.key, String(r.value), 'fixture', 'fixture', AT);
    return [200, '{"ok":true}'];
  }
  if (url.pathname === '/__wakes' && method === 'GET') {
    const rows = db.prepare('SELECT id, key, minute FROM wakes WHERE repo = ? ORDER BY id').all(url.searchParams.get('repo'));
    return [200, JSON.stringify({ n: rows.length, ids: rows.map((r) => Number(r.id)), rows })];
  }
  if (url.pathname === '/__answer') {
    if (method === 'DELETE') { answers.clear(); return [200, '{"ok":true}']; }
    const r = b();
    answers.set(r.path, [Number(r.status), typeof r.body === 'string' ? r.body : JSON.stringify(r.body)]);
    return [200, '{"ok":true}'];
  }
  if (answers.has(url.pathname)) return answers.get(url.pathname);
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  return fetchWorker(method, path, h, body);
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
    res.end(code === 204 ? undefined : out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
