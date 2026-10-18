// Headless drive of the /machines version columns (BH-7371, after BH-7306).
//
// Not a unit test. Two modes.
//
// FIXTURE (default): it serves the BUILT dist/ over http with the reads
// /machines makes stubbed (three watchdog boxes, a Fly project with three
// machines, two box_status rows, a registry with two boxes the watchdog does
// not know, one lane-fleet row, harness_version.max_lag_min=30; any other
// /api/* read answers {}), opens /machines in chromium at 1440x900 and
// 390x844, in the mill (dark) and paper (light) themes, and checks what a
// user sees:
//   - the SHA, LAG, LAST SYNC and LAST BEAT heads of ORGO BOXES are visible;
//   - the registry-only rows box-review-2 and bh-hub-2 are visible;
//   - the lag-40 LAG cell is var(--amber), the `current` one is not;
//   - each Fly machine shows its 8-char sha (dash feed, then lane-fleet);
//   - a click on LAG sets aria-sort on that head and re-orders the rows;
//   - the body never scrolls sideways; every table sits in its own
//     overflow-x:auto container.
// Then one more page with GET /api/coord/boxes answering 503: every LAG cell
// reads `unavailable`, none reads `current`.
//
// DEPLOYED (--base <https origin>): no server, no stubs. It sets the `dash`
// cookie from env CONSOLE_DASH_COOKIE (never printed, never written) and runs
// only the checks that need no known data: not the NOT SIGNED IN screen, the
// four heads visible, no body scroll, tables in overflow-x containers.
//
// Both modes write machines-<theme>-<width>.png (the viewport, before the sort
// click) and computed.md (theme, width, element, property, value) to --shots
// (default ./shots, git-ignored).
//
//   npm run build && node tests/drive/machines.bh-7371-drive.mjs [--shots <dir>]
//   CONSOLE_DASH_COOKIE=<value> node tests/drive/machines.bh-7371-drive.mjs --base https://<console> [--shots <dir>]
//
// Exit 0 = every check passed and the 4 PNGs and computed.md are on disk,
// 1 = a check failed (the shots written so far stay), 2 = a bad argument, no
// cookie for --base, or no dist/ (nothing is written).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');
const USAGE = 'usage: node tests/drive/machines.bh-7371-drive.mjs [--shots <dir>] [--base https://<origin>]';

function usage(why) {
  console.error(`${USAGE} (${why})`);
  process.exit(2);
}

const opts = {};
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  const flag = args[i];
  if (flag !== '--shots' && flag !== '--base') usage(`bad argument: ${flag}`);
  if (args[i + 1] === undefined || args[i + 1].startsWith('--')) usage(`${flag} needs a value`);
  opts[flag.slice(2)] = args[i + 1];
}

let base = null;
if (opts.base !== undefined) {
  let u = null;
  try { u = new URL(opts.base); } catch { u = null; }
  if (!u || u.protocol !== 'https:' || !u.host) usage(`--base must be an https:// origin: ${opts.base}`);
  base = u.origin;
}
const cookie = (process.env.CONSOLE_DASH_COOKIE || '').trim();
if (base && !cookie) {
  console.error('--base needs the dash cookie in env CONSOLE_DASH_COOKIE; it is not set');
  process.exit(2);
}
const shotDir = path.resolve(opts.shots || path.join(root, 'shots'));

if (!base && !fs.existsSync(path.join(dist, 'index.html'))) {
  console.error('dist/ is not built — run `npm run build` first');
  process.exit(2);
}

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch {
  process.env.NODE_PATH = [process.env.NODE_PATH, execSync('npm root -g').toString().trim()].filter(Boolean).join(path.delimiter);
  require('node:module').Module._initPaths();
  ({ chromium } = require('playwright'));
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };

// Timestamps are relative to one fixed anchor, and each fixture page pins its
// clock to it (page.clock.setFixedTime): LAG says `current` only for a check
// under 20 minutes old, and the age cells read the same on every run.
const FIXED_NOW = Date.parse('2026-10-14T06:00:00Z');
const ago = (min) => new Date(FIXED_NOW - min * 60000).toISOString();
const STUBS = {
  '/api/dash/machines': {
    boxes: { hub: '1m ago', 'bw-alpha': '1m ago', 'bw-beta': '2m ago' },
    fly: {
      proj: {
        machine_count: 3, apps: ['pool-proj'], orphan_jobs: [], jobs: [],
        machines: [
          { id: 'flym1aaa', role: 'pool', state: 'started', region: 'iad', app: 'pool-proj', harness_commit: '0123456789abcdef', created_at: ago(90) },
          { id: 'flym2bbb', role: 'pool', state: 'started', region: 'iad', app: 'pool-proj', created_at: ago(60) },
          { id: 'flym3ccc', role: 'pool', state: 'stopped', region: 'iad', app: 'pool-proj', created_at: ago(30) }
        ]
      }
    },
    fly_errors: [],
    snapshot_age_min: 1
  },
  // bw-alpha current with sync and beat times, bw-beta 40 min behind (over
  // the 30 min max: amber), hub and the registry-only boxes have no row.
  '/api/coord/boxes': {
    boxes: [
      { box: 'bw-alpha', harness_commit: 'aaaa1111bbbb2222', harness_lag_min: 0, lag_checked_at: ago(5), harness_synced_at: ago(30), last_beat_at: ago(2) },
      { box: 'bw-beta', harness_commit: 'bbbb2222cccc3333', harness_lag_min: 40, lag_checked_at: ago(3) }
    ],
    as_of: ago(0)
  },
  '/api/coord/registry': { boxes: [{ box: 'hub' }, { box: 'bw-alpha' }, { box: 'bw-beta' }, { box: 'box-review-2' }, { box: 'bh-hub-2' }] },
  '/api/coord/lane-fleet/machines': { machines: [{ machine_id: 'flym2bbb', state: 'started', harness_commit: 'fedcba9876543210' }] },
  '/api/coord/settings': { settings: [{ key: 'harness_version.max_lag_min', value: '30' }] },
  '/api/coord/box-commands': { commands: [], truncated: false },
  // The shell's own reads, so the top bar shows a live hub and watchdog
  // rather than a "watchdog unreachable" banner over the screen.
  '/api/dash/fleet': { snapshot_age_min: 1, watchdog: { boxes: { hub: '1m ago' } }, open_alerts: 0 },
  '/api/coord/whoami': { access: 'on', email: 'operator@example.com' }
};
const FLY_SHAS = { flym1aaa: '01234567', flym2bbb: 'fedcba98' };
const REGISTRY_ONLY = ['box-review-2', 'bh-hub-2'];
const VERSION_HEADS = ['SHA', 'LAG', 'LAST SYNC', 'LAST BEAT'];
const THEMES = [['mill', 'dark'], ['paper', 'light']];
const VIEWPORTS = [[1440, 900], [390, 844]];

let boxesDown = false;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    if (url.pathname === '/api/coord/boxes' && boxesDown) {
      res.writeHead(503, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: 'unavailable' }));
    }
    // The Orgo read: a route not deployed, which the screen shows as such.
    if (url.pathname === '/api/coord/orgo-computers') {
      res.writeHead(404, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not_found' }));
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(STUBS[url.pathname] || {}));
  }
  let file = path.join(dist, url.pathname === '/' ? 'index.html' : url.pathname.slice(1));
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(dist, 'index.html');
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  return res.end(fs.readFileSync(file));
});

const fail = [];
const check = (ok, what) => {
  console.log(`${ok ? 'pass' : 'FAIL'} ${what}`);
  if (!ok) fail.push(what);
};

// In the page: what a reader sees of ORGO BOXES and each FLY table.
function measure() {
  const visible = (el) => {
    if (!el || el.getClientRects().length === 0) return false;
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0 && r.width > 0 && r.height > 0;
  };
  const pick = (el, props) => (el ? Object.fromEntries(props.map((p) => [p, getComputedStyle(el)[p]])) : null);
  // A head's label without the sort arrow.
  const label = (th) => th.textContent.replace(/[^A-Z ]/g, '').replace(/\s+/g, ' ').trim();
  const sections = [...document.querySelectorAll('.section')];
  const titled = (re) => sections.filter((s) => re.test(s.querySelector('.section__title')?.textContent.trim() || ''));
  const shape = (s) => {
    const table = s && s.querySelector('table');
    if (!table) return null;
    const heads = [...table.querySelectorAll('thead th')];
    const names = heads.map(label);
    const rows = [...table.querySelectorAll('tbody tr')].map((tr) => {
      const tds = [...tr.querySelectorAll(':scope > td')];
      return { visible: visible(tr), cells: Object.fromEntries(names.map((n, i) => [n, tds[i] ? tds[i].textContent.replace(/\s+/g, ' ').trim() : null])), el: tr };
    });
    let wrap = table.parentElement;
    while (wrap && wrap !== s && !['auto', 'scroll'].includes(getComputedStyle(wrap).overflowX)) wrap = wrap.parentElement;
    return { table, heads, names, rows, wrap: wrap && wrap !== s ? wrap : null };
  };
  const cellEl = (t, rowFirst, head) => {
    const r = t && t.rows.find((x) => x.cells[t.names[0]] === rowFirst);
    const i = t ? t.names.indexOf(head) : -1;
    return r && i >= 0 ? r.el.querySelectorAll(':scope > td')[i] : null;
  };
  const orgo = shape(titled(/^ORGO BOXES$/)[0]);
  const flys = titled(/^FLY ·/).map(shape).filter(Boolean);
  // var(--amber) as the browser resolves it in this theme.
  const probe = document.createElement('span');
  probe.style.color = 'var(--amber)';
  document.body.appendChild(probe);
  const amber = getComputedStyle(probe).color;
  probe.remove();
  const lagSpan = (box) => cellEl(orgo, box, 'LAG')?.querySelector('span') || null;
  const TEXT = ['fontFamily', 'fontSize', 'fontWeight', 'color'];
  const allTables = [...document.querySelectorAll('table')].map((t) => {
    let w = t.parentElement;
    while (w && w !== document.body && !['auto', 'scroll'].includes(getComputedStyle(w).overflowX)) w = w.parentElement;
    return w && w !== document.body ? getComputedStyle(w).overflowX : 'none';
  });
  return {
    signedOut: [...document.querySelectorAll('.empty__title')].some((e) => e.textContent.trim() === 'NOT SIGNED IN'),
    orgo: orgo ? {
      heads: orgo.heads.map((th) => ({ text: label(th), visible: visible(th), sort: th.getAttribute('aria-sort') })),
      rows: orgo.rows.map((r) => ({ visible: r.visible, cells: r.cells })),
      wrap: orgo.wrap ? getComputedStyle(orgo.wrap).overflowX : null
    } : null,
    fly: flys.map((t) => t.rows.map((r) => ({ visible: r.visible, cells: r.cells }))).flat(),
    amber,
    computed: {
      'ORGO th SHA': pick(orgo && orgo.heads[orgo.names.indexOf('SHA')], TEXT),
      'ORGO td SHA code': pick(cellEl(orgo, 'bw-alpha', 'SHA')?.querySelector('code'), TEXT),
      'ORGO td LAG current': pick(lagSpan('bw-alpha'), TEXT),
      'ORGO td LAG over max': pick(lagSpan('bw-beta'), TEXT),
      'ORGO td LAST SYNC': pick(cellEl(orgo, 'bw-alpha', 'LAST SYNC')?.querySelector('span'), TEXT),
      'FLY td SHA code': pick(flys[0] && cellEl(flys[0], 'flym1aaa', 'SHA')?.querySelector('code'), TEXT),
      'ORGO table wrap': pick(orgo && orgo.wrap, ['overflowX']),
      body: pick(document.body, ['backgroundColor'])
    },
    allTables,
    page: { scrollWidth: document.documentElement.scrollWidth, innerWidth }
  };
}

const rowsOf = (m) => (m.orgo ? m.orgo.rows : []);
const rowNamed = (m, name) => rowsOf(m).find((r) => r.cells.BOX === name);
const table = [];
const shots = [];

// Wait for ORGO BOXES with its version cells filled (no '…' left), or the
// NOT SIGNED IN screen.
async function settle(page, ready) {
  await page.waitForFunction(ready, null, { timeout: 15000 }).catch(() => {});
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(300);
}
const orgoReady = () => {
  const t = [...document.querySelectorAll('.section')].find((s) => s.querySelector('.section__title')?.textContent.trim() === 'ORGO BOXES');
  const signedOut = [...document.querySelectorAll('.empty__title')].some((e) => e.textContent.trim() === 'NOT SIGNED IN');
  return signedOut || Boolean(t && t.querySelector('tbody tr') && !t.querySelector('tbody').textContent.includes('…'));
};

// At a phone width the version columns sit right of the viewport inside the
// table's own scroll box, so the shot scrolls the SHA head into view first.
async function shoot(page, themeId, width) {
  if (width < 1000) {
    await page.evaluate(() => {
      const s = [...document.querySelectorAll('.section')].find((x) => x.querySelector('.section__title')?.textContent.trim() === 'ORGO BOXES');
      const th = s && [...s.querySelectorAll('thead th')].find((h) => h.textContent.replace(/[^A-Z ]/g, '').trim() === 'SHA');
      if (th) th.scrollIntoView({ block: 'start', inline: 'start' });
    });
    await page.waitForTimeout(150);
  }
  const file = path.join(shotDir, `machines-${themeId}-${width}.png`);
  await page.screenshot({ path: file });
  shots.push(file);
  console.log(`shot ${file}`);
}

function common(m, tag) {
  const heads = m.orgo ? m.orgo.heads : [];
  for (const h of VERSION_HEADS) {
    const th = heads.find((x) => x.text === h);
    check(th && th.visible, `${tag}: the ${h} head of ORGO BOXES is visible`);
  }
  check(m.page.scrollWidth <= m.page.innerWidth, `${tag}: no horizontal body scroll (scrollWidth ${m.page.scrollWidth} <= innerWidth ${m.page.innerWidth})`);
  check(m.allTables.length > 0 && m.allTables.every((o) => o === 'auto'), `${tag}: every table sits in an overflow-x:auto container (${m.allTables.join(', ') || 'no tables'})`);
}

async function fixturePage(browser, url, themeId, scheme, width, height) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1, colorScheme: scheme });
  await page.addInitScript((id) => { window.localStorage.setItem('ui.theme', id); }, themeId);
  await page.clock.setFixedTime(FIXED_NOW);
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(url, { waitUntil: 'networkidle' });
  return { page, errors };
}

async function runFixture(browser) {
  await new Promise((r) => server.listen(0, r));
  const origin = `http://127.0.0.1:${server.address().port}`;
  for (const [themeId, scheme] of THEMES) {
    for (const [width, height] of VIEWPORTS) {
      const tag = `${themeId} ${width}px`;
      const { page, errors } = await fixturePage(browser, `${origin}/machines`, themeId, scheme, width, height);
      await settle(page, orgoReady);
      const m = await page.evaluate(measure);
      check(m.orgo !== null, `${tag}: the ORGO BOXES table renders`);
      common(m, tag);
      for (const name of REGISTRY_ONLY) {
        const r = rowNamed(m, name);
        check(r && r.visible, `${tag}: the registry-only row ${name} is visible`);
      }
      const alpha = rowNamed(m, 'bw-alpha');
      const beta = rowNamed(m, 'bw-beta');
      check(alpha && alpha.cells.SHA === 'aaaa1111' && alpha.cells.LAG === 'current',
        `${tag}: bw-alpha shows SHA aaaa1111 and LAG current (${alpha ? `${alpha.cells.SHA}, ${alpha.cells.LAG}` : 'no row'})`);
      const amberOn = m.computed['ORGO td LAG over max'];
      const plain = m.computed['ORGO td LAG current'];
      check(beta && beta.cells.LAG === '40 min' && amberOn && amberOn.color === m.amber,
        `${tag}: the 40 min LAG cell is var(--amber) (${amberOn ? amberOn.color : 'none'} vs ${m.amber})`);
      check(plain && plain.color !== m.amber, `${tag}: the current LAG cell is not amber (${plain ? plain.color : 'none'})`);
      for (const [id, sha] of Object.entries(FLY_SHAS)) {
        const r = m.fly.find((x) => x.cells.MACHINE === id);
        check(r && r.visible && r.cells.SHA === sha, `${tag}: Fly machine ${id} shows sha ${sha} (${r ? r.cells.SHA : 'no row'})`);
      }
      for (const [el, props] of Object.entries(m.computed)) {
        if (props) for (const [p, v] of Object.entries(props)) table.push([themeId, width, el, p, v]);
      }
      table.push([themeId, width, 'var(--amber)', 'color', m.amber]);
      await shoot(page, themeId, width);

      // A click on LAG: the head reads ascending and bw-alpha (lag 0) leads,
      // where LAST PING desc put bw-beta first.
      const firstBefore = rowsOf(m)[0] ? rowsOf(m)[0].cells.BOX : null;
      await page.locator('.section', { hasText: 'ORGO BOXES' }).locator('thead th button', { hasText: /^\s*LAG/ }).click({ timeout: 5000 });
      await page.waitForTimeout(200);
      const after = await page.evaluate(measure);
      const lagHead = after.orgo && after.orgo.heads.find((h) => h.text === 'LAG');
      const firstAfter = rowsOf(after)[0] ? rowsOf(after)[0].cells.BOX : null;
      check(lagHead && lagHead.sort === 'ascending' && firstBefore === 'bw-beta' && firstAfter === 'bw-alpha',
        `${tag}: a click on LAG sorts by it (aria-sort ${lagHead ? lagHead.sort : 'none'}, first row ${firstBefore} -> ${firstAfter})`);
      check(errors.length === 0, `${tag}: no page errors${errors.length ? ` (${errors.join(' | ')})` : ''}`);
      await page.close();
    }
  }

  // The status feed down: LAG and SHA say `unavailable`, never `current`.
  boxesDown = true;
  const { page, errors } = await fixturePage(browser, `${origin}/machines`, 'mill', 'dark', 1440, 900);
  await settle(page, orgoReady);
  const m = await page.evaluate(measure);
  const lags = rowsOf(m).map((r) => r.cells.LAG);
  check(lags.length > 0 && lags.every((t) => t === 'unavailable'), `503 boxes feed: every LAG cell reads unavailable (${lags.join(', ') || 'no rows'})`);
  check(!lags.includes('current'), '503 boxes feed: no LAG cell reads current');
  check(rowsOf(m).every((r) => r.cells.SHA === 'unavailable'), `503 boxes feed: every SHA cell reads unavailable (${rowsOf(m).map((r) => r.cells.SHA).join(', ')})`);
  check(errors.length === 0, `503 boxes feed: no page errors${errors.length ? ` (${errors.join(' | ')})` : ''}`);
  await page.close();
}

async function runDeployed(browser) {
  for (const [themeId, scheme] of THEMES) {
    for (const [width, height] of VIEWPORTS) {
      const tag = `${themeId} ${width}px`;
      const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, colorScheme: scheme });
      await ctx.addCookies([{ name: 'dash', value: cookie, url: base }]);
      const page = await ctx.newPage();
      await page.addInitScript((id) => { window.localStorage.setItem('ui.theme', id); }, themeId);
      await page.goto(`${base}/machines`, { waitUntil: 'networkidle' });
      await settle(page, orgoReady);
      const m = await page.evaluate(measure);
      check(!m.signedOut, `${tag}: not the NOT SIGNED IN screen`);
      check(m.orgo !== null, `${tag}: the ORGO BOXES table renders`);
      common(m, tag);
      for (const [el, props] of Object.entries(m.computed)) {
        if (props) for (const [p, v] of Object.entries(props)) table.push([themeId, width, el, p, v]);
      }
      table.push([themeId, width, 'var(--amber)', 'color', m.amber]);
      await shoot(page, themeId, width);
      await ctx.close();
    }
  }
}

let browser = null;
try {
  fs.mkdirSync(shotDir, { recursive: true });
  // CHROMIUM_PATH: a box whose playwright and browser builds have drifted apart.
  browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  if (base) await runDeployed(browser);
  else await runFixture(browser);
  const md = ['| theme | width | element | property | value |', '|---|---|---|---|---|',
    ...table.map((r) => `| ${r.join(' | ')} |`)].join('\n');
  fs.writeFileSync(path.join(shotDir, 'computed.md'), `${md}\n`);
  console.log(`table ${path.join(shotDir, 'computed.md')}`);
  const onDisk = shots.filter((f) => fs.existsSync(f) && fs.statSync(f).size > 0);
  check(onDisk.length === THEMES.length * VIEWPORTS.length, `${onDisk.length} of ${THEMES.length * VIEWPORTS.length} screenshots on disk`);
} catch (e) {
  check(false, `the drive threw: ${e && e.message ? e.message : e}`);
} finally {
  if (browser) await browser.close().catch(() => {});
  if (server.listening) server.close();
}
console.log(fail.length ? `${fail.length} check(s) failed` : 'ok: all checks passed');
process.exit(fail.length ? 1 : 0);
