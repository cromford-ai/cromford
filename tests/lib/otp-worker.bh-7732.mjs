// tests/lib/otp-worker.bh-7732.mjs — an HTTP server on 127.0.0.1 for
// tests/otp-wait.bh-7732-test.sh, so bin/otp-wait.sh is driven over real curl
// against the REAL jobs worker (worker/jobs/src/index.js) on node:sqlite with
// the composed jobs schema applied. HARNESS_SECRET is 'tok-fixture-bh7732'.
// Same shape as tests/lib/docker-pool-worker.bh-7300.mjs.
//
//   node otp-worker.bh-7732.mjs <log>
//
// Test hooks (never worker routes):
//   POST /__seed {to, mid, code, at}  one otp_messages row, in the shape
//                                     worker/otp-inbox/src/index.js writes
//   POST /__arm  {after, row}         insert `row` (the /__seed body) once
//                                     `after` GET /api/otp requests were served
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
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
const db = new DatabaseSync(':memory:');
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'tok-fixture-bh7732' };

const seed = (x) => db.prepare(`INSERT INTO otp_messages (recipient, message_id, sender, subject, code, parse_status, received_at)
  VALUES (?,?,'noreply@vendor.example.test','Your code',?,?,?)`).run(x.to, x.mid, x.code ?? null, x.code ? 'code' : 'no_code', x.at);
let armed = null; let served = 0;

const handle = async (method, url, headers, body) => {
  const path = new URL(url, 'http://fixture.invalid').pathname;
  if (path === '/__seed') { seed(JSON.parse(body || '{}')); return [200, '{"ok":true}']; }
  if (path === '/__arm') { armed = JSON.parse(body || '{}'); return [200, '{"ok":true}']; }
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  const req = new Request(`http://jobs.fixture.invalid${url}`, {
    method, headers: h, body: method === 'GET' || method === 'HEAD' ? undefined : body,
  });
  const res = await worker.fetch(req, env);
  const out = [res.status, await res.text()];
  if (path === '/api/otp') {
    served++;
    if (armed && served >= armed.after) { seed(armed.row); armed = null; }
  }
  return out;
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
