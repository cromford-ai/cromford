// Headless drive of the BUILT bundle for the side menu (BH-9118).
//
// Not a unit test. It serves dist/ over http with every /api/ read stubbed
// (the staff roster holds three agents, every other read answers {}), and
// opens the console in chromium:
//   R1 at 375 and 1280, on /, /jobs, /costs, /world, /settings/fleet/lanes and
//      /staff, the document is no wider than the viewport;
//   R2 at 375 the menu is hidden; the hamburger opens it; Escape, a scrim tap
//      and a link tap each close it; the link lands on its screen;
//   R3 at 1280 the rail and a closed group survive a reload;
//   R4 at 1280 Tab reaches every side-menu item, and the focused item has an
//      outline;
//   R5 at 1280 Reports > COSTS, Logs > JOBS and Team > STAFF land on their
//      screens from / (the entry-point test).
//
//   npm run build && node tests/drive/sidemenu-drive.mjs [--shots <dir>]
//
// Exit code is the verdict. A box with no playwright or no chromium prints
// "SKIP: no chromium" and exits 0: that is NOT a pass, and the PR records it
// as "[NOTE] not verified here: browser drive".

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { navLink, SIDE_MENU, MENU_BUTTON } from './nav.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');

const args = process.argv.slice(2);
const shotDir = path.resolve(args.includes('--shots') ? args[args.indexOf('--shots') + 1] : path.join(root, 'shots'));

const require = createRequire(import.meta.url);
function loadChromium() {
  try { return require('playwright').chromium; } catch { /* try the global install */ }
  try {
    process.env.NODE_PATH = execSync('npm root -g').toString().trim();
    require('node:module').Module._initPaths();
    return require('playwright').chromium;
  } catch { return null; }
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };
const API = {
  '/api/coord/staff/roster': { agents: [{ name: 'archie' }, { name: 'watchman' }, { name: 'clerk' }] }
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(API[decodeURIComponent(url.pathname)] || {}));
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
const isVisible = (page, sel) => page.evaluate((s) => {
  const el = document.querySelector(s);
  if (!el) return false;
  const cs = getComputedStyle(el);
  const r = el.getBoundingClientRect();
  return cs.visibility !== 'hidden' && cs.display !== 'none' && r.right > 0 && r.width > 0;
}, sel);
const pathname = (page) => page.evaluate(() => location.pathname);

async function run() {
  if (!fs.existsSync(path.join(dist, 'index.html'))) {
    console.error('dist/ is not built — run `npm run build` first');
    process.exit(2);
  }
  const chromium = loadChromium();
  let browser = null;
  if (chromium) {
    try {
      browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
    } catch (e) {
      console.log(`chromium did not start: ${e.message.split('\n')[0]}`);
    }
  }
  if (!browser) {
    console.log('SKIP: no chromium');
    process.exit(0);
  }
  fs.mkdirSync(shotDir, { recursive: true });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;

  // R1: no sideways scroll at either width on six screens.
  for (const width of [375, 1280]) {
    const ctx = await browser.newContext({ viewport: { width, height: 800 }, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    for (const at of ['/', '/jobs', '/costs', '/world', '/settings/fleet/lanes', '/staff']) {
      await page.goto(`${base}${at}`, { waitUntil: 'networkidle' });
      await page.waitForSelector(SIDE_MENU, { state: 'attached', timeout: 15000 });
      const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
      check(sw === iw, `R1 ${width}px ${at}: scrollWidth ${sw} == innerWidth ${iw}`);
    }
    await page.goto(`${base}/`, { waitUntil: 'networkidle' });
    await page.screenshot({ path: path.join(shotDir, `sidemenu-${width}.png`), fullPage: false });
    await ctx.close();
  }

  // R2: the phone drawer.
  {
    const ctx = await browser.newContext({ viewport: { width: 375, height: 800 }, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    await page.goto(`${base}/`, { waitUntil: 'networkidle' });
    await page.waitForSelector(MENU_BUTTON, { timeout: 15000 });
    check(!(await isVisible(page, SIDE_MENU)), 'R2 375px: the menu is hidden by default');
    const bottom = await page.$$eval('.bottomnav a', (as) => as.map((a) => a.getAttribute('href')));
    check(bottom.join(' ') === '/ /now /kanban /alerts /needs', `R2 375px: the bottom nav holds five tabs (${bottom.join(' ')})`);
    const open = async () => { await page.click(MENU_BUTTON); await page.waitForSelector(`${SIDE_MENU}.sidemenu--open`); await page.waitForTimeout(250); };
    await open();
    check(await isVisible(page, SIDE_MENU), 'R2 375px: the hamburger opens the drawer');
    await page.screenshot({ path: path.join(shotDir, 'sidemenu-drawer-375.png') });
    const focused = await page.evaluate(() => document.activeElement && document.activeElement.getAttribute('href'));
    check(focused === '/world', `R2 375px: focus is on the first item (${focused})`);
    await page.keyboard.press('Escape');
    await page.waitForTimeout(250);
    check(!(await isVisible(page, SIDE_MENU)), 'R2 375px: Escape closes it');
    const back = await page.evaluate((s) => document.activeElement === document.querySelector(s), MENU_BUTTON);
    check(back, 'R2 375px: focus is back on the hamburger');
    await open();
    await page.mouse.click(360, 400);
    await page.waitForTimeout(250);
    check(!(await isVisible(page, SIDE_MENU)), 'R2 375px: a scrim tap closes it');
    await open();
    await page.click(navLink('/costs'));
    await page.waitForTimeout(250);
    check(await pathname(page) === '/costs', `R2 375px: COSTS lands on ${await pathname(page)}`);
    check(!(await isVisible(page, SIDE_MENU)), 'R2 375px: the link tap closed the drawer');
    await ctx.close();
  }

  // R3, R4, R5 at 1280.
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    await page.goto(`${base}/`, { waitUntil: 'networkidle' });
    await page.waitForSelector(navLink('/staff/archie'), { timeout: 15000 });
    check(await isVisible(page, SIDE_MENU), 'R5 1280px: the menu shows beside the page');
    check(!(await isVisible(page, MENU_BUTTON)), 'R5 1280px: no hamburger on a desktop');

    // R5: entry points from /.
    for (const [href, label] of [['/costs', 'Reports > COSTS'], ['/jobs', 'Logs > JOBS'], ['/staff', 'Team > STAFF'], ['/staff/watchman', 'Team > Watchman']]) {
      await page.goto(`${base}/`, { waitUntil: 'networkidle' });
      await page.click(navLink(href));
      await page.waitForTimeout(200);
      check(await pathname(page) === href, `R5 1280px: ${label} lands on ${await pathname(page)}`);
      const lit = await page.$$eval(`${SIDE_MENU} a[aria-current="page"]`, (as) => as.map((a) => a.getAttribute('href')));
      check(lit.join(' ') === href, `R5 1280px: ${href} lights ${lit.join(' ') || 'nothing'}`);
    }

    // R4: Tab reaches every item; the focused one has an outline.
    await page.goto(`${base}/`, { waitUntil: 'networkidle' });
    await page.waitForSelector(navLink('/staff/archie'), { timeout: 15000 });
    const want = await page.$$eval(`${SIDE_MENU} a`, (as) => as.map((a) => a.getAttribute('href')));
    const reached = new Set();
    const noOutline = [];
    for (let i = 0; i < 120 && reached.size < want.length; i++) {
      await page.keyboard.press('Tab');
      const hit = await page.evaluate((s) => {
        const el = document.activeElement;
        if (!el || !el.closest(s) || el.localName !== 'a') return null;
        const cs = getComputedStyle(el);
        return { href: el.getAttribute('href'), outline: cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0 };
      }, SIDE_MENU);
      if (hit) { reached.add(hit.href); if (!hit.outline) noOutline.push(hit.href); }
    }
    const missed = want.filter((h) => !reached.has(h));
    check(missed.length === 0, `R4 1280px: Tab reached ${reached.size} of ${want.length} items${missed.length ? ` (missed ${missed.join(' ')})` : ''}`);
    check(noOutline.length === 0, `R4 1280px: every focused item has an outline${noOutline.length ? ` (none on ${noOutline.join(' ')})` : ''}`);

    // R3: the rail and a closed group survive a reload.
    await page.click(`${SIDE_MENU} .sidemenu__collapse`);
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForSelector(SIDE_MENU);
    const railW = await page.evaluate((s) => document.querySelector(s).getBoundingClientRect().width, SIDE_MENU);
    check(await page.$(`${SIDE_MENU}.sidemenu--rail`) !== null && railW <= 60, `R3 1280px: the rail survives a reload (width ${railW})`);
    await page.screenshot({ path: path.join(shotDir, 'sidemenu-rail-1280.png') });
    await page.click(`${SIDE_MENU} .sidemenu__collapse`);
    const reports = `${SIDE_MENU} [data-group="reports"] .sidemenu__grouphead`;
    await page.click(reports);
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForSelector(reports);
    const expanded = await page.getAttribute(reports, 'aria-expanded');
    check(expanded === 'false' && await page.$(navLink('/costs')) === null, `R3 1280px: Reports stays closed after a reload (aria-expanded ${expanded})`);
    await ctx.close();
  }

  await browser.close();
  server.close();
  if (fail.length) { console.log(`\n${fail.length} check(s) failed`); process.exit(1); }
  console.log('\nall side-menu checks passed');
}

run().catch((e) => { console.error(e); process.exit(1); });
