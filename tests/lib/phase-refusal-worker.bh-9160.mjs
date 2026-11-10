// tests/lib/phase-refusal-worker.bh-9160.mjs — an HTTP server on 127.0.0.1 for
// tests/queue-phase-refusal.bh-9160-test.sh, so queue_put and the verbatim
// bin/lib/rb/gates.sh fly enqueue block are driven over real curl against the
// REAL jobs worker (worker/jobs/src/index.js) on node:sqlite with the composed
// jobs schema applied. HARNESS_SECRET is 'fixture-harness-secret'.
// Same shape as tests/lib/release-cap-worker.bh-8734.mjs.
//
//   node phase-refusal-worker.bh-9160.mjs <log>
//
// Test hooks (never worker routes):
//   POST /__put {project, key, status, attempt, phase?}
//                                 writes (or overwrites) one build_queue row
//   GET  /__row?project=&key=     the build_queue row, or null
//   POST /__down {down: bool}     while down, every worker route answers 503
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status> <body>` to <log>. Exits 3 when node:sqlite is
// missing, so the suite can SKIP visibly, and on its own after 300 s.
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
const { ensureColumns } = await import(`${ROOT}worker/jobs/src/lib/core.js`);
const db = new DatabaseSync(':memory:');
db.exec(jobsSchemaSql());
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' };
// The phase columns, as the worker's own lifecycle routes add them on D1.
await ensureColumns(env, 'build_queue');
let down = false;

const handle = async (method, url, headers, body) => {
  const u = new URL(url, 'http://fixture.invalid');
  const path = u.pathname;
  const qp = (k) => u.searchParams.get(k);
  const b = () => JSON.parse(body || '{}');
  if (path === '/__put') {
    const x = b();
    db.prepare('DELETE FROM build_queue WHERE project=? AND ticket_key=?').run(x.project, x.key);
    db.prepare(`INSERT INTO build_queue (project, ticket_key, ticket_id, status, target, attempt, requested_by,
                  enqueued_at, finished_at, reason, updated_at, phase, phase_at, phase_actor)
                VALUES (?,?,?,?,?,?,'hub-fixture','2026-11-06T00:00:00Z','2026-11-06T00:00:00Z','RESULT PLAN_BLOCKED',
                        '2026-11-06T00:00:00Z',?,?,?)`)
      .run(x.project, x.key, `id-${x.key}`, x.status || 'done', x.target || 'fly', x.attempt ?? 1,
        x.phase ?? null, x.phase ? '2026-11-06T00:00:00Z' : null, x.phase ? 'triage' : null);
    return [200, '{"ok":true}'];
  }
  if (path === '/__row') {
    return [200, JSON.stringify(db.prepare('SELECT * FROM build_queue WHERE project=? AND ticket_key=?').get(qp('project'), qp('key')) ?? null)];
  }
  if (path === '/__down') { down = b().down === true; return [200, '{"ok":true}']; }
  if (down) return [503, '{"error":"fixture down"}'];
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
    appendFileSync(log, `${req.method} ${req.url} ${code} ${body.replace(/\n/g, ' ')}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
