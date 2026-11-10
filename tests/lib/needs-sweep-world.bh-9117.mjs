// tests/lib/needs-sweep-world.bh-9117.mjs — one HTTP server on 127.0.0.1 for
// tests/needs-sweep.bh-9117-test.sh, so bin/needs-sweep.sh is driven over
// real curl against
//   /api/needs-sweep/*  the REAL Pages function
//                       (console-ui/functions/api/needs-sweep/[[path]].js) on a
//                       console D1 (node:sqlite) seeded from <seed.sql>
//   every other /api/*  the REAL jobs worker (worker/jobs/src/index.js) on the
//                       jobs schema composed from worker/jobs/schema.d/, so the
//                       settings rows the lane reads are the seed this PR ships
// HARNESS_SECRET is 'fixture-harness-secret'.
//
//   node needs-sweep-world.bh-9117.mjs <log> <seed.sql> <bodies.jsonl>
//
// Test hooks (never real routes):
//   POST /__sql    jobs DB: exec the body       POST /__get   jobs DB: one SELECT
//   POST /__csql   console DB: exec the body    POST /__cget  console DB: one SELECT
//   POST /__mode   the body is the failure mode for /api/needs-sweep:
//     cand500 | badjson | samecursor (candidates), apply500 | changed3 (apply), '' none
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>; every POST to /api/needs-sweep/apply
// appends its body to <bodies.jsonl>. Exits 3 when node:sqlite is missing, and
// on its own after 180 s.
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , log, seed, bodies] = process.argv;
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
const pages = await import(`${ROOT}console-ui/functions/api/needs-sweep/[[path]].js`);
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
const SECRET = 'fixture-harness-secret';

const jobs = new DatabaseSync(':memory:');
jobs.exec(jobsSchemaSql());
const jobsEnv = { DB: d1(jobs), HARNESS_SECRET: SECRET };

const cdb = new DatabaseSync(':memory:');
cdb.exec(`CREATE TABLE builds (id INTEGER PRIMARY KEY, bkey TEXT, project TEXT, ticket_key TEXT, stage TEXT,
    tier INTEGER, verdict TEXT, pr_url TEXT, merged INTEGER DEFAULT 0, updated_at TEXT);
  CREATE TABLE commands (id INTEGER PRIMARY KEY, ckey TEXT, type TEXT, project TEXT, status TEXT,
    attempts INTEGER, result TEXT, created_at, updated_at);`);
if (seed) cdb.exec(readFileSync(seed, 'utf8'));
const pagesEnv = { CONSOLE_DB: d1(cdb), HARNESS_SECRET: `${SECRET}\n` };
let mode = '';

const handle = async (method, path, headers, body) => {
  if (method === 'POST' && path === '/__sql') { jobs.exec(body); return [200, '{"ok":true}']; }
  if (method === 'POST' && path === '/__get') return [200, JSON.stringify(jobs.prepare(body).all())];
  if (method === 'POST' && path === '/__csql') { cdb.exec(body); return [200, '{"ok":true}']; }
  if (method === 'POST' && path === '/__cget') return [200, JSON.stringify(cdb.prepare(body).all())];
  if (method === 'POST' && path === '/__mode') { mode = body.trim(); return [200, '{"ok":true}']; }
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  const init = { method, headers: h, body: method === 'GET' || method === 'HEAD' ? undefined : body };
  if (path.startsWith('/api/needs-sweep/')) {
    const route = path.split('?')[0].slice('/api/needs-sweep/'.length);
    if (route === 'apply' && method === 'POST') appendFileSync(bodies, `${body}\n`);
    if (route === 'candidates') {
      if (mode === 'cand500') return [500, '{"error":"fixture failure"}'];
      if (mode === 'badjson') return [200, '{"rowz":[]}'];
    }
    if (route === 'apply' && mode === 'apply500') return [500, '{"error":"fixture failure"}'];
    const res = await pages.onRequest({
      request: new Request(`http://pages.fixture.invalid${path}`, init),
      env: pagesEnv,
      params: { path: route.split('/').filter(Boolean) }
    });
    let text = await res.text();
    if (route === 'candidates' && mode === 'samecursor') {
      // A page with rows whose cursor stays where it was asked.
      const j = JSON.parse(text);
      const after = Number(new URL(`http://x${path}`).searchParams.get('after') || 0);
      text = JSON.stringify({ ...j, next_after: after, done: false });
    }
    if (route === 'apply' && mode === 'changed3' && res.status === 200) {
      const j = JSON.parse(text);
      text = JSON.stringify({ ...j, builds: { ...j.builds, changed: 3 } });
    }
    return [res.status, text];
  }
  const res = await worker.fetch(new Request(`http://jobs.fixture.invalid${path}`, init), jobsEnv);
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
server.listen(0, '127.0.0.1', () => { process.stdout.write(`${server.address().port}\n`); });
setTimeout(() => process.exit(0), 180e3).unref();
