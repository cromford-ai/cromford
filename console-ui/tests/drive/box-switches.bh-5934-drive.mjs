// Headless drive of the BUILT bundle for the /flags BOX SWITCHES section (BH-5934).
//
// Not a unit test. It serves dist/ over http with the two reads /flags makes
// stubbed (/api/coord/flags with two flag rows, /api/coord/settings with three
// ON box rows, one OFF box row and one fleet row; any other /api/* read
// answers {}), opens /flags in chromium at 1280x900 and 375x780, in the mill
// (dark) and paper (light) themes, and measures what the ticket promised:
//   - the BOX SWITCHES title and its table are visible, with the 3 ON rows
//     only (the OFF row and the fleet row are not listed);
//   - every column head carries aria-sort, and a click on SWITCH sorts by it;
//   - the new table has the same computed type and colour as the ALL FLAGS
//     table above it (the console design, not a new style);
//   - 375px: the body never scrolls sideways; the wide table scrolls inside
//     its own overflow-x container.
// It writes one screenshot per theme and viewport and computed.md (the
// computed-value table) to --shots (default ./shots).
//
//   npm run build && node tests/drive/box-switches.bh-5934-drive.mjs [--shots <dir>]
//
// Exit 0 = every check passed, 1 = a check failed, 2 = a bad argument or no dist/.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  if (args[i] !== '--shots' || args[i + 1] === undefined) {
    console.error(`usage: node tests/drive/box-switches.bh-5934-drive.mjs [--shots <dir>] (bad argument: ${args[i]})`);
    process.exit(2);
  }
}
const shotDir = path.resolve(args.includes('--shots') ? args[args.indexOf('--shots') + 1] : path.join(root, 'shots'));

if (!fs.existsSync(path.join(dist, 'index.html'))) {
  console.error('dist/ is not built — run `npm run build` first');
  process.exit(2);
}

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch {
  process.env.NODE_PATH = execSync('npm root -g').toString().trim();
  require('node:module').Module._initPaths();
  ({ chromium } = require('playwright'));
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };

// Fixed timestamps: the SET AT cell renders an age, so the picture changes
// with the day, but no check below reads it.
const setting = (key, value, actor, at) => ({ key, value, actor, updated_at: at });
const EXTRA = {
  '/api/coord/flags': {
    flags: [
      { scope: 'fleet', name: 'paused-project-3', value: '1', cleared_at: null, set_by: 'operator@example.com', set_at: '2026-10-16T09:00:00Z', reason: 'client freeze' },
      { scope: 'fly-1', name: 'automerge-disabled', value: '1', cleared_at: null, set_by: 'ops', set_at: '2026-10-16T08:00:00Z', reason: 'a long reason that has to wrap inside its own cell at 375px' }
    ]
  },
  '/api/coord/settings': {
    settings: [
      setting('switch.fly-disabled.fly-1', '1', 'operator@example.com', '2026-10-16T10:00:00Z'),
      setting('switch.review-disabled.box-project-3-2', 'on', 'ops', '2026-10-15T22:00:00Z'),
      setting('switch.automerge-disabled.hub', 'true', 'operator@example.com', '2026-10-14T07:30:00Z'),
      setting('switch.triage-disabled.project-4-1', '0', 'ops', '2026-10-13T12:00:00Z'),
      setting('switch.fly-disabled', '1', 'ops', '2026-10-12T12:00:00Z')
    ]
  }
};
const ON_BOXES = ['box-project-3-2', 'fly-1', 'hub'];
const THEMES = [['mill', 'dark'], ['paper', 'light']];
const VIEWPORTS = [[1280, 900], [375, 780]];

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(EXTRA[url.pathname] || {}));
  }
  let file = path.join(dist, url.pathname === '/' ? 'index.html' : url.pathname.slice(1));
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(dist, 'index.html');
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  return res.end(fs.readFileSync(file));
});

const fail = [];
const check = (ok, what) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) fail.push(what);
};

// In the page: the two sections by title, and for each the computed values a
// reader sees, plus visibility and the BOX SWITCHES rows.
function measure() {
  const sections = [...document.querySelectorAll('.section')];
  const byTitle = (t) => sections.find((s) => s.querySelector('.section__title')?.textContent.trim() === t);
  const visible = (el) => {
    if (!el || el.getClientRects().length === 0) return false;
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0 && r.width > 0 && r.height > 0;
  };
  const pick = (el, props) => (el ? Object.fromEntries(props.map((p) => [p, getComputedStyle(el)[p]])) : null);
  const TEXT = ['fontFamily', 'fontSize', 'fontWeight', 'color', 'textTransform', 'letterSpacing'];
  const side = (s) => {
    if (!s) return null;
    const table = s.querySelector('table');
    let wrap = table && table.parentElement;
    while (wrap && wrap !== s && !['auto', 'scroll'].includes(getComputedStyle(wrap).overflowX)) wrap = wrap.parentElement;
    return {
      titleVisible: visible(s.querySelector('.section__title')),
      tableVisible: visible(table),
      heads: table ? [...table.querySelectorAll('th')].map((th) => ({ text: th.textContent.trim(), sort: th.getAttribute('aria-sort') })) : [],
      rows: table ? [...table.querySelectorAll('tbody tr')].filter(visible).map((tr) => [...tr.querySelectorAll('td')].map((td) => td.textContent.trim())) : [],
      scroller: wrap && wrap !== s ? { overflowX: getComputedStyle(wrap).overflowX, clientWidth: wrap.clientWidth, scrollWidth: wrap.scrollWidth } : null,
      computed: {
        title: pick(s.querySelector('.section__title'), TEXT),
        // The sorted head is brighter than the others, so each state is
        // compared with the same state in the other table.
        th: pick(table && table.querySelector('th[aria-sort="none"]'), [...TEXT, 'borderBottomColor']),
        thSorted: pick(table && table.querySelector('th[aria-sort="ascending"], th[aria-sort="descending"]'), TEXT),
        td: pick(table && table.querySelector('tbody td'), [...TEXT, 'paddingTop', 'paddingLeft']),
        link: pick(table && table.querySelector('tbody td a'), ['color', 'textDecorationLine'])
      }
    };
  };
  return {
    flags: side(byTitle('ALL FLAGS')),
    box: side(byTitle('BOX SWITCHES')),
    page: { scrollWidth: document.documentElement.scrollWidth, innerWidth, background: getComputedStyle(document.body).backgroundColor }
  };
}

const table = [];

async function run() {
  fs.mkdirSync(shotDir, { recursive: true });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  // CHROMIUM_PATH: a box whose playwright and browser builds have drifted apart.
  const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  for (const [themeId, scheme] of THEMES) {
    for (const [width, height] of VIEWPORTS) {
      const tag = `${themeId} ${width}px`;
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1, colorScheme: scheme });
      await page.addInitScript((id) => { window.localStorage.setItem('ui.theme', id); }, themeId);
      const errors = [];
      page.on('pageerror', (e) => errors.push(String(e)));
      await page.goto(`${base}/flags`, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => [...document.querySelectorAll('.section__title')].some((t) => t.textContent.trim() === 'BOX SWITCHES')
        && document.querySelectorAll('.section table').length >= 2, null, { timeout: 15000 });
      await page.evaluate(() => document.fonts.ready);
      await page.waitForTimeout(300);

      const m = await page.evaluate(measure);
      check(m.box && m.box.titleVisible, `${tag}: the BOX SWITCHES title is visible`);
      check(m.box && m.box.tableVisible, `${tag}: the BOX SWITCHES table is visible`);
      const boxes = (m.box ? m.box.rows : []).map((r) => r[0]);
      check(JSON.stringify(boxes) === JSON.stringify(ON_BOXES), `${tag}: the ON rows only, sorted by BOX (${boxes.join(', ') || 'none'})`);
      check(!(m.box ? m.box.rows : []).some((r) => r.includes('triage-disabled')), `${tag}: the OFF row switch.triage-disabled.project-4-1 is not listed`);
      const heads = m.box ? m.box.heads : [];
      check(heads.length === 5 && heads.every((h) => h.sort), `${tag}: ${heads.length} column heads, each with aria-sort (${heads.map((h) => `${h.text}=${h.sort}`).join(' ')})`);
      check(m.page.scrollWidth <= m.page.innerWidth, `${tag}: no horizontal body scroll (scrollWidth ${m.page.scrollWidth} <= innerWidth ${m.page.innerWidth})`);
      check(m.box && m.box.scroller && m.box.scroller.overflowX === 'auto', `${tag}: the table sits in its own overflow-x:auto container (${m.box && m.box.scroller ? `${m.box.scroller.scrollWidth}/${m.box.scroller.clientWidth}px` : 'none'})`);
      for (const k of ['title', 'th', 'thSorted', 'td', 'link']) {
        const a = m.flags && m.flags.computed[k];
        const b = m.box && m.box.computed[k];
        const same = a && b && Object.keys(b).every((p) => p === 'paddingLeft' || a[p] === b[p]);
        check(same, `${tag}: BOX SWITCHES ${k} matches ALL FLAGS ${k}${same ? '' : ` (${JSON.stringify(a)} vs ${JSON.stringify(b)})`}`);
        if (b) for (const [p, v] of Object.entries(b)) table.push([themeId, width, k, p, a ? a[p] : '-', v]);
      }
      table.push([themeId, width, 'body', 'backgroundColor', '-', m.page.background]);

      // The shot is the first paint: the sort click below scrolls the table.
      const shot = path.join(shotDir, `flags-box-switches-${themeId}-${width}.png`);
      await page.screenshot({ path: shot, fullPage: true });
      console.log(`shot ${shot}`);

      // A click on SWITCH sorts by it: the head reads ascending and the first
      // row is the alphabetically first switch name.
      await page.locator('.section', { hasText: 'BOX SWITCHES' }).locator('th', { hasText: 'SWITCH' }).locator('button').click();
      await page.waitForFunction(() => [...document.querySelectorAll('.section')]
        .find((x) => x.querySelector('.section__title')?.textContent.trim() === 'BOX SWITCHES')
        ?.querySelector('th:nth-child(2)')?.getAttribute('aria-sort') !== 'none', null, { timeout: 5000 }).catch(() => {});
      const after = await page.evaluate(measure);
      const sw = after.box.heads.find((h) => h.text.startsWith('SWITCH'));
      check(sw && sw.sort === 'ascending' && after.box.rows[0][1] === 'automerge-disabled',
        `${tag}: a click on SWITCH sorts by it (${sw ? sw.sort : 'no head'}, first row ${after.box.rows[0] ? after.box.rows[0][1] : 'none'})`);

      check(errors.length === 0, `${tag}: no page errors${errors.length ? ` (${errors.join(' | ')})` : ''}`);
      await page.close();
    }
  }
  await browser.close();
  server.close();
  const md = ['| theme | width | element | property | ALL FLAGS | BOX SWITCHES |', '|---|---|---|---|---|---|',
    ...table.map((r) => `| ${r.join(' | ')} |`)].join('\n');
  fs.writeFileSync(path.join(shotDir, 'computed.md'), `${md}\n`);
  console.log(`table ${path.join(shotDir, 'computed.md')}`);
  console.log(fail.length ? `${fail.length} check(s) failed` : 'all checks passed');
  process.exit(fail.length ? 1 : 0);
}

run().catch((e) => { console.error(e); server.close(); process.exit(1); });
