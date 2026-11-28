// tests/lib/inspector-world.bh-9419.mjs — one HTTP server on 127.0.0.1 for
// tests/staff-inspector-lever.bh-9419-test.sh, so bin/staff/inspector-lever.sh
// is driven over real curl against
//   /api/*            the REAL jobs worker (worker/jobs/src/index.js) on the
//                     jobs schema composed from worker/jobs/schema.d/, so the
//                     settings rows the lane reads are the seed this PR ships
//   /v6/deployments   a fake Vercel deployment list, and
//   /v3/deployments/<uid>/events   a fake Vercel build log
//   /cf/accounts/<acct>/pages/projects/<name>   a fake Cloudflare Pages project
// The fakes answer from <fixture.json>, read again on every request, so a case
// changes the vendor state by rewriting the file:
//   {"deployments": {"<projectId>": {"status": 200, "body": {...}}},
//    "events":      {"<uid>": {"status": 200, "body": [...]}},
//    "cf":          {"status": 200, "body": {...}}}
// A missing entry answers 404. HARNESS_SECRET is 'fixture-harness-secret'.
//
//   node inspector-world.bh-9419.mjs <log> <fixture.json>
//
// Test hooks (never real routes): POST /__sql (jobs DB: exec the body),
// POST /__get (jobs DB: one SELECT).
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status> host=<Host header>` to <log>. Exits 3 when
// node:sqlite is missing, and on its own after 300 s.
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , log, fixture] = process.argv;
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
const SECRET = 'fixture-harness-secret';

const jobs = new DatabaseSync(':memory:');
jobs.exec(jobsSchemaSql());
const jobsEnv = { DB: d1(jobs), HARNESS_SECRET: SECRET };

const fx = () => { try { return JSON.parse(readFileSync(fixture, 'utf8')); } catch { return {}; } };
const answer = (e) => (e ? [e.status || 200, JSON.stringify(e.body === undefined ? null : e.body)] : [404, '{"error":"not found"}']);

const handle = async (method, path, headers, body) => {
  if (method === 'POST' && path === '/__sql') { jobs.exec(body); return [200, '{"ok":true}']; }
  if (method === 'POST' && path === '/__get') return [200, JSON.stringify(jobs.prepare(body).all())];
  const u = new URL(`http://x${path}`);
  if (path.startsWith('/v6/deployments')) {
    if (headers.authorization !== 'Bearer tok-fixture-vercel') return [403, '{"error":"forbidden"}'];
    return answer((fx().deployments || {})[u.searchParams.get('projectId') || '']);
  }
  const ev = u.pathname.match(/^\/v3\/deployments\/([^/]+)\/events$/);
  if (ev) {
    if (headers.authorization !== 'Bearer tok-fixture-vercel') return [403, '{"error":"forbidden"}'];
    return answer((fx().events || {})[ev[1]]);
  }
  if (u.pathname.startsWith('/cf/accounts/')) {
    if (headers.authorization !== 'Bearer tok-fixture-cloudflare') return [403, '{"success":false}'];
    return answer(fx().cf);
  }
  const h = { 'content-type': 'application/json' };
  if (headers.authorization) h.authorization = headers.authorization;
  const init = { method, headers: h, body: method === 'GET' || method === 'HEAD' ? undefined : body };
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
    if (!req.url.startsWith('/__')) appendFileSync(log, `${req.method} ${req.url} ${code} host=${req.headers.host || ''}\n`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(code === 204 ? undefined : out);
  });
});
server.listen(0, '127.0.0.1', () => { process.stdout.write(`${server.address().port}\n`); });
setTimeout(() => process.exit(0), 300e3).unref();
