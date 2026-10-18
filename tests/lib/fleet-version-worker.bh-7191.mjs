// tests/lib/fleet-version-worker.bh-7191.mjs — an HTTP server on 127.0.0.1 for
// tests/fleet-version-check.bh-7191-test.sh, so bin/fleet-version-check.sh is
// driven over real curl against the REAL jobs worker (worker/jobs/src/index.js)
// on node:sqlite with the jobs schema applied (jobsSchemaSql(), the settings
// seed rows included). HARNESS_SECRET is 'fixture-harness-secret'. The shape
// is tests/lib/lane-fleet-worker.bh-6126.mjs.
//
//   node fleet-version-worker.bh-7191.mjs <log> <epoch>
//
// Test hooks (never worker routes):
//   PUT  /__clock {epoch}          moves the worker clock (Date.now, new Date())
//   POST /__sql {sql, params}      runs one fixture statement; answers {rows}
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// the suite can SKIP visibly, and on its own after 300 s.
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , log, epoch0] = process.argv;
let clockMs = Number(epoch0) * 1000;
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
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };

const handle = async (method, path, headers, body) => {
  if (path === '/__clock') { clockMs = Number(JSON.parse(body).epoch) * 1000; return [200, '{"ok":true}']; }
  if (path === '/__sql') {
    const b = JSON.parse(body);
    const st = db.prepare(b.sql);
    const rows = /^\s*select/i.test(b.sql) ? st.all(...(b.params || [])) : (st.run(...(b.params || [])), []);
    return [200, JSON.stringify({ rows })];
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
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
