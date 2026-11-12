// tests/lib/web-session-worker.bh-7597.mjs — an HTTP server on 127.0.0.1 for
// tests/web-session-cli.bh-7597-test.sh, so bin/lib/web-session.sh is driven
// over real curl against the REAL jobs worker (worker/jobs/src/index.js) on
// node:sqlite with the jobs schema composed from worker/jobs/schema.d/.
//
//   node web-session-worker.bh-7597.mjs <log>
//
// HARNESS_SECRET is 'fixture-harness-secret' and WEB_VAULT_KEY_1 is built from
// a fixture string.
//
// Test hooks (never worker routes):
//   POST /__sql      the body is SQL, run with exec (seed rows, age a row)
//   POST /__get      the body is one SELECT; answers its rows as JSON
//   POST /__novalue  the next /api/web-session/load answers 200 {} (no value)
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>; a body is never logged. Exits 3 when
// node:sqlite is missing, so the suite can SKIP visibly, and on its own after 180 s.
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
const env = {
  DB: d1(db),
  HARNESS_SECRET: 'fixture-harness-secret',
  WEB_VAULT_KEY_1: Buffer.from('fixture-key-web-session-bh7597-1').toString('base64'),
};
let noValue = false;

const handle = async (method, path, headers, body) => {
  if (path === '/__sql' && method === 'POST') { db.exec(body); return [200, '{"ok":true}']; }
  if (path === '/__get' && method === 'POST') return [200, JSON.stringify(db.prepare(body).all())];
  if (path === '/__novalue' && method === 'POST') { noValue = true; return [200, '{"ok":true}']; }
  if (noValue && path === '/api/web-session/load') { noValue = false; return [200, '{"saved_at":"2026-10-22T00:00:00Z"}']; }
  const h = { 'content-type': 'application/json' };
  for (const k of ['authorization', 'x-web-vault-run-token']) if (headers[k] !== undefined) h[k] = headers[k];
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
    if (!req.url.startsWith('/__')) appendFileSync(log, `${req.method} ${req.url} ${code}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { process.stdout.write(`${server.address().port}\n`); });
setTimeout(() => process.exit(0), 180e3).unref();
