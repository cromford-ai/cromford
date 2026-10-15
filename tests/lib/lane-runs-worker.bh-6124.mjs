// tests/lib/lane-runs-worker.bh-6124.mjs — an HTTP server on 127.0.0.1 for
// tests/project-lanes-fly.bh-6124-test.sh, so pl_dispatch, lp_* and
// bin/lane-run-worker.sh are driven over real curl against the REAL jobs
// worker (worker/jobs/src/index.js) on node:sqlite with the composed jobs schema
// applied. HARNESS_SECRET is 'fixture-harness-secret'.
//
//   node lane-runs-worker.bh-6124.mjs <log>
//
// Test hooks (never worker routes):
//   PUT /__setting {key, value}   writes a settings row (value "" included)
//   DELETE /__setting {key}       removes it
//   GET /__lane_runs              every lane_runs row, args parsed
//   FAIL_ENQUEUE_N=<n> (env)      the first n POST /api/lane-runs answer 500
//   NO_BATCH=1 (env)              POST /api/lane-runs/batch answers 404, as a
//                                 worker that predates the route (BH-6886)
//   FAIL_BATCH_N=<n> (env)        the first n POST /api/lane-runs/batch answer 500
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
let failEnqueue = Number(process.env.FAIL_ENQUEUE_N || 0);
const noBatch = process.env.NO_BATCH === '1';
let failBatch = Number(process.env.FAIL_BATCH_N || 0);

const handle = async (method, path, headers, body) => {
  if (path === '/__setting') {
    const b = JSON.parse(body || '{}');
    if (method === 'DELETE') db.prepare('DELETE FROM settings WHERE key = ?').run(b.key);
    else db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-12T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(b.key, String(b.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__lane_runs') {
    const rows = db.prepare('SELECT * FROM lane_runs ORDER BY id').all()
      .map((r) => ({ ...r, args: JSON.parse(r.args_json) }));
    return [200, JSON.stringify({ rows })];
  }
  if (method === 'POST' && path === '/api/lane-runs' && failEnqueue > 0) {
    failEnqueue -= 1;
    return [500, '{"error":"fixture failure"}'];
  }
  if (method === 'POST' && path === '/api/lane-runs/batch' && noBatch) return [404, '{"error":"not found"}'];
  if (method === 'POST' && path === '/api/lane-runs/batch' && failBatch > 0) {
    failBatch -= 1;
    return [500, '{"error":"fixture failure"}'];
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
setTimeout(() => process.exit(0), 180000).unref();
