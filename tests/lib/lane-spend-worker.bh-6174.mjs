// tests/lib/lane-spend-worker.bh-6174.mjs — an HTTP server on 127.0.0.1 for
// tests/spend-lane-push.bh-6174-test.sh, so bin/spend-lane-push.sh is driven
// over real curl against the REAL jobs worker (worker/jobs/src/index.js) on
// node:sqlite with the jobs schema applied (jobsSchemaSql(), the composition
// of worker/jobs/schema.d/, #6093 schema-compose G6), and its rows are read back
// through GET /api/metrics/lane-spend. HARNESS_SECRET is 'fixture-harness-secret'.
//
//   node lane-spend-worker.bh-6174.mjs <log>
//
// Test hooks (never worker routes):
//   PUT /__setting {key, value}                    writes a settings row
//   POST /__cost_row {lane_id, cost_usd, ts}       writes one cost_rows row
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
let rowN = 0;

const handle = async (method, path, headers, body) => {
  if (path === '/__setting') {
    const b = JSON.parse(body || '{}');
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-12T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value, actor=excluded.actor").run(b.key, String(b.value));
    return [200, '{"ok":true}'];
  }
  if (path === '/__cost_row') {
    const b = JSON.parse(body || '{}');
    rowN += 1;
    db.prepare("INSERT INTO cost_rows (box,row_hash,line_no,ts,host,project,stage,runner,model,rc,cost_usd,lane_id,inserted_at) VALUES ('hub',?,?,?,'h','p','execute','claude','m',0,?,?,'2026-10-12T00:00:00Z')")
      .run(`fixture-${rowN}`, rowN, b.ts, Number(b.cost_usd), b.lane_id);
    return [200, '{"ok":true}'];
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
