// tests/lib/envelope-worker.bh-7965.mjs — an HTTP server on 127.0.0.1 for the
// BH-7965 hub suites, so bin/envelope-keygen.sh, bin/envelope-consume.sh,
// bin/secrets-apply.sh and bin/secret-envelope-sweep.sh are driven over real
// curl against the REAL jobs worker (worker/jobs/src/index.js) on node:sqlite
// with the jobs schema composed from worker/jobs/schema.d/. Modelled on
// tests/lib/retention-worker.bh-6750.mjs.
//
//   node envelope-worker.bh-7965.mjs <log>
//
// HARNESS_SECRET is 'fixture-harness-secret'. ENVELOPE_HUB_TOKEN is the env
// FIXTURE_HUB_TOKEN (unset = the worker has none).
// Test hooks (never worker routes):
//   POST /__sql   the body is SQL, run with exec (seed rows, set settings)
//   POST /__get   the body is one SELECT; answers its rows as JSON
//   FAIL_ALL=1 (env)  every worker route answers 500
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status> hub=<0|1>` to <log> (hub=1: the request carried an
// x-envelope-hub-token header). No body and no header value is logged. Exits 3
// when node:sqlite is missing, and on its own after 300 s.
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
if (process.env.FIXTURE_HUB_TOKEN !== undefined) env.ENVELOPE_HUB_TOKEN = process.env.FIXTURE_HUB_TOKEN;

const handle = async (method, path, headers, body) => {
  if (path === '/__sql' && method === 'POST') { db.exec(body); return [200, '{"ok":true}']; }
  if (path === '/__get' && method === 'POST') return [200, JSON.stringify(db.prepare(body).all())];
  if (process.env.FAIL_ALL === '1') return [500, '{"error":"fixture failure"}'];
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  if (headers['x-envelope-hub-token'] !== undefined) h['x-envelope-hub-token'] = headers['x-envelope-hub-token'];
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
    try { [code, out] = await handle(req.method, req.url, req.headers, body); } catch (e) { out = JSON.stringify({ error: String(e && e.message) }); }
    const hub = req.headers['x-envelope-hub-token'] !== undefined ? 1 : 0;
    appendFileSync(log, `${req.method} ${req.url} ${code} hub=${hub}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(code === 204 ? undefined : out);
  });
});
server.listen(0, '127.0.0.1', () => { process.stdout.write(`${server.address().port}\n`); });
setTimeout(() => process.exit(0), 300e3).unref();
