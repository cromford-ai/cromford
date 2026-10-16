// tests/lib/mc-wake-worker.bh-6975.mjs — an HTTP server on 127.0.0.1 for
// tests/mc-wake-consumer.bh-6975-test.sh, so bin/merge-conductor-wake.sh is
// driven over real curl against the REAL jobs worker (worker/jobs/src/index.js)
// on node:sqlite with the jobs schema composed from worker/jobs/schema.d/.
// HARNESS_SECRET is 'fixture-harness-secret'. The same shape as
// tests/lib/repair-on-push-worker.bh-6963.mjs.
//
//   node mc-wake-worker.bh-6975.mjs <log>
//
// Test hooks (never worker routes):
//   POST /__hook {event, payload, delivery}  signs the payload and sends it to
//                     the REAL POST /webhooks/github with that event header, so
//                     the wake row is written by the production writer (wakeOf
//                     + recordWake)
//   PUT /__wake {repo, kind, key, event, at}  one wakes row with a chosen `at`
//                     (each with its own minute bucket); answers {id}
//   PUT /__setting {key, value}       one settings row
//   GET /__cursor                     the merge-conductor-wake wake_cursors row
//                                     and the max wake id
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// the suite can SKIP visibly, and on its own after 300 s.
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';
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
const WH = 'fixture-webhook-secret';
const env = { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret', GITHUB_WEBHOOK_SECRET: WH };
const AT = '2026-10-16T00:00:00Z';
let bucket = 0;

const fetchWorker = async (method, path, headers, body) => {
  const req = new Request(`http://jobs.fixture.invalid${path}`, {
    method, headers, body: method === 'GET' || method === 'HEAD' ? undefined : body,
  });
  const res = await worker.fetch(req, env);
  return [res.status, await res.text()];
};

const handle = async (method, path, headers, body) => {
  const b = () => JSON.parse(body || '{}');
  if (path === '/__hook' && method === 'POST') {
    const { event, payload, delivery } = b();
    const raw = JSON.stringify(payload);
    return fetchWorker('POST', '/webhooks/github', {
      'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': delivery,
      'x-hub-signature-256': 'sha256=' + createHmac('sha256', WH).update(raw).digest('hex'),
    }, raw);
  }
  if (path === '/__wake' && method === 'PUT') {
    const r = b();
    bucket += 1;
    const res = db.prepare(`INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)`)
      .run(r.repo, r.kind, String(r.key), r.event || null, `fixture-${bucket}`, r.at || AT);
    return [200, JSON.stringify({ id: Number(res.lastInsertRowid) })];
  }
  if (path === '/__setting' && method === 'PUT') {
    const r = b();
    db.prepare(`INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES (?,?,?,?,?)`)
      .run(r.key, String(r.value), 'fixture', 'fixture', AT);
    return [200, '{"ok":true}'];
  }
  if (path === '/__cursor') {
    const r = db.prepare(`SELECT cursor FROM wake_cursors WHERE box='merge-conductor-wake'`).get();
    const top = db.prepare('SELECT MAX(id) AS hi FROM wakes').get();
    return [200, JSON.stringify({ cursor: r ? Number(r.cursor) : null, max_id: Number(top.hi || 0) })];
  }
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  return fetchWorker(method, path, h, body);
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
