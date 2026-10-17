// tests/lib/component-watch.bh-6972.mjs — the worker side of
// tests/component-watch.bh-6972-test.sh. The suite's fake curl runs it once per
// request: node component-watch.bh-6972.mjs <METHOD> <path?query> [body-file].
// It answers from the REAL route handlers (alerts.js, alert-actions.js,
// alert-decisions.js, ledger.js, model-routes.js) over the sqlite file
// $FXT/d1.sqlite, with the worker clock pinned to $FXT_NOW. It prints the
// payload, a newline and the status, the shape bin/lib/jobs/req.sh reads.
//
// Fixture switches, all under $FXT:
//   reqlog                       every request is appended: METHOD path [body]
//   settings.json                GET /api/settings/<key> answers from this map;
//                                a key not in it is 404 (no row)
//   fail.<METHOD>.<path with / as _>   that route answers 500
//   fail.resolve                 POST /api/alerts/actions action=resolve answers 500
// Any other path is 404, the answer of a worker that has no such route.
import { DatabaseSync } from 'node:sqlite';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';

const W = process.env.CW_WORKER_DIR;
const { d1 } = await import(`${W}/test/lib/d1-sqlite.bh-1030.js`);
const { matchRoute } = await import(`${W}/src/lib/router.js`);
const families = ['alerts', 'alert-actions', 'alert-decisions', 'ledger', 'model-routes'];
const routes = [];
for (const f of families) routes.push(...(await import(`${W}/src/routes/${f}.js`)).routes);

const [method, pathq, bodyFile] = process.argv.slice(2);
const T = process.env.FXT;
const out = (code, body) => { process.stdout.write(JSON.stringify(body) + '\n' + code); process.exit(0); };
let raw = '';
if (bodyFile) { try { raw = readFileSync(bodyFile, 'utf8'); } catch { raw = ''; } }
appendFileSync(`${T}/reqlog`, `${method} ${pathq}${raw ? ' ' + raw : ''}\n`);

const url = new URL('https://jobs.test' + pathq);
const path = url.pathname;
if (existsSync(`${T}/fail.${method}.${path.replace(/\//g, '_')}`)) out(500, { error: 'fixture outage' });
if (method === 'GET' && path.startsWith('/api/settings/')) {
  let map = {};
  try { map = JSON.parse(readFileSync(`${T}/settings.json`, 'utf8')); } catch { map = {}; }
  const key = decodeURIComponent(path.slice('/api/settings/'.length));
  if (Object.prototype.hasOwnProperty.call(map, key)) out(200, { setting: { key, value: String(map[key]) } });
  out(404, { error: 'no such setting' });
}
let body = null;
if (raw) { try { body = JSON.parse(raw); } catch { body = null; } }
if (method === 'POST' && path === '/api/alerts/actions' && body && body.action === 'resolve' && existsSync(`${T}/fail.resolve`)) {
  out(500, { error: 'fixture outage' });
}
const hit = matchRoute(routes, method, path);
if (!hit) out(404, { error: 'unknown endpoint', worker: 'harness-jobs' });
// The lane reads alerts and its ledger in parallel, and the alerts route runs
// DDL (ensureColumns): wait for a lock instead of answering 500.
const db = new DatabaseSync(`${T}/d1.sqlite`, { timeout: 10000 });
const res = await hit.handler({ env: { DB: d1(db) }, url, path, t: process.env.FXT_NOW, body: body || {}, m: hit.m });
process.stdout.write(await res.text() + '\n' + res.status);
