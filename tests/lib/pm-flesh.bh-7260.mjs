// tests/lib/pm-flesh.bh-7260.mjs — the worker side of
// tests/pm-flesh.bh-7260-test.sh. The suite's fake curl runs it once per
// request: node pm-flesh.bh-7260.mjs <METHOD> <path?query> [body-file].
// It answers from the REAL route handlers (settings.js, roadmap-ideas.js,
// pm.js, model-routes.js) over the sqlite file $FXT/d1.sqlite, with the
// worker clock pinned to $FXT_NOW. It prints the payload, a newline and the
// status, the shape bin/lib/jobs/req.sh reads.
//
// Fixture switches, all under $FXT:
//   reqlog   every request is appended: METHOD path [body]
//   order    every request is appended as "jobs METHOD path" (the suite's
//            stubs append to the same file, so the order of steps is visible)
//   fail.<METHOD>.<path with / as _>   that route answers 500
//   failbody.<METHOD>.<path with / as _>   that route answers 500 when the
//            request body contains the file's text (one status of a route)
// Any other path is 404, the answer of a worker that has no such route.
import { DatabaseSync } from 'node:sqlite';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';

const W = process.env.PF_WORKER_DIR;
const { d1 } = await import(`${W}/test/lib/d1-sqlite.bh-1030.js`);
const { matchRoute } = await import(`${W}/src/lib/router.js`);
const routes = [];
for (const f of ['settings', 'roadmap-ideas', 'pm', 'model-routes']) {
  routes.push(...(await import(`${W}/src/routes/${f}.js`)).routes);
}

const [method, pathq, bodyFile] = process.argv.slice(2);
const T = process.env.FXT;
const out = (code, body) => { process.stdout.write(JSON.stringify(body) + '\n' + code); process.exit(0); };
let raw = '';
if (bodyFile) { try { raw = readFileSync(bodyFile, 'utf8'); } catch { raw = ''; } }
appendFileSync(`${T}/reqlog`, `${method} ${pathq}${raw ? ' ' + raw : ''}\n`);
const url = new URL('https://jobs.test' + pathq);
const path = url.pathname;
appendFileSync(`${T}/order`, `jobs ${method} ${path}\n`);
if (existsSync(`${T}/fail.${method}.${path.replace(/\//g, '_')}`)) out(500, { error: 'fixture outage' });
const fb = `${T}/failbody.${method}.${path.replace(/\//g, '_')}`;
if (existsSync(fb) && raw.includes(readFileSync(fb, 'utf8'))) out(500, { error: 'fixture outage' });
let body = null;
if (raw) { try { body = JSON.parse(raw); } catch { body = null; } }
const hit = matchRoute(routes, method, path);
if (!hit) out(404, { error: 'unknown endpoint', worker: 'harness-jobs' });
const db = new DatabaseSync(`${T}/d1.sqlite`, { timeout: 10000 });
const res = await hit.handler({ env: { DB: d1(db) }, url, path, t: process.env.FXT_NOW, body: body || {}, m: hit.m });
process.stdout.write(await res.text() + '\n' + res.status);
