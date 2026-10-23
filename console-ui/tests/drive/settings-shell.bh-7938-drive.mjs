// Headless drive of the BUILT bundle for the settings side menu (BH-7938).
//
// Not a unit test. It serves dist/ over http with every /api/ read stubbed
// (the project list holds two projects, every other read answers {}), and
// opens the console in chromium at 1440px and 390px:
//   - /settings lands on /settings/fleet/lanes (the redirect, through App);
//   - at 1440 the menu sits left of the page;
//   - at 390 the body does not scroll sideways, .settings-menu is one row
//     (flex-wrap nowrap, overflow-x auto) and every chip is 44px high or more.
//
//   npm run build && node tests/drive/settings-shell.bh-7938-drive.mjs [--shots <dir>]
//
// Exit code is the verdict. A box with no playwright or no chromium prints
// "SKIP: no chromium" and exits 0: that is NOT a pass, and the PR records it
// as "[NOTE] not verified here: 390px drive".

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
  '/api/dash/projects': { projects: [{ project: 'zeta-fixture' }, { project: 'alpha-fixture' }] }
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

async function run() {
  if (!fs.existsSync(path.join(dist, 'index.html'))) {
    console.error('dist/ is not built — run `npm run build` first');
    process.exit(2);
  }
  const chromium = loadChromium();
  let browser = null;
  if (chromium) {
    try {
      // CHROMIUM_PATH: a box whose playwright and browser builds have drifted apart.
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

  for (const [name, width, height] of [['desktop', 1440, 900], ['phone', 390, 844]]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    await page.goto(`${base}/settings`, { waitUntil: 'networkidle' });
    await page.waitForSelector('nav.settings-menu', { timeout: 15000 });
    await page.waitForSelector('nav.settings-menu a[href="/settings/p/alpha-fixture"]', { timeout: 15000 });
    const where = await page.evaluate(() => location.pathname);
    check(where === '/settings/fleet/lanes', `${name}: /settings lands on ${where}`);
    await page.screenshot({ path: path.join(shotDir, `settings-shell-${name}.png`), fullPage: true });

    if (width >= 1000) {
      const [menu, body] = await page.evaluate(() => ['.settings-menu', '.settings-shell__page']
        .map((s) => document.querySelector(s).getBoundingClientRect().toJSON()));
      check(menu.right <= body.left, `${name}: menu (right ${menu.right}) sits left of the page (left ${body.left})`);
    } else {
      const sw = await page.evaluate(() => document.documentElement.scrollWidth);
      check(sw <= width, `${name}: documentElement.scrollWidth ${sw} <= ${width}`);
      const cs = await page.evaluate(() => {
        const s = getComputedStyle(document.querySelector('.settings-menu'));
        return { wrap: s.flexWrap, ox: s.overflowX, dir: s.flexDirection };
      });
      check(cs.wrap === 'nowrap', `${name}: .settings-menu flex-wrap ${cs.wrap}`);
      check(cs.ox === 'auto', `${name}: .settings-menu overflow-x ${cs.ox}`);
      check(cs.dir === 'row', `${name}: .settings-menu flex-direction ${cs.dir}`);
      const heights = await page.evaluate(() => [...document.querySelectorAll('.settings-menu__item')]
        .map((el) => [el.textContent.trim(), el.getBoundingClientRect().height]));
      const short = heights.filter(([, hgt]) => hgt < 44);
      check(heights.length >= 8 && short.length === 0,
        `${name}: ${heights.length} chips, every one 44px or more${short.length ? ` (short: ${JSON.stringify(short)})` : ''}`);
      // The project menu at the same width, through a real click.
      await page.click('nav.settings-menu a[href="/settings/p/alpha-fixture"]');
      await page.waitForSelector('.settings-menu__back', { timeout: 15000 });
      const sw2 = await page.evaluate(() => document.documentElement.scrollWidth);
      check(sw2 <= width, `${name}: project menu scrollWidth ${sw2} <= ${width}`);
      await page.screenshot({ path: path.join(shotDir, `settings-shell-project-${name}.png`), fullPage: true });
    }
    await page.close();
  }

  await browser.close();
  server.close();
  if (fail.length) {
    console.log(`\n${fail.length} check(s) failed`);
    process.exit(1);
  }
  console.log('\nall checks passed');
}

run().catch((e) => { console.error(e); server.close(); process.exit(1); });
