// tests/lib/mr-red-world.bh-9532.mjs — one HTTP server on 127.0.0.1 for
// tests/staff-mr-red-contract.bh-9532-test.sh. It hosts the REAL jobs worker
// (worker/jobs/src/index.js) on the jobs schema composed from
// worker/jobs/schema.d/, so the settings rows, the roster row, the claim route
// and the mr-red routes are the ones this PR ships. HARNESS_SECRET is
// 'fixture-harness-secret'.
//
//   node mr-red-world.bh-9532.mjs <log>
//
// Test hooks (never real routes):
//   POST /__sql   exec the body on the jobs DB
//   POST /__get   one SELECT on the jobs DB, the rows as JSON
//   POST /__mode  the body is a failure mode: claim500 (the claim route
//                 answers 500), '' none
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing,
// and on its own after 900 s.
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

const jobs = new DatabaseSync(':memory:');
jobs.exec(jobsSchemaSql());
const env = { DB: d1(jobs), HARNESS_SECRET: 'fixture-harness-secret' };
let mode = '';

const handle = async (method, path, headers, body) => {
  if (method === 'POST' && path === '/__sql') { jobs.exec(body); return [200, '{"ok":true}']; }
  if (method === 'POST' && path === '/__get') return [200, JSON.stringify(jobs.prepare(body).all())];
  if (method === 'POST' && path === '/__mode') { mode = body.trim(); return [200, '{"ok":true}']; }
  if (mode === 'claim500' && path === '/api/staff/findings/claim') return [500, '{"error":"fixture failure"}'];
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  const init = { method, headers: h, body: method === 'GET' || method === 'HEAD' ? undefined : body };
  const res = await worker.fetch(new Request(`http://jobs.fixture.invalid${path}`, init), env);
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
setTimeout(() => process.exit(0), 900e3).unref();
