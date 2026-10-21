// tests/lib/web-vault-worker.bh-7595.mjs — an HTTP server on 127.0.0.1 for
// tests/web-vault-cli.bh-7595-test.sh, so bin/web-vault.sh and
// bin/lib/web-vault.sh are driven over real curl against the REAL jobs worker
// (worker/jobs/src/index.js) on node:sqlite with the jobs schema composed from
// worker/jobs/schema.d/.
//
//   node web-vault-worker.bh-7595.mjs <log>
//
// HARNESS_SECRET is 'fixture-harness-secret', WEB_VAULT_ADMIN_TOKEN is
// 'fixture-admin-token-7595' and WEB_VAULT_KEY_1 is built from a fixture string.
//
// Test hooks (never worker routes):
//   POST /__sql   the body is SQL, run with exec (seed rows, set settings)
//   POST /__get   the body is one SELECT; answers its rows as JSON
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
  WEB_VAULT_ADMIN_TOKEN: 'fixture-admin-token-7595',
  WEB_VAULT_KEY_1: Buffer.from('fixture-key-web-vault-bh7595-001').toString('base64'),
};

const handle = async (method, path, headers, body) => {
  if (path === '/__sql' && method === 'POST') { db.exec(body); return [200, '{"ok":true}']; }
  if (path === '/__get' && method === 'POST') return [200, JSON.stringify(db.prepare(body).all())];
  const h = { 'content-type': 'application/json' };
  for (const k of ['authorization', 'x-web-vault-admin-token', 'x-web-vault-run-token']) if (headers[k] !== undefined) h[k] = headers[k];
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
