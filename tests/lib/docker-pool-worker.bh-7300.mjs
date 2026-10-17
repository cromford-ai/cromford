// tests/lib/docker-pool-worker.bh-7300.mjs — an HTTP server on 127.0.0.1 for
// tests/docker-pool.bh-7300-test.sh, so the docker-pool lease routes,
// bin/lib/docker-pool.sh and bin/jobs-watchdog.sh are driven over real curl
// against the REAL jobs worker (worker/jobs/src/index.js) on node:sqlite with
// the composed jobs schema applied. HARNESS_SECRET is 'fixture-harness-secret'.
// Same shape as tests/lib/project-lease.bh-6883.mjs.
//
//   node docker-pool-worker.bh-7300.mjs <log>
//
// Test hooks (never worker routes):
//   POST /__enqueue {project, key, target?}  a queued build_queue row (target fly)
//   GET  /__row?project=&key=     the build_queue row, or null
//   GET  /__leases?project=&key=  the docker_pool_leases rows of that key, by id
//   POST /__expire {project, key} sets the active lease's lease_until to 2000-01-01
//   PUT  /__setting {key, value}  writes a settings row
//   PUT  /__answer {status, body} every later /api/docker-pool/* POST answers
//                                 that status and body instead of the worker;
//                                 {} clears it
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
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };

let answer = null;

const handle = async (method, url, headers, body) => {
  const u = new URL(url, 'http://fixture.invalid');
  const path = u.pathname;
  const qp = (k) => u.searchParams.get(k);
  const b = () => JSON.parse(body || '{}');
  if (path === '/__enqueue') {
    const x = b();
    db.prepare(`INSERT INTO build_queue (project, ticket_key, ticket_id, status, target, attempt, requested_by, enqueued_at, updated_at)
                VALUES (?,?,?,'queued',?,0,'hub-fixture','2026-10-17T00:00:00Z','2026-10-17T00:00:00Z')`)
      .run(x.project, x.key, `id-${x.key}`, x.target || 'fly');
    return [200, '{"ok":true}'];
  }
  if (path === '/__row') {
    return [200, JSON.stringify(db.prepare('SELECT * FROM build_queue WHERE project=? AND ticket_key=?').get(qp('project'), qp('key')) ?? null)];
  }
  if (path === '/__leases') {
    return [200, JSON.stringify(db.prepare('SELECT * FROM docker_pool_leases WHERE project=? AND ticket_key=? ORDER BY id').all(qp('project'), qp('key')))];
  }
  if (path === '/__expire') {
    const x = b();
    const r = db.prepare("UPDATE docker_pool_leases SET lease_until='2000-01-01T00:00:00Z' WHERE project=? AND ticket_key=? AND status='active'").run(x.project, x.key);
    return [200, JSON.stringify({ changes: Number(r.changes) })];
  }
  if (path === '/__setting') {
    const x = b();
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-17T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(x.key, String(x.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__answer') {
    const x = b();
    answer = x.status === undefined ? null : x;
    return [200, '{"ok":true}'];
  }
  if (answer && method === 'POST' && path.startsWith('/api/docker-pool/')) return [answer.status, answer.body || '{}'];
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
