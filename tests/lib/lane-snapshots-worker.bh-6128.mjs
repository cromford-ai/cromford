// tests/lib/lane-snapshots-worker.bh-6128.mjs — an HTTP server on 127.0.0.1 for
// tests/blocked-resolver-offhub.bh-6128-test.sh: the REAL jobs worker
// (worker/jobs/src/index.js) on node:sqlite with worker/jobs/schema.sql
// applied, so bin/lib/lane-run-inputs.sh, bin/lane-snapshot-publish.sh and
// bin/lane-run-worker.sh are driven over real curl. HARNESS_SECRET is
// 'fixture-harness-secret'. The shape is tests/lib/lane-runs-worker.bh-6124.mjs,
// plus the hooks this suite needs.
//
//   node lane-snapshots-worker.bh-6128.mjs <log>
//
// Test hooks (never worker routes):
//   PUT /__setting {key, value}   writes a settings row
//   DELETE /__setting {key}       removes it
//   GET /__lane_runs              every lane_runs row, args parsed
//   POST /__sql {sql, params}     runs one statement, answers {rows}
//   PUT /__fail {method, match, status, skip}
//                                 every later request whose method matches and
//                                 whose path contains `match` answers `status`,
//                                 after the first `skip` of them (default 0)
//                                 have been let through
//   DELETE /__fail                stops failing
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>. Exits 3 when node:sqlite is missing, and
// on its own after 300 s.
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
let fail = null;

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
  if (path === '/__sql') {
    const b = JSON.parse(body || '{}');
    const st = db.prepare(b.sql);
    const rows = /^\s*select/i.test(b.sql) ? st.all(...(b.params || [])) : (st.run(...(b.params || [])), []);
    return [200, JSON.stringify({ rows })];
  }
  if (path === '/__fail') {
    fail = method === 'DELETE' ? null : JSON.parse(body || '{}');
    return [200, '{"ok":true}'];
  }
  if (fail && fail.method === method && path.includes(fail.match)) {
    if (Number(fail.skip) > 0) fail.skip = Number(fail.skip) - 1;
    else return [Number(fail.status) || 500, '{"error":"fixture failure"}'];
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
setTimeout(() => process.exit(0), 300000).unref();
