// tests/lib/ticket-edges.bh-6977.mjs — an HTTP server on 127.0.0.1 for
// tests/ticket-edges.bh-6977-test.sh, so bin/lib/ticket-edges.sh and its
// callers are driven over real curl against the REAL jobs worker
// (worker/jobs/src/index.js) on node:sqlite with the composed jobs schema
// applied. HARNESS_SECRET is 'fixture-harness-secret'. Same shape as
// tests/lib/project-lease.bh-6883.mjs.
//
//   node ticket-edges.bh-6977.mjs <log>
//
// Test hooks (never worker routes):
//   GET /__rows?table=ticket_edges|ticket_holds   every row, ORDER BY id
//   PUT /__setting {key, value}                   writes a settings row
//   POST /__drop                                  drops both tables (503)
//   PUT /__answer {status, body}                  every later POST to
//                                                 /api/ticket-* answers that
//                                                 instead of the worker; {} clears it
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
const db = new DatabaseSync(':memory:');
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };
const TABLES = ['ticket_edges', 'ticket_holds'];

let answer = null;

const handle = async (method, url, headers, body) => {
  const u = new URL(url, 'http://fixture.invalid');
  const path = u.pathname;
  if (path === '/__rows') {
    const t = u.searchParams.get('table');
    if (!TABLES.includes(t)) return [400, '{"error":"table"}'];
    try { return [200, JSON.stringify(db.prepare(`SELECT * FROM ${t} ORDER BY id`).all())]; } catch { return [200, '[]']; }
  }
  if (path === '/__setting') {
    const b = JSON.parse(body || '{}');
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-15T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(b.key, String(b.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__drop') {
    db.exec('DROP TABLE IF EXISTS ticket_edges; DROP TABLE IF EXISTS ticket_holds;');
    return [200, '{"ok":true}'];
  }
  if (path === '/__answer') {
    const b = JSON.parse(body || '{}');
    answer = b.status === undefined ? null : b;
    return [200, '{"ok":true}'];
  }
  if (answer && method === 'POST' && path.startsWith('/api/ticket-')) return [answer.status, answer.body || '{}'];
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  const req = new Request(`http://jobs.fixture.invalid${url}`, {
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
