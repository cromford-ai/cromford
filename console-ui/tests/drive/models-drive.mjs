// Headless drive of the BUILT bundle's /models screen at 375px and 1280px
// (BH-1510.3).
//
// Serves dist/ with the model-routes worker STUBBED IN MEMORY — the PUT and the
// reset really change what the next GET answers, so the drive exercises the
// round trip a person makes: open a role, pick a model, save, confirm in the
// in-app modal, see the ladder and the history change. It asserts what no unit
// test can see: no sideways body scroll on a phone, every table inside its own
// scrolling box, sortable headers, no native dialog, and the exact bodies the
// screen writes.
//
// The fixture is the point of honesty: this proves the SCREEN, not the data —
// the live worker's rows are only read once the console is deployed.
//
//   npm run build && npm run drive:models [-- --shots <dir>]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { navLink } from './nav.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');
const args = process.argv.slice(2);
const shotDir = path.resolve(args.includes('--shots') ? args[args.indexOf('--shots') + 1] : path.join(root, 'shots'));

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch {
  process.env.NODE_PATH = process.env.NODE_PATH || execSync('npm root -g').toString().trim();
  require('node:module').Module._initPaths();
  ({ chromium } = require('playwright'));
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };

// determinism: ok-file clock-now-js clock-new-date `at` stamps are only rendered
// and ordered by id; the drive asserts shapes and bodies, never a date.
const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

// The #1510.0 seed as it ships (worker/jobs/schema.sql), trimmed to the roles
// that exercise every attribution grade.
const SEED = [
  ['build.execute', [['claude-opus-5', 'claude']]],
  ['build.execute.fallback', [['claude-opus-5', 'claude']]],
  ['build.review', [['claude-fable-5-1', 'claude']]],
  ['build.qa', [['claude-opus-5', 'claude']]],
  ['build.plan', [['claude-fable-5-1', 'claude']]],
  ['triage', [['claude-fable-5-1', 'claude']]],
  ['triage.light', [['claude-sonnet-5', 'claude']]],
  ['orchestrate', [['claude-fable-5-1', 'claude'], ['claude-opus-5', 'claude']]],
  ['alert.triage', [['claude-fable-5-1', 'claude']]],
  ['greenfield', [['claude-fable-5-1', 'claude']]],
  ['auth.fallback', [['claude-opus-5', 'claude']]],
  ['codex.default', [['gpt-6-astra', 'codex']]],
  ['fireworks.default', [['accounts/fireworks/models/kimi-k2p7-code', 'fireworks']]]
];
const RUNNERS = ['claude', 'codex', 'openrouter', 'grok', 'fireworks'];
const PRICES = {
  'claude-opus-5': [0.000005, 0.000025], 'claude-opus-5-5': [0.000005, 0.000025],
  'claude-fable-5-1': [0.000015, 0.000075], 'claude-sonnet-5': [0.000003, 0.000015],
  'gpt-6-astra': [0.0000025, 0.00001], 'accounts/fireworks/models/kimi-k2p7-code': [0.0000006, 0.0000025]
};

// model_routes + model_route_changes, in memory. key = `${project||''}|${role}`.
const routes = new Map(SEED.map(([role, ladder]) => [`|${role}`,
  ladder.map(([model, runner], position) => ({ position, model, runner, updated_by: 'seed', updated_at: '2026-09-22T00:00:00Z' }))]));
// BH-1563: TWO legacy gapped scopes — rows that exist but start past rung 0,
// so the resolver ignores them and nothing on the old screen said they were
// there. The first is repaired by hand during the desktop pass; the second is
// left alone, so the banner is still there for the mobile pass to render.
routes.set('project-3|triage.light', [{ position: 2, model: 'claude-opus-5', runner: 'claude', updated_by: 'legacy', updated_at: '2026-09-20T00:00:00Z' }]);
routes.set('project-4|greenfield', [{ position: 3, model: 'claude-fable-5-1', runner: 'claude', updated_by: 'legacy', updated_at: '2026-09-20T00:00:00Z' }]);
const changes = [];
const writes = [];
// BH-2512: the per-model price_source marks the toggle writes.
const priceSource = new Map();
// Scope versions, as the worker's max(id): every write to a scope moves it.
const versions = new Map();
const bump = (key) => versions.set(key, (versions.get(key) || 1) + 1);
const versionOf = (key) => (routes.get(key) && routes.get(key).length ? (versions.get(key) || 1) : 0);

// NO RUNG 0 = NO SCOPE, the worker's own rule (core.js resolveModelLadder):
// without it the drive would serve a gapped scope the real worker hides.
function resolve(role, project) {
  const own = project && routes.get(`${project}|${role}`);
  if (own && own.length && own[0].position === 0) return { ladder: own, source: 'project' };
  const hub = routes.get(`|${role}`) || [];
  return { ladder: hub.length && hub[0].position === 0 ? hub : [], source: hub.length && hub[0].position === 0 ? 'hub' : 'none' };
}

// Every scope whose rows do not start at rung 0, fleet-wide (BH-1563).
const gapsNow = () => [...routes.entries()]
  .filter(([, rows]) => rows.length && rows[0].position !== 0)
  .map(([key, rows]) => ({ project: key.split('|')[0] || null, role: key.split('|')[1], positions: rows.map((r) => r.position) }))
  .sort((a, b) => `${a.project || ''}/${a.role}`.localeCompare(`${b.project || ''}/${b.role}`));
const ownRows = (role, project) => (project && (routes.get(`${project}|${role}`) || []).length
  ? routes.get(`${project}|${role}`) : routes.get(`|${role}`) || []);
const bare = (l) => l.map(({ position, model, runner }) => ({ position, model, runner }));

function audit(project, role, position, before, after, actor, reason) {
  changes.push({
    id: changes.length + 1, scope: project ? 'project' : 'hub', project: project || null, role, position,
    before_model: before ? before.model : null, before_runner: before ? before.runner : null,
    after_model: after ? after.model : null, after_runner: after ? after.runner : null, actor, reason, at: now()
  });
}

function api(method, p, q, body) {
  if (p === '/api/dash/fleet') return [200, { projects: ['project-4', 'project-3'], snapshot_age_min: 1, watchdog: { ok: true } }];
  if (p === '/api/coord/model-prices') {
    return [200, { per_token: Object.fromEntries(Object.entries(PRICES).map(([m, [i, o]]) => [m, {
      prompt: i, completion: o, ...(priceSource.has(m) ? { price_source: priceSource.get(m) } : {})
    }])) }];
  }
  // BH-2512: the price-source toggle and the hub remove, as the worker does them.
  if (p === '/api/coord/model-prices/source' && method === 'PUT') {
    writes.push({ method, p, body });
    if (!PRICES[body.model]) return [404, { error: `not in model_prices: ${body.model}` }];
    if (body.price_source === 'vendor-direct') priceSource.set(body.model, 'vendor-direct'); else priceSource.delete(body.model);
    return [200, { model: body.model, price_source: body.price_source }];
  }
  if (p === '/api/coord/model-routes/remove' && method === 'POST') {
    writes.push({ method, p, body });
    const key = `|${body.role}`;
    if (body.expected_version !== undefined && body.expected_version !== versionOf(key)) {
      return [409, { error: 'this ladder changed since you loaded it — reload and edit again', scope_version: versionOf(key), stale: 'project' }];
    }
    bump(key);
    const before = routes.get(key) || [];
    before.forEach((b) => audit(null, body.role, b.position, b, null, body.actor, body.reason));
    routes.delete(key);
    return [200, { removed: before.length, role: body.role, tombstone: before.length === 0 }];
  }
  if (p === '/api/coord/metrics/llm-spend') {
    const seed = [...q.values()].join('|').length;
    return [200, { usd: Math.round(seed * 137) / 100, calls: seed * 3, refused: 0 }];
  }
  if (p === '/api/coord/model-routes' && method === 'GET') {
    const project = q.get('project');
    const roles = [...new Set([...routes.keys()].filter((k) => k.startsWith('|') || (project && k.startsWith(`${project}|`))).map((k) => k.split('|')[1]))].sort();
    const gaps = gapsNow();
    const isGapped = (role) => gaps.some((g) => g.role === role
      && (g.project || '') === ((project && (routes.get(`${project}|${role}`) || []).length) ? project : ''));
    // BH-2512: one stage the ledger saw with no stage.* route, until a hub
    // rung 0 for it exists.
    const unrouted = q.has('unrouted_since') ? {
      unrouted_since: q.get('unrouted_since'), unrouted_truncated: false,
      unrouted_stages: (routes.get('|stage.qux') || []).some((r) => r.position === 0) ? []
        : [{ stage: 'qux', role: 'stage.qux', projects: ['project-4'], calls: 4, last_seen: now(), runners: ['claude'] }]
    } : {};
    return [200, {
      project, runners: RUNNERS, as_of: now(), gaps,
      roles: roles.map((role) => ({ role, ...resolve(role, project), gapped: isGapped(role) })),
      ...unrouted
    }];
  }
  if (p === '/api/coord/model-routes' && method === 'PUT') {
    writes.push({ method, p, body });
    const key = `${body.project || ''}|${body.role}`;
    if (body.expected_version !== undefined && body.expected_version !== versionOf(key)) {
      return [409, { error: 'this ladder changed since you loaded it — reload and edit again', scope_version: versionOf(key), stale: 'project' }];
    }
    // The hub guard (BH-1563): a project write based on the inherited hub
    // ladder refuses when that ladder moved, and says which scope did.
    if (body.expected_hub_version !== undefined && body.expected_hub_version !== versionOf(`|${body.role}`)) {
      return [409, { error: 'the hub ladder this edit was based on changed since you loaded it — reload and edit again',
        scope_version: versionOf(key), hub_scope_version: versionOf(`|${body.role}`), stale: 'hub' }];
    }
    const before = routes.get(key) || [];
    const same = (b, r) => b && b.model === r.model && b.runner === r.runner;
    const next = body.ladder.map((r, position) => (same(before[position], r) && !body.confirm
      ? { ...before[position] } : { position, ...r, updated_by: body.actor, updated_at: now() }));
    next.forEach((r, i) => { const b = before[i]; if (!same(b, r) || body.confirm) audit(body.project, body.role, i, b, r, body.actor, body.reason); });
    bump(key);
    before.slice(next.length).forEach((b) => audit(body.project, body.role, b.position, b, null, body.actor, body.reason));
    routes.set(key, next);
    return [200, { route: { role: body.role, project: body.project, ladder: bare(next) } }];
  }
  if (p === '/api/coord/model-routes/reset' && method === 'POST') {
    writes.push({ method, p, body });
    const key = `${body.project}|${body.role}`;
    if (body.expected_version !== undefined && body.expected_version !== versionOf(key)) {
      return [409, { error: 'this ladder changed since you loaded it — reload and edit again', scope_version: versionOf(key), stale: 'project' }];
    }
    bump(key);
    const before = routes.get(key) || [];
    before.forEach((b) => audit(body.project, body.role, b.position, b, null, body.actor, body.reason));
    routes.delete(key);
    return [200, { removed: before.length, route: { role: body.role, project: body.project, ...resolve(body.role, body.project) } }];
  }
  if (p.startsWith('/api/coord/model-routes/') && method === 'GET') {
    const role = decodeURIComponent(p.slice('/api/coord/model-routes/'.length));
    const r = resolve(role, q.get('project'));
    return [200, {
      role, project: q.get('project'), ladder: bare(r.ladder), source: r.source, runners: RUNNERS, as_of: now(),
      scope_version: versionOf(`${q.get('project') || ''}|${role}`),
      hub_scope_version: versionOf(`|${role}`),
      gapped: (() => {
        const rows = routes.get(`${q.get('project') || ''}|${role}`) || [];
        return rows.length && rows[0].position !== 0 ? { rows: bare(rows) } : null;
      })(),
      provenance: r.ladder.map(({ position, updated_by, updated_at }) => ({ position, updated_by, updated_at }))
    }];
  }
  if (p === '/api/coord/model-route-changes') {
    const project = q.get('project');
    const list = changes.filter((c) => c.role === q.get('role') && (!project || c.project === null || c.project === project)).slice().reverse();
    return [200, { role: q.get('role'), project, changes: list, truncated: false }];
  }
  return [200, {}];
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      const [status, body] = api(req.method, url.pathname, url.searchParams, raw ? JSON.parse(raw) : null);
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    });
    return;
  }
  let file = path.join(dist, url.pathname === '/' ? 'index.html' : url.pathname.slice(1));
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(dist, 'index.html');
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  res.end(fs.readFileSync(file));
});

const fail = [];
const check = (ok, what) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) fail.push(what);
};

// The roles tables (HUB DEFAULTS, STAGE RUNNERS), not BH-2512's two sections,
// which carry their own rows and their own action column.
const NOT_ROLES = ['UNROUTED STAGES', 'MODEL PRICES'];
const roleTables = (page) => page.evaluate((skip) => {
  const ts = [...document.querySelectorAll('table.tbl')].filter((t) => {
    const title = t.closest('.section') && t.closest('.section').querySelector('.section__title');
    return !(title && skip.includes(title.innerText.trim()));
  });
  return {
    th: ts.reduce((n, t) => n + t.querySelectorAll('thead th').length, 0),
    sortable: ts.reduce((n, t) => n + t.querySelectorAll('thead th[aria-sort] button').length, 0),
    rows: ts.reduce((n, t) => n + t.querySelectorAll('tbody tr').length, 0)
  };
}, NOT_ROLES);

async function layout(page, name) {
  const o = await page.evaluate(() => ({
    body: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    loose: [...document.querySelectorAll('table.tbl')].filter((t) => !t.closest('.tablewrap')).length,
    th: document.querySelectorAll('table.tbl thead th').length,
    sortable: document.querySelectorAll('table.tbl thead th[aria-sort] button').length
  }));
  check(o.body <= 0, `${name}: no horizontal body scroll (overflow ${o.body}px)`);
  check(o.loose === 0, `${name}: every table sits inside a .tablewrap that scrolls on its own`);
  return o;
}

async function run() {
  if (!fs.existsSync(path.join(dist, 'index.html'))) {
    console.error('dist/ is not built — run `npm run build` first');
    process.exit(2);
  }
  fs.mkdirSync(shotDir, { recursive: true });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();

  for (const [name, width, height] of [['desktop', 1280, 900], ['mobile', 375, 820]]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    const errors = [];
    let dialogs = 0;
    page.on('dialog', async (d) => { dialogs += 1; await d.dismiss(); });
    // The stale-tab flow provokes exactly one 409 on purpose; the browser logs
    // it as a failed resource. Any other error still fails the drive.
    let expected409 = name === 'desktop' ? 1 : 0;
    page.on('console', (m) => {
      if (m.type() !== 'error') return;
      if (expected409 > 0 && /status of 409/.test(m.text())) { expected409 -= 1; return; }
      errors.push(m.text());
    });
    page.on('pageerror', (e) => errors.push(String(e)));

    // ── the list
    await page.goto(`${base}/models`, { waitUntil: 'networkidle' });
    await page.waitForSelector('table.tbl tbody tr', { timeout: 15000 });
    await layout(page, `${name} /models`);
    const o = await roleTables(page);
    check(o.sortable === o.th - 1, `${name}: ${o.sortable} of ${o.th} headers sort (HISTORY is a link column)`);
    if (name === 'desktop') {
      const spill = await page.$eval('.tablewrap', (w) => w.scrollWidth - w.clientWidth);
      check(spill <= 0, `desktop: the roles table fits 1280px with no scroll of its own (spill ${spill}px)`);
    }
    const rows = o.rows;
    check(rows === SEED.length, `${name}: one row per role (${rows})`);
    const text = await page.evaluate(() => document.body.innerText);
    check(/roles carry a rung still on its #1510\.0 seed value/.test(text), `${name}: the SEED banner says what it counts`);
    check(/no spend attribution yet: auth\.fallback/.test(text), `${name}: the coverage note names the unattributed role`);
    // BH-1563: the scopes the resolver hides. Desktop runs first and repairs
    // one of the two, so mobile legitimately sees one fewer.
    const wantGaps = name === 'desktop' ? 2 : 1;
    check(new RegExp(`${wantGaps} scopes? carr(y|ies) a ladder with no rung 0`).test(text),
      `${name}: the gap banner counts the hidden scopes (${wantGaps})`);
    check(await page.$('a[href="/models/greenfield?project=project-4"]') !== null,
      `${name}: each gapped scope links to its own role page on its own tab`);
    check(await page.$('a[href="/models/build.execute#history"]') !== null, `${name}: every row links its history`);
    check(await page.$(navLink('/models')) !== null, `${name}: MODELS is in the nav`);
    // BH-2512: the unrouted stage, tagged, linked to the page that routes it;
    // the price table with its toggle; every header of both sorts but the button.
    check(/UNROUTED STAGES/.test(text) && /DEFAULTS TO CLAUDE/.test(text), `${name}: UNROUTED STAGES lists qux as DEFAULTS TO CLAUDE`);
    check(await page.$('a[href="/models/stage.qux"]') !== null, `${name}: the unrouted stage links to its role page`);
    check(/MODEL PRICES/.test(text) && /MARK VENDOR-DIRECT/.test(text), `${name}: MODEL PRICES offers the price-source toggle`);
    const extra = await page.evaluate((only) => [...document.querySelectorAll('.section')]
      .filter((sec) => only.includes(sec.querySelector('.section__title').innerText.trim()))
      .map((sec) => [sec.querySelectorAll('thead th').length, sec.querySelectorAll('thead th[aria-sort] button').length]), NOT_ROLES);
    check(extra.length === 2 && extra[0][0] === 5 && extra[0][1] === 5 && extra[1][0] === 4 && extra[1][1] === 3,
      `${name}: UNROUTED sorts all 5 headers, PRICES 3 of 4 (the button column) (${JSON.stringify(extra)})`);
    // ROLE is the default sort (ascending), so one click flips it and a second
    // flips it back.
    await page.click('table.tbl thead th button');
    await page.waitForTimeout(100);
    const dir = await page.$eval('table.tbl thead th', (th) => th.getAttribute('aria-sort'));
    await page.click('table.tbl thead th button');
    await page.waitForTimeout(100);
    const dir2 = await page.$eval('table.tbl thead th', (th) => th.getAttribute('aria-sort'));
    check(dir === 'descending' && dir2 === 'ascending', `${name}: ROLE header flips the sort (${dir} -> ${dir2})`);
    await page.screenshot({ path: path.join(shotDir, `models-${name}.png`), fullPage: true });

    if (name === 'desktop') {
      // ── edit the hub ladder of build.execute: the #1507 carry-over, by hand
      await page.click('a[href="/models/build.execute"]');
      await page.waitForSelector('select[aria-label="rung 0 model"]');
      await page.selectOption('select[aria-label="rung 0 model"]', 'claude-opus-5-5');
      await page.fill('input[aria-label="reason"]', '#1507 carry-over');
      await page.click('button:has-text("SAVE LADDER")');
      await page.waitForSelector('.modal');
      const modal = await page.$eval('.modal', (m) => m.innerText);
      check(/claude-opus-5 \(claude\) → claude-opus-5-5 \(claude\)/.test(modal), 'desktop: the confirm modal shows the rung before → after');
      await page.screenshot({ path: path.join(shotDir, `models-confirm-${name}.png`) });
      await page.click('.modal button.btn--primary');
      await page.waitForSelector('#change-1');
      const put = writes.find((w) => w.method === 'PUT');
      check(put && JSON.stringify(put.body) === JSON.stringify({
        role: 'build.execute', project: null, ladder: [{ model: 'claude-opus-5-5', runner: 'claude' }],
        actor: 'console', reason: '#1507 carry-over', expected_version: 1
      }), `desktop: the PUT carries the whole ladder, actor, reason and the version it edited (${put && JSON.stringify(put.body)})`);
      const role = await page.evaluate(() => document.body.innerText);
      check(/written/.test(role), 'desktop: the page says the write landed');
      check(/#1507 carry-over/.test(role), 'desktop: the history shows the change with its reason');
      await layout(page, 'desktop /models/build.execute');
      await page.screenshot({ path: path.join(shotDir, `models-role-${name}.png`), fullPage: true });

      // ── KEEP SEEDED VALUE on a seed that is right: the tag must clear
      await page.goto(`${base}/models/auth.fallback`, { waitUntil: 'networkidle' });
      await page.click('button:has-text("KEEP SEEDED VALUE")');
      await page.waitForSelector('.modal');
      await page.click('.modal button.btn--primary');
      await page.waitForFunction(() => /kept as seeded written/.test(document.body.innerText), null, { timeout: 5000 }).catch(() => {});
      const keepW = writes.filter((w) => w.method === 'PUT').at(-1);
      check(keepW && keepW.body.confirm === true && keepW.body.role === 'auth.fallback' && Number.isInteger(keepW.body.expected_version),
        `desktop: KEEP sends the same ladder with confirm:true and its version (${keepW && JSON.stringify(keepW.body)})`);
      check(await page.$('button:has-text("KEEP SEEDED VALUE")') === null, 'desktop: after KEEP the role no longer offers it (no seed rung left)');
      await page.goto(`${base}/models`, { waitUntil: 'networkidle' });
      await page.waitForSelector('table.tbl tbody tr');
      const authRow = await page.$eval('a[href="/models/auth.fallback"]', (a) => a.closest('td').innerText);
      check(!/SEED/.test(authRow), `desktop: the list no longer tags auth.fallback SEED (${authRow.replace(/\s+/g, ' ')})`);

      // ── a stale tab: another writer moves build.plan after this page loaded
      await page.goto(`${base}/models/build.plan`, { waitUntil: 'networkidle' });
      await page.waitForSelector('select[aria-label="rung 0 model"]');
      api('PUT', '/api/coord/model-routes', new URLSearchParams(), {
        role: 'build.plan', project: null, ladder: [{ model: 'claude-sonnet-5', runner: 'claude' }], actor: 'other-tab', reason: 'raced'
      });
      await page.selectOption('select[aria-label="rung 0 model"]', 'claude-opus-5-5');
      await page.click('button:has-text("SAVE LADDER")');
      await page.click('.modal button.btn--primary');
      await page.waitForFunction(() => /changed since you loaded it/.test(document.body.innerText), null, { timeout: 5000 }).catch(() => {});
      const staleText = await page.evaluate(() => document.body.innerText);
      check(/changed since you loaded it/.test(staleText), 'desktop: a stale save says the ladder changed and was not written');
      await page.waitForFunction(() => /claude-sonnet-5/.test(document.querySelector('table.tbl').innerText), null, { timeout: 5000 }).catch(() => {});
      check(/claude-sonnet-5/.test(await page.$eval('table.tbl', (t) => t.innerText)), 'desktop: the page reloaded to the other writer\'s ladder');
      check(routes.get('|build.plan')[0].model === 'claude-sonnet-5', 'desktop: the stale write changed nothing on the worker');

      // ── a project override, then reset back to the hub
      await page.goto(`${base}/models/build.qa?project=project-4`, { waitUntil: 'networkidle' });
      await page.waitForSelector('select[aria-label="rung 0 model"]');
      check(/saving creates an override/i.test(await page.evaluate(() => document.body.innerText)), 'desktop: a project on the hub default is told saving creates an override');
      await page.selectOption('select[aria-label="rung 0 model"]', 'claude-fable-5-1');
      await page.click('button:has-text("SAVE LADDER")');
      await page.click('.modal button.btn--primary');
      await page.waitForSelector('button:has-text("RESET TO HUB")');
      await page.click('button:has-text("RESET TO HUB")');
      await page.waitForSelector('.modal');
      await page.click('.modal button.btn--warn');
      // The button reads '…' while the write is in flight, so wait for the
      // refetched scope, not for the button's label to change.
      await page.waitForFunction(() => /HUB DEFAULT/.test(document.body.innerText), null, { timeout: 5000 }).catch(() => {});
      const override = writes.filter((w) => w.method === 'PUT').at(-1);
      check(override && override.body.project === 'project-4' && Number.isInteger(override.body.expected_hub_version),
        `desktop: a project save on the INHERITED hub ladder carries expected_hub_version (${override && JSON.stringify(override.body)})`);
      const reset = writes.find((w) => w.p.endsWith('/reset'));
      check(reset && reset.body.project === 'project-4' && reset.body.role === 'build.qa', 'desktop: RESET TO HUB posts the project-scoped reset');
      const after = await page.evaluate(() => document.body.innerText);
      check(/HUB DEFAULT/.test(after), 'desktop: after the reset the role resolves to the hub default again');

      // ── BH-1563: repair a legacy gapped scope from the banner's own link
      await page.goto(`${base}/models`, { waitUntil: 'networkidle' });
      await page.waitForSelector('table.tbl tbody tr');
      await page.click('a[href="/models/triage.light?project=project-3"]');
      await page.waitForSelector('button:has-text("RESET TO HUB")');
      const gapText = await page.evaluate(() => document.body.innerText);
      check(/rung 2: claude-opus-5 \(claude\)/.test(gapText), 'desktop: the gapped role page lists the orphan rung nothing reads');
      check(/no rung 0/.test(gapText), 'desktop: and says why it is ignored');
      await page.click('button:has-text("RESET TO HUB")');
      await page.waitForSelector('.modal');
      await page.click('.modal button.btn--warn');
      await page.waitForFunction(() => !/no rung 0/.test(document.body.innerText), null, { timeout: 5000 }).catch(() => {});
      check(!routes.has('project-3|triage.light'), 'desktop: RESET TO HUB deleted the orphan rows on the worker');
      await page.goto(`${base}/models`, { waitUntil: 'networkidle' });
      await page.waitForSelector('table.tbl tbody tr');
      const banner = await page.evaluate(() => document.body.innerText);
      check(/1 scope carries a ladder with no rung 0/.test(banner), 'desktop: the banner now counts one fewer hidden scope');

      // ── BH-2512: flip one model's price source, in the modal, and back
      const model = Object.keys(PRICES).sort()[0];
      await page.click('button:has-text("MARK VENDOR-DIRECT")');
      await page.waitForSelector('.modal');
      check(/04:30/.test(await page.$eval('.modal', (m) => m.innerText)), 'desktop: the price-source modal says when it takes effect');
      await page.screenshot({ path: path.join(shotDir, `models-price-confirm-${name}.png`) });
      await page.click('.modal button.btn--primary');
      await page.waitForSelector('button:has-text("USE OPENROUTER")', { timeout: 5000 }).catch(() => {});
      const ps = writes.filter((w) => w.p === '/api/coord/model-prices/source').at(-1);
      check(ps && JSON.stringify(ps.body) === JSON.stringify({ model, price_source: 'vendor-direct' }),
        `desktop: MARK VENDOR-DIRECT PUTs the model and vendor-direct (${ps && JSON.stringify(ps.body)})`);
      check(priceSource.get(model) === 'vendor-direct' && await page.$('button:has-text("USE OPENROUTER")') !== null,
        'desktop: the row reloads as DIRECT and offers USE OPENROUTER');
      await page.click('button:has-text("USE OPENROUTER")');
      await page.waitForSelector('.modal');
      check(/clears/i.test(await page.$eval('.modal', (m) => m.innerText)), 'desktop: switching back says it clears vendor rates');
      await page.click('.modal button.btn--warn');
      await page.waitForFunction(() => !/USE OPENROUTER/.test(document.body.innerText), null, { timeout: 5000 }).catch(() => {});
      check(!priceSource.has(model), 'desktop: USE OPENROUTER cleared the mark on the worker');

      // ── BH-2512: route the unrouted stage from its own link; it leaves the list
      await page.click('a[href="/models/stage.qux"]');
      await page.waitForSelector('button:has-text("ADD RUNG")');
      await page.click('button:has-text("ADD RUNG")');
      await page.click('button:has-text("SAVE LADDER")');
      await page.waitForSelector('.modal');
      await page.click('.modal button.btn--primary');
      await page.waitForSelector('button:has-text("REMOVE ROUTE")', { timeout: 5000 }).catch(() => {});
      await page.goto(`${base}/models`, { waitUntil: 'networkidle' });
      await page.waitForSelector('table.tbl tbody tr');
      check(/EVERY STAGE IS ROUTED/.test(await page.evaluate(() => document.body.innerText)), 'desktop: after SAVE LADDER the stage is no longer unrouted');

      // ── BH-2512: REMOVE ROUTE on the hub role page, confirmed in the modal
      await page.goto(`${base}/models/stage.qux`, { waitUntil: 'networkidle' });
      await page.waitForSelector('button:has-text("REMOVE ROUTE")');
      await page.click('button:has-text("REMOVE ROUTE")');
      await page.waitForSelector('.modal');
      check(/RUNNER_QUX/.test(await page.$eval('.modal', (m) => m.innerText)), 'desktop: the remove modal says what the stage falls back to');
      await page.click('.modal button.btn--warn');
      await page.waitForFunction(() => /removal written/.test(document.body.innerText), null, { timeout: 5000 }).catch(() => {});
      const rm = writes.filter((w) => w.p === '/api/coord/model-routes/remove').at(-1);
      check(rm && rm.body.role === 'stage.qux' && rm.body.actor === 'console' && Number.isInteger(rm.body.expected_version),
        `desktop: REMOVE ROUTE posts the hub remove with its version (${rm && JSON.stringify(rm.body)})`);
      check(!routes.has('|stage.qux'), 'desktop: the hub rows are gone on the worker');
      check(await page.$('button:has-text("REMOVE ROUTE")') === null, 'desktop: with no hub rows left, REMOVE ROUTE is gone');
      await page.goto(`${base}/models/stage.qux?project=project-4`, { waitUntil: 'networkidle' });
      await page.waitForSelector('button:has-text("SAVE LADDER")');
      check(await page.$('button:has-text("REMOVE ROUTE")') === null, 'desktop: a project tab never offers REMOVE ROUTE');
    } else {
      await page.goto(`${base}/models/orchestrate?project=project-4`, { waitUntil: 'networkidle' });
      await page.waitForSelector('select[aria-label="rung 1 model"]');
      await layout(page, 'mobile /models/orchestrate');
      await page.screenshot({ path: path.join(shotDir, `models-role-${name}.png`), fullPage: true });
    }

    check(dialogs === 0, `${name}: no native dialog opened (${dialogs})`);
    check(errors.length === 0, `${name}: console is clean${errors.length ? ` — ${errors.slice(0, 2).join(' | ')}` : ''}`);
    await page.close();
  }

  await browser.close();
  server.close();
  console.log(fail.length ? `\nFAILED: ${fail.length}` : `\nall good — shots in ${shotDir}`);
  process.exit(fail.length ? 1 : 0);
}

run().catch((e) => { console.error(e); process.exit(1); });
