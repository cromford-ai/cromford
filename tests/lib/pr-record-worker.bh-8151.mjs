// tests/lib/pr-record-worker.bh-8151.mjs — an HTTP server on 127.0.0.1 for
// tests/pr-record-webhook.bh-8151-test.sh: the REAL jobs worker
// (worker/jobs/src/index.js) on node:sqlite with the jobs schema applied, with
// GITHUB_WEBHOOK_SECRET set, so a signed delivery to POST /webhooks/github and
// bin/lib/pr-record.sh's GET /api/pr-records meet the same DB. The shape is
// tests/lib/gh-budget-worker.bh-6974.mjs, plus the GitHub delivery headers.
// HARNESS_SECRET is 'fixture-harness-secret'; GITHUB_WEBHOOK_SECRET is
// 'fixture-webhook-secret'.
//
//   node pr-record-worker.bh-8151.mjs <log> <epoch>
//
// Test hook (never a worker route):
//   POST /__sql {sql, params}   runs one fixture statement; answers {rows}
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// the suite can SKIP visibly, and on its own after 300 s.
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

const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const db = new DatabaseSync(':memory:');
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret', GITHUB_WEBHOOK_SECRET: 'fixture-webhook-secret' };
const FORWARD = ['authorization', 'x-github-event', 'x-github-delivery', 'x-hub-signature-256'];

const handle = async (method, path, headers, body) => {
  if (path === '/__sql') {
    const b = JSON.parse(body);
    const st = db.prepare(b.sql);
    const rows = /^\s*select/i.test(b.sql) ? st.all(...(b.params || [])) : (st.run(...(b.params || [])), []);
    return [200, JSON.stringify({ rows })];
  }
  const h = { 'content-type': 'application/json' };
  for (const k of FORWARD) if (headers[k]) h[k] = headers[k];
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
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
