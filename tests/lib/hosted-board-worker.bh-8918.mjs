// tests/lib/hosted-board-worker.bh-8918.mjs — an HTTP server on 127.0.0.1 for
// tests/hosted-board-tracer.bh-8918-test.sh, so bin/jobs-client.sh,
// bin/triage-gate.sh and bin/board-conformance.sh are driven over real curl
// against the REAL jobs worker (worker/jobs/src/index.js) on node:sqlite with
// the jobs schema applied. Its D1 batch is one transaction, as D1's is
// (worker/jobs/test/lib/d1-tx.bh-8918.js). HARNESS_SECRET is
// 'fixture-harness-secret'. The shape is tests/lib/gh-budget-worker.bh-6974.mjs.
//
//   node hosted-board-worker.bh-8918.mjs <log> <epoch>
//
// Test hook (never a worker route):
//   POST /__sql {sql, params}   runs one fixture statement; answers {rows}
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status> secret=<0|1>` to <log>; secret=1 means the request
// carried HARNESS_SECRET as its bearer. Exits 3 when node:sqlite is missing,
// so the suite can SKIP visibly, and on its own after 300 s.
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , log, epoch0] = process.argv;
const clockMs = Number(epoch0) * 1000;
const RealDate = Date;
class FixtureDate extends RealDate {
  constructor(...a) { if (a.length === 0) super(clockMs); else super(...a); }
  static now() { return clockMs; }
}
globalThis.Date = FixtureDate;

const SECRET = 'fixture-harness-secret';
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
const { d1tx } = await import(`${ROOT}worker/jobs/test/lib/d1-tx.bh-8918.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
const db = new DatabaseSync(':memory:');
db.exec(jobsSchemaSql());
const env = { DB: d1tx(db), HARNESS_SECRET: SECRET };

const handle = async (method, path, headers, body) => {
  if (path === '/__sql') {
    const b = JSON.parse(body);
    const st = db.prepare(b.sql);
    const rows = /^\s*select/i.test(b.sql) ? st.all(...(b.params || [])) : (st.run(...(b.params || [])), []);
    return [200, JSON.stringify({ rows })];
  }
  const h = { 'content-type': 'application/json' };
  for (const k of ['authorization', 'idempotency-key']) if (headers[k]) h[k] = headers[k];
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
    const secret = (req.headers.authorization || '') === `Bearer ${SECRET}` ? 1 : 0;
    appendFileSync(log, `${req.method} ${req.url} ${code} secret=${secret}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
