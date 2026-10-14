// tests/lib/lane-run-lease.bh-6125.mjs — an HTTP server on 127.0.0.1 for
// tests/lane-run-lease.bh-6125-test.sh, so bin/lib/lane-run-heartbeat.sh and
// bin/lane-run-worker.sh are driven over real curl against the REAL jobs
// worker (worker/jobs/src/index.js) on node:sqlite with the composed jobs schema
// applied. HARNESS_SECRET is 'fixture-harness-secret'. Same shape as
// tests/lib/lane-runs-worker.bh-6124.mjs, with the hooks this suite needs.
//
//   node lane-run-lease.bh-6125.mjs <log>
//
// Test hooks (never worker routes):
//   PUT /__setting {key, value}    writes a settings row
//   GET /__lane_runs               every lane_runs row
//   POST /__expire {id}            sets that row's lease_until to 2000-01-01
//   PUT /__heartbeat_fail {status, body}
//                                  every later heartbeat POST answers that
//                                  status and body instead of the router;
//                                  status 0 drops the connection (a transport
//                                  failure); {} clears it
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// the suite can SKIP visibly, and on its own after 180 s.
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
let beatFail = null;

const handle = async (method, path, headers, body) => {
  if (path === '/__setting') {
    const b = JSON.parse(body || '{}');
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-12T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(b.key, String(b.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__lane_runs') {
    return [200, JSON.stringify({ rows: db.prepare('SELECT * FROM lane_runs ORDER BY id').all() })];
  }
  if (path === '/__expire') {
    const r = db.prepare("UPDATE lane_runs SET lease_until='2000-01-01T00:00:00Z' WHERE id=?").run(JSON.parse(body || '{}').id);
    return [200, JSON.stringify({ changes: Number(r.changes) })];
  }
  if (path === '/__heartbeat_fail') {
    const b = JSON.parse(body || '{}');
    beatFail = b.status === undefined ? null : b;
    return [200, '{"ok":true}'];
  }
  if (beatFail && method === 'POST' && /^\/api\/lane-runs\/\d+\/heartbeat$/.test(path)) {
    return [beatFail.status, beatFail.body || '{}'];
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
    if (code === 0) { req.socket.destroy(); return; }
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(code === 204 ? undefined : out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 180000).unref();
