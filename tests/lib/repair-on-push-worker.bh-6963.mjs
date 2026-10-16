// tests/lib/repair-on-push-worker.bh-6963.mjs — an HTTP server on 127.0.0.1
// for tests/repair-on-push.bh-6963-test.sh, so bin/repair-on-push.sh is driven
// over real curl against the REAL jobs worker (worker/jobs/src/index.js) on
// node:sqlite with the jobs schema composed from worker/jobs/schema.d/.
// HARNESS_SECRET is 'fixture-harness-secret'.
//
//   node repair-on-push-worker.bh-6963.mjs <log>
//
// Test hooks (never worker routes):
//   POST /__push {payload, delivery}  signs the payload and sends it to the
//                     REAL POST /webhooks/github, so the wake row is written by
//                     the production writer (wakeOf + recordWake)
//   PUT /__pr {repo, number, state}   one pr_state_events row
//   PUT /__setting {key, value}       one settings row
//   PUT /__noise {n}                  n wakes of kind pr (they raise max_id)
//   GET /__cursor                     the repair-on-push wake_cursors row, max
//                                     wake id and the newest push wake id
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, so
// the suite can SKIP visibly, and on its own after 180 s.
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
const AT = '2026-10-15T00:00:00Z';

const fetchWorker = async (method, path, headers, body) => {
  const req = new Request(`http://jobs.fixture.invalid${path}`, {
    method, headers, body: method === 'GET' || method === 'HEAD' ? undefined : body,
  });
  const res = await worker.fetch(req, env);
  return [res.status, await res.text()];
};

const handle = async (method, path, headers, body) => {
  const b = () => JSON.parse(body || '{}');
  if (path === '/__push' && method === 'POST') {
    const { payload, delivery } = b();
    const raw = JSON.stringify(payload);
    return fetchWorker('POST', '/webhooks/github', {
      'content-type': 'application/json', 'x-github-event': 'push', 'x-github-delivery': delivery,
      'x-hub-signature-256': 'sha256=' + createHmac('sha256', WH).update(raw).digest('hex'),
    }, raw);
  }
  if (path === '/__pr' && method === 'PUT') {
    const r = b();
    db.prepare(`INSERT INTO pr_state_events (repo, number, state, since, head, reviewed, reason, url, alerted, at, actor)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)`).run(r.repo, r.number, r.state, AT, '-', '-', '-',
      `https://github.com/${r.repo}/pull/${r.number}`, '-', AT, 'fixture');
    return [200, '{"ok":true}'];
  }
  if (path === '/__setting' && method === 'PUT') {
    const r = b();
    db.prepare(`INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES (?,?,?,?,?)`)
      .run(r.key, String(r.value), 'fixture', 'fixture', AT);
    return [200, '{"ok":true}'];
  }
  if (path === '/__noise' && method === 'PUT') {
    const n = Number(b().n) || 1;
    for (let i = 0; i < n; i++) {
      db.prepare(`INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)`)
        .run('Example-Org/example-repo', 'pr', String(9000 + i), 'pull_request.opened', `noise-${i}`, AT);
    }
    return [200, '{"ok":true}'];
  }
  if (path === '/__cursor') {
    const r = db.prepare(`SELECT cursor FROM wake_cursors WHERE box='repair-on-push'`).get();
    const top = db.prepare('SELECT MAX(id) AS hi FROM wakes').get();
    const push = db.prepare("SELECT MAX(id) AS hi FROM wakes WHERE kind='push'").get();
    return [200, JSON.stringify({ cursor: r ? Number(r.cursor) : null, max_id: Number(top.hi || 0),
      push_id: Number(push.hi || 0) })];
  }
  if (process.env.FAIL_ALL === '1') return [500, '{"error":"fixture failure"}'];
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
setTimeout(() => process.exit(0), 180000).unref();
