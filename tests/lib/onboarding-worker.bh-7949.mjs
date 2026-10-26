// tests/lib/onboarding-worker.bh-7949.mjs — an HTTP server on 127.0.0.1 for
// tests/onboard-run.bh-7934-test.sh and tests/onboard-run-vendor-budget.bh-7934-test.sh,
// so bin/onboard-run.sh is driven over real curl against the REAL jobs worker
// (worker/jobs/src/index.js) on node:sqlite with the composed jobs schema.
// HARNESS_SECRET is 'tok-fixture-bh7949'. Same shape as
// tests/lib/otp-worker.bh-7732.mjs.
//
//   node onboarding-worker.bh-7949.mjs <log>
//
// Test hooks (never worker routes; the cancel and retry routes are BH-7950's):
//   POST /__cancel {id?}         the run (or every running run) -> cancelled
//   POST /__retry  {id}          BH-7950's retry as one batch: a failed run ->
//                                queued, its failed and skipped steps -> queued
//   POST /__age    {id, at}      sets the run's updated_at to `at` (ISO)
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <url> <status>` to <log>. Exits 3 when node:sqlite is missing, so
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
const env = { DB: d1(db), HARNESS_SECRET: 'tok-fixture-bh7949' };

const hooks = {
  '/__cancel': (x) => (x.id
    ? db.prepare("UPDATE onboarding_runs SET state = 'cancelled' WHERE id = ?").run(x.id)
    : db.prepare("UPDATE onboarding_runs SET state = 'cancelled' WHERE state = 'running'").run()),
  '/__retry': (x) => {
    db.exec('BEGIN');
    db.prepare(`UPDATE onboarding_steps SET retries = retries + (state = 'failed'), state = 'queued',
      started_at = NULL, finished_at = NULL, error_code = NULL WHERE run_id = ? AND state IN ('failed','skipped')`).run(x.id);
    db.prepare("UPDATE onboarding_runs SET state = 'queued', finished_at = NULL WHERE id = ? AND state = 'failed'").run(x.id);
    db.exec('COMMIT');
  },
  '/__age': (x) => db.prepare('UPDATE onboarding_runs SET updated_at = ? WHERE id = ?').run(x.at, x.id),
};

const handle = async (method, url, headers, body) => {
  const path = new URL(url, 'http://fixture.invalid').pathname;
  if (hooks[path]) { hooks[path](JSON.parse(body || '{}')); return [200, '{"ok":true}']; }
  const h = { 'content-type': 'application/json' };
  for (const k of ['authorization', 'idempotency-key']) if (headers[k]) h[k] = headers[k];
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
    let tag = '';
    if (/\/beat$/.test(req.url)) { try { const b = JSON.parse(body); tag = b.claim ? ' claim' : ` ${b.station}:${b.state}`; } catch { /* not JSON */ } }
    appendFileSync(log, `${req.method} ${req.url} ${code}${tag}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 300000).unref();
