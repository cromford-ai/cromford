// tests/lib/lane-run-metrics-worker.bh-6127.mjs — an HTTP server on 127.0.0.1
// for tests/lane-run-wait-alert.bh-6127-test.sh, so bin/lane-run-wait-alert.sh
// is driven over real curl against the REAL jobs worker
// (worker/jobs/src/index.js) on node:sqlite with the jobs schema composed from worker/jobs/schema.d/
// applied. HARNESS_SECRET is 'fixture-harness-secret'.
//
//   node lane-run-metrics-worker.bh-6127.mjs <log>
//
// Test hooks (never worker routes):
//   PUT /__lane_run {lane, project, status, enq_s_ago, claimed_by}
//                     inserts a lane_runs row enqueued enq_s_ago seconds ago,
//                     with no validation, so a test can seed a row the
//                     enqueue route would refuse (an unsafe lane name)
//   GET /__wait_alerts every lane_run_wait_alerts row
//   FAIL_ALL=1 (env)  every worker route answers 500
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
// BH-6005: the schema is composed from schema.d/; schema.sql is not committed.
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };
const iso = (msv) => new Date(msv).toISOString().replace(/\.\d{3}Z$/, 'Z');

const handle = async (method, path, headers, body) => {
  if (path === '/__lane_run' && method === 'PUT') {
    const b = JSON.parse(body || '{}');
    const enq = Date.now() - Number(b.enq_s_ago || 0) * 1000;  // determinism: ok the worker stamps with the real clock, so a seed is an offset off that clock at insert time
    const claimed = b.claimed_by ? iso(enq + 1000) : null;
    db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, claimed_at, claimed_by,
        attempts, status, rc, finished_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)`)
      .run(b.lane, b.project, '["bin/x.sh"]', iso(enq), 'fixture', claimed, b.claimed_by || null,
        claimed ? 1 : 0, b.status || 'queued', b.status === 'done' ? 0 : null, b.status === 'done' ? claimed : null);
    return [200, '{"ok":true}'];
  }
  if (path === '/__wait_alerts') {
    return [200, JSON.stringify({ rows: db.prepare('SELECT * FROM lane_run_wait_alerts ORDER BY lane').all() })];
  }
  if (process.env.FAIL_ALL === '1') return [500, '{"error":"fixture failure"}'];
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
