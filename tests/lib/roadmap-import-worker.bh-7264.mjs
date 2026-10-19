// tests/lib/roadmap-import-worker.bh-7264.mjs — an HTTP server on 127.0.0.1
// for tests/roadmap-import.bh-7243-test.sh, so bin/roadmap-import.sh is driven
// over real curl against the REAL jobs worker (worker/jobs/src/index.js) on
// node:sqlite with the jobs schema applied. HARNESS_SECRET is
// 'fixture-harness-secret'. The shape is tests/lib/fleet-version-worker.bh-7191.mjs.
//
//   node roadmap-import-worker.bh-7264.mjs <log> <epoch>
//
// Test hook (never a worker route):
//   POST /__sql {sql, params}   runs one fixture statement. A SELECT answers
//                               its rows as text: one line per row, the
//                               columns joined by a tab. Any other statement
//                               answers an empty body.
//
// The clock is pinned to <epoch>. Prints the port on stdout once it listens.
// Every request appends one line `<METHOD> <path> <status>` to <log>. Exits 3
// when node:sqlite is missing, so the suite can SKIP visibly, and stops on its
// own after 300 s.
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

const REPO = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${REPO}worker/jobs/src/index.js`)).default;
const { d1 } = await import(`${REPO}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${REPO}worker/jobs/test/lib/jobs-schema.js`);
const db = new DatabaseSync(':memory:');
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };

const handle = async (method, path, headers, body) => {
  if (path === '/__sql') {
    const b = JSON.parse(body);
    const st = db.prepare(b.sql);
    if (!/^\s*select/i.test(b.sql)) { st.run(...(b.params || [])); return [200, '']; }
    const rows = st.all(...(b.params || []));
    return [200, rows.map((r) => Object.values(r).map((v) => (v === null ? 'NULL' : String(v))).join('\t')).join('\n')];
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
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
