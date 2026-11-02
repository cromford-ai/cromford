// Headless drive of /projects/:project/ready, the Ready screen (BH-8744,
// BH-7935.3).
//
// Not a unit test. It serves the BUILT dist/ over http, answers
// /api/coord/onboarding/ready/*, /api/coord/ai-accounts and the Project page
// reads from fixtures, opens the page in chromium in the mill (dark) and paper
// (light) themes at 1440 and 390 px, and checks what a user sees:
//   R1 nine .project-ready__card elements are visible
//   R2 each card's tag is visible with the fixture's expected text
//   R3 every card link is visible with href /config; a click lands on /config
//   R4 the AI account Choose click shows the sheet dialog; Escape closes it
//   R5 /p/cromford: the READY link is visible; the click lands on
//      /projects/cromford/ready and the band is visible
//   R6 at 390: document.documentElement.scrollWidth <= 390
//   R7 the two actions are visible with their hrefs
// Writes out/bh-8744-ready-computed.json and out/project-ready-<theme>-<width>.png
// (console-ui/tests/drive/out/, git-ignored).
//
//   npm run build && node tests/drive/project-ready.bh-8744-drive.mjs
//
// Exit 0 = every check passed and the 4 PNGs and the JSON are on disk,
// 1 = a check failed, 2 = no dist/ (nothing is written).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');
const outDir = path.join(here, 'out');
if (!fs.existsSync(path.join(dist, 'index.html'))) {
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
const P = 'cromford';
// The worker's answer for a seeded project (worker test A1's shape).
const ANSWER = {
  project: P, repo: 'example-org/cromford', prod: 'https://console.example', box: 'hub-box', tailnet: true,
  account: 'bh-label', fly: false,
  facts: { state: 'pass', vercel: true, qa_account: false, migration_token: true, checked_at: '2026-10-30T08:50:15.000Z' }
};
const TAGS = ['connected', 'connected', 'not set', 'not set', 'connected', 'fleet default', 'connected', 'not checked', 'bh-label'];

const SHELL = {
  '/api/dash/fleet': { snapshot_age_min: 1, watchdog: { boxes: { hub: '1m ago' } }, open_alerts: 0 },
  '/api/dash/projects': { projects: [{ project: P }], projects_source: 'fleet_status', snapshot_age_min: 1 },
  '/api/coord/whoami': { access: 'on', email: 'operator@example.com' },
  '/api/coord/ai-accounts': { accounts: [] }
};
const send = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;
  if (p.startsWith('/api/')) {
    req.on('data', () => {});
    req.on('end', () => {
      if (p === `/api/coord/onboarding/ready/${P}`) return send(res, 200, ANSWER);
      if (p.startsWith('/api/coord/onboarding/ready/')) return send(res, 404, { error: 'unknown_project' });
      if (p.startsWith('/api/dash/p/')) return send(res, 200, { runs: [], builds: [], alerts: [], board: {} });
      if (/^\/api\/coord\/settings\//.test(p)) return send(res, 200, { setting: null });
      return send(res, 200, SHELL[p] || {});
    });
    return;
  }
  let file = path.join(dist, p === '/' ? 'index.html' : p.slice(1));
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(dist, 'index.html');
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  res.end(fs.readFileSync(file));
});

const fail = [];
const check = (ok, what) => {
  console.log(`${ok ? 'pass' : 'FAIL'} ${what}`);
  if (!ok) fail.push(what);
};

async function newPage(browser, themeId, scheme, width, height) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1, colorScheme: scheme });
  await page.addInitScript((id) => { window.localStorage.setItem('ui.theme', id); }, themeId);
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  return { page, errors };
}
const visible = (loc) => loc.isVisible().catch(() => false);

// In the page: the computed values for the PR body table.
function measure() {
  const q = (s) => document.querySelector(s);
  const pick = (el, props) => (el ? Object.fromEntries(props.map((p) => [p, getComputedStyle(el)[p]])) : null);
  return {
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth,
    columns: q('.project-ready__grid') ? getComputedStyle(q('.project-ready__grid')).gridTemplateColumns.split(' ').length : 0,
    computed: {
      body: pick(document.body, ['backgroundColor', 'color', 'fontFamily']),
      h1: pick(q('.project-ready h1'), ['fontFamily', 'fontSize', 'color']),
      '.project-ready__band': pick(q('.project-ready__band'), ['backgroundColor', 'borderColor', 'borderRadius', 'padding']),
      '.project-ready__band-title': pick(q('.project-ready__band-title'), ['fontFamily', 'fontSize', 'color']),
      '.project-ready__card': pick(q('.project-ready__card'), ['backgroundColor', 'borderColor', 'borderRadius', 'padding']),
      '.project-ready__card .tag': pick(q('.project-ready__card .tag'), ['color', 'borderColor', 'fontFamily', 'fontSize']),
      '.project-ready__action': pick(q('.project-ready__action'), ['borderRadius', 'height', 'backgroundColor', 'color'])
    }
  };
}

const THEMES = [['mill', 'dark'], ['paper', 'light']];
const VIEWPORTS = [[1440, 900], [390, 844]];
const computed = [];
const shots = [];

async function run(browser) {
  await new Promise((r) => server.listen(0, r));
  const origin = `http://127.0.0.1:${server.address().port}`;

  for (const [themeId, scheme] of THEMES) {
    for (const [width, height] of VIEWPORTS) {
      const tag = `${themeId} ${width}px`;
      const { page, errors } = await newPage(browser, themeId, scheme, width, height);

      // R5: reach the screen from the Project page.
      await page.goto(`${origin}/p/${P}`, { waitUntil: 'domcontentloaded' });
      const readyLink = page.locator(`a[href="/projects/${P}/ready"]`).first();
      await readyLink.waitFor({ state: 'visible', timeout: 15000 }).catch(() => {});
      check(await visible(readyLink) && (await readyLink.textContent()).trim() === 'READY', `${tag} R5: the READY link is visible`);
      await readyLink.click();
      await page.waitForSelector('.project-ready__band', { state: 'visible', timeout: 10000 }).catch(() => {});
      check(new URL(page.url()).pathname === `/projects/${P}/ready` && await visible(page.locator('.project-ready__band')),
        `${tag} R5: the click lands on the Ready screen with the band visible`);

      // R1, R2.
      await page.waitForSelector('.project-ready__card', { state: 'visible', timeout: 10000 }).catch(() => {});
      const cards = page.locator('.project-ready__card');
      check(await cards.count() === 9, `${tag} R1: nine cards (${await cards.count()})`);
      for (let i = 0; i < 9; i++) {
        const card = cards.nth(i);
        const t = card.locator('.tag');
        const okTag = await visible(card) && await visible(t) && (await t.textContent()).trim() === TAGS[i];
        check(okTag, `${tag} R1/R2: card ${i + 1} visible with tag "${TAGS[i]}"`);
      }

      // R3: the eight card links.
      const links = page.locator('.project-ready__card a');
      check(await links.count() === 8, `${tag} R3: eight card links`);
      for (let i = 0; i < await links.count(); i++) {
        const a = links.nth(i);
        const href = await a.getAttribute('href');
        check(await visible(a) && href === '/config', `${tag} R3: card link ${i + 1} visible, href ${href}`);
      }

      // R7: the two actions.
      const ticket = page.locator('.project-ready__actions a[href="https://github.com/example-org/cromford/issues/new"]');
      const open = page.locator(`.project-ready__actions a[href="/p/${P}"]`);
      check(await visible(ticket) && await visible(open), `${tag} R7: File the first ticket and Open the project are visible`);

      // R6 and the computed values.
      const m = await page.evaluate(measure);
      check(m.scrollWidth <= m.innerWidth, `${tag} R6: no horizontal body scroll (${m.scrollWidth} <= ${m.innerWidth})`);
      if (width === 390) check(m.columns === 1, `${tag} R6: one card column (${m.columns})`);
      computed.push({ theme: themeId, width, ...m.computed });
      const file = path.join(outDir, `project-ready-${themeId}-${width}.png`);
      await page.screenshot({ path: file, fullPage: true });
      shots.push(file);

      // R4: the AI account sheet.
      const choose = page.locator('.project-ready__card[data-card="account"] button:has-text("Choose")');
      check(await visible(choose), `${tag} R4: the AI account Choose button is visible`);
      await choose.click();
      const sheet = page.locator(`[role="dialog"][aria-label="AI account for ${P}"]`);
      await sheet.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
      check(await visible(sheet), `${tag} R4: the AI account sheet is visible`);
      // The sheet binds Escape in an effect that runs after paint; a key sent
      // in the same frame as the first render reaches no listener.
      const focused = await page.waitForFunction(
        (sel) => { const d = document.querySelector(sel); return !!d && d.contains(document.activeElement); },
        `[role="dialog"][aria-label="AI account for ${P}"]`, { timeout: 5000 }
      ).then(() => true, () => false);
      check(focused, `${tag} R4: focus moves into the sheet`);
      await page.keyboard.press('Escape');
      await sheet.waitFor({ state: 'hidden', timeout: 5000 }).catch(() => {});
      check(!(await visible(sheet)), `${tag} R4: Escape closes the sheet`);

      // R3: a card link click lands on /config.
      await links.first().click();
      await page.waitForURL((u) => new URL(u).pathname === '/config', { timeout: 5000 }).catch(() => {});
      check(new URL(page.url()).pathname === '/config', `${tag} R3: a card link click lands on /config (${page.url()})`);
      check(errors.length === 0, `${tag}: no page errors${errors.length ? ` (${errors.join(' | ')})` : ''}`);
      await page.close();
    }
  }
}

let browser = null;
try {
  fs.mkdirSync(outDir, { recursive: true });
  browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  await run(browser);
  fs.writeFileSync(path.join(outDir, 'bh-8744-ready-computed.json'), `${JSON.stringify(computed, null, 2)}\n`);
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
