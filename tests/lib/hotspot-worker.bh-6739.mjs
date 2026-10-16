// tests/lib/hotspot-worker.bh-6739.mjs — an HTTP server on 127.0.0.1 for
// tests/hotspot-split-ticket.bh-6739-test.sh, so bin/hotspot-split-ticket.sh is
// driven over real curl against the REAL jobs worker (worker/jobs/src/index.js)
// on node:sqlite with the jobs schema composed from worker/jobs/schema.d/.
// HARNESS_SECRET is 'fixture-harness-secret'.
//
//   node hotspot-worker.bh-6739.mjs <log> <fail-dir>
//
// Test hooks (never worker routes):
//   POST /__sql   the body is SQL, run with exec (seed rows, set settings)
//   POST /__get   the body is one SELECT; answers its rows as JSON
//   <fail-dir>/put-fail   while it exists, the NEXT PUT /api/hotspot-tickets
//                         answers 500 and the file is removed (fail once)
//   <fail-dir>/get-fail   while it exists, every GET /api/hotspot-tickets
//                         answers 500
//   <fail-dir>/hot-get-fail  while it exists, every GET /api/conflict-hotspots
//                         answers 500
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// the suite can SKIP visibly, and on its own after 300 s.
import { createServer } from 'node:http';
import { appendFileSync, existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , log, failDir] = process.argv;
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
const db = new DatabaseSync(':memory:');
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };

const handle = async (method, path, headers, body) => {
  if (path === '/__sql' && method === 'POST') { db.exec(body); return [200, '{"ok":true}']; }
  if (path === '/__get' && method === 'POST') return [200, JSON.stringify(db.prepare(body).all())];
  if (method === 'GET' && path.startsWith('/api/conflict-hotspots') && existsSync(`${failDir}/hot-get-fail`)) {
    return [500, '{"error":"fixture failure"}'];
  }
  if (path.startsWith('/api/hotspot-tickets')) {
    if (method === 'PUT' && existsSync(`${failDir}/put-fail`)) {
      rmSync(`${failDir}/put-fail`);
      return [500, '{"error":"fixture failure"}'];
    }
    if (method === 'GET' && existsSync(`${failDir}/get-fail`)) return [500, '{"error":"fixture failure"}'];
  }
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  const req = new Request(`http://jobs.fixture.invalid${path}`, {
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
    res.end(code === 204 ? undefined : out);
  });
});
server.listen(0, '127.0.0.1', () => { process.stdout.write(`${server.address().port}\n`); });
setTimeout(() => process.exit(0), 300e3).unref();
