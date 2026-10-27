// Headless drive of /projects/new, the two-step onboarding form (BH-7999,
// BH-7935.2).
//
// Not a unit test. It serves the BUILT dist/ over http, answers
// /api/coord/onboarding/*, /api/coord/settings/* and the Fleet reads from
// fixtures, logs every POST, opens the page in chromium in the mill (dark) and
// paper (light) themes, and checks what a user sees:
//   D1 `/`: the PROJECTS NEW link opens /projects/new; #onboard-slug is
//      visible while the repos read is still held (1500 ms)
//   D2 `project-11`: Continue visible and disabled; `example-org/project-11`:
//      Continue enabled, the detect card shows its skeleton, then the facts
//      dl with main and the GitHub link. visible:false shows Install, error
//      shows Retry
//   D3 Advanced: project project-11, prefix RA, Dedicated and Fly pool
//      disabled with `wave 6`; D3b the New repo segment shows owner, name and
//      three templates
//   D4 step 2: GitHub Issues checked; Product board disabled with `soon`;
//      Linear, Jira, App board disabled with `wave 3`. D4b Issues off: nothing
//      checked, Start setup disabled, the Issues text visible
//   D5 the last Review line is visible; the AI account line has no input
//   D6 390 px: no horizontal body scroll; the bar buttons fill the bar
//   D7 a double Start setup click: exactly 1 POST with an Idempotency-Key,
//      then the URL is /projects/project-11/setup/ob_...
// Writes out/bh-7935-onboard-computed.json and out/onboard-<theme>-<width>.png
// (console-ui/tests/drive/out/, git-ignored).
//
//   npm run build && node tests/drive/onboard.bh-7935-drive.mjs
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
const RUN_ID = 'ob_0123456789abcdef0123';
const INSTALL = 'https://github.com/apps/fixture-app/installations/new';
const FACTS = { default_branch: 'main', has_issues: true, open_issues: 4 };

// Per page: which detect answer the fixture gives, and the settings rows.
let detectMode = 'ok';
let detectCalls = 0;
let reposDelay = 0;
const SETTINGS = { 'onboarding.product_board_ready': '0', 'onboarding.detect_poll_ms': '300', 'onboarding.detect_poll_max_s': '120' };
function detectAnswer() {
  detectCalls += 1;
  if (detectCalls === 1) return { state: 'pending' };
  if (detectMode === 'invisible') return { state: 'ok', visible: false, install_url: INSTALL };
  if (detectMode === 'error') return { state: 'error', error: 'gh: 404 Not Found' };
  if (detectMode === 'off') return { state: 'ok', visible: true, facts: { ...FACTS, has_issues: false }, install_url: INSTALL };
  return { state: 'ok', visible: true, facts: FACTS, install_url: INSTALL };
}

const log = [];
const SHELL = {
  '/api/dash/fleet': { snapshot_age_min: 1, watchdog: { boxes: { hub: '1m ago' } }, open_alerts: 0 },
  '/api/dash/projects': { projects: [], projects_source: 'fleet_status', snapshot_age_min: 1 },
  '/api/coord/whoami': { access: 'on', email: 'operator@example.com' }
};
const send = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;
  if (p.startsWith('/api/')) {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      if (req.method === 'POST') log.push({ path: p, key: req.headers['idempotency-key'] || null, body });
      const set = /^\/api\/coord\/settings\/(.+)$/.exec(p);
      if (set) {
        const key = decodeURIComponent(set[1]);
        return send(res, 200, { setting: key in SETTINGS ? { key, value: SETTINGS[key] } : null });
      }
      if (p === '/api/coord/onboarding/repos') {
        const answer = () => send(res, 200, { state: 'ok', repos: ['example-org/project-11', 'example-org/project-16'] });
        return reposDelay ? setTimeout(answer, reposDelay) : answer(); // fixed-wait: ok the fixture server holds this answer on purpose so D1 sees the input first
      }
      if (p === '/api/coord/onboarding/repo') return send(res, 200, detectAnswer());
      if (p === '/api/coord/onboarding/runs' && req.method === 'POST') {
        return setTimeout(() => send(res, 201, { id: RUN_ID, state: 'queued', created: true }), 400); // fixed-wait: ok holds the create so a second click lands in flight
      }
      if (/^\/api\/coord\/onboarding\/runs\/ob_[0-9a-f]{20}$/.test(p)) return send(res, 404, { error: 'not_found' });
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
const visible = (page, sel) => page.locator(sel).first().isVisible().catch(() => false);
const reset = (mode = 'ok') => { detectMode = mode; detectCalls = 0; reposDelay = 0; };

// In the page: the computed values for the PR body table.
function measure() {
  const q = (s) => document.querySelector(s);
  const pick = (el, props) => (el ? Object.fromEntries(props.map((p) => [p, getComputedStyle(el)[p]])) : null);
  const bar = q('.onboard-bar');
  const buttons = bar ? [...bar.querySelectorAll('.btn')] : [];
  const cs = bar ? getComputedStyle(bar) : null;
  const inner = bar ? bar.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) : 0;
  const used = buttons.reduce((s, b) => s + b.getBoundingClientRect().width, 0) + (buttons.length - 1) * parseFloat(cs ? cs.columnGap || '0' : '0');
  return {
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth,
    bar: { inner: Math.round(inner), used: Math.round(used), heights: buttons.map((b) => Math.round(b.getBoundingClientRect().height)) },
    computed: {
      body: pick(document.body, ['backgroundColor', 'color', 'fontFamily']),
      '.page-headline h1, h1': pick(q('.onboard h1'), ['fontFamily', 'fontSize', 'color']),
      '#onboard-slug': pick(q('#onboard-slug'), ['height', 'borderRadius', 'backgroundColor', 'color', 'fontFamily']),
      '.onboard-bar': pick(bar, ['position', 'bottom', 'backgroundColor', 'gap']),
      '.onboard-bar .btn--primary': pick(q('.onboard-bar .btn--primary'), ['borderRadius', 'height', 'backgroundColor', 'color']),
      '.onboard-detect': pick(q('.onboard-detect'), ['backgroundColor', 'borderColor', 'borderRadius'])
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

  // D1-D6, per theme and width.
  for (const [themeId, scheme] of THEMES) {
    for (const [width, height] of VIEWPORTS) {
      const tag = `${themeId} ${width}px`;
      reset();
      reposDelay = 1500;
      const { page, errors } = await newPage(browser, themeId, scheme, width, height);
      await page.goto(`${origin}/`, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('a[href="/projects/new"]', { state: 'visible', timeout: 15000 }).catch(() => {});
      check(await visible(page, 'a[href="/projects/new"]'), `${tag} D1: the PROJECTS NEW link is visible`);
      await page.click('a[href="/projects/new"]');
      const early = await page.waitForSelector('#onboard-slug', { state: 'visible', timeout: 1200 }).then(() => true, () => false);
      check(early && new URL(page.url()).pathname === '/projects/new', `${tag} D1: /projects/new with #onboard-slug visible before the repos answer`);

      await page.fill('#onboard-slug', 'project-11');
      check(await visible(page, 'button:has-text("Continue")') && await page.isDisabled('button:has-text("Continue")'),
        `${tag} D2: Continue visible and disabled for a bare name`);
      await page.fill('#onboard-slug', 'example-org/project-11');
      check(!(await page.isDisabled('button:has-text("Continue")')), `${tag} D2: Continue enabled with only a slug`);
      const skel = await page.waitForSelector('.onboard-detect .skel', { state: 'visible', timeout: 3000 }).then(() => true, () => false);
      check(skel, `${tag} D2: the detect card shows the skeleton while pending`);
      await page.waitForSelector('.onboard-facts', { state: 'visible', timeout: 5000 }).catch(() => {});
      check(await visible(page, '.onboard-facts') && /main/.test(await page.textContent('.onboard-facts')), `${tag} D2: the facts dl is visible with main`);
      check(await visible(page, '.onboard-facts a[href="https://github.com/example-org/project-11"]'), `${tag} D2: the GitHub link is visible`);

      await page.click('.onboard-adv > summary');
      check(await page.inputValue('#onboard-project') === 'project-11' && await page.inputValue('#onboard-prefix') === 'RA',
        `${tag} D3: Advanced holds project-11 and RA`);
      check(await page.isDisabled('input[name="onboard-box"][value="dedicated"]') && await page.isDisabled('input[name="onboard-box"][value="fly"]')
        && await visible(page, '.onboard-box .tag:has-text("wave 6")'), `${tag} D3: Dedicated and Fly pool disabled, wave 6 visible`);

      const m = await page.evaluate(measure);
      check(m.scrollWidth <= m.innerWidth, `${tag} D6: no horizontal body scroll (${m.scrollWidth} <= ${m.innerWidth})`);
      if (width < 720) {
        check(Math.abs(m.bar.inner - m.bar.used) <= 2, `${tag} D6: the bar buttons fill the bar (${m.bar.used} of ${m.bar.inner})`);
        check(m.bar.heights.every((x) => x >= 44), `${tag} D6: bar buttons >= 44px (${m.bar.heights})`);
      }
      computed.push({ theme: themeId, width, ...m.computed });
      const file = path.join(outDir, `onboard-${themeId}-${width}.png`);
      await page.screenshot({ path: file });
      shots.push(file);

      await page.click('button:has-text("Continue")');
      check(await page.getAttribute('[role="radio"][data-value="github-issues"]', 'aria-checked') === 'true', `${tag} D4: GitHub Issues is checked`);
      check(await page.isDisabled('[role="radio"][data-value="board"]') && await visible(page, '[data-value="board"] .tag:has-text("soon")'),
        `${tag} D4: Product board disabled with soon visible`);
      for (const v of ['linear', 'jira', 'app-board']) {
        check(await page.isDisabled(`[role="radio"][data-value="${v}"]`) && await visible(page, `[data-value="${v}"] .tag:has-text("wave 3")`),
          `${tag} D4: ${v} disabled with wave 3 visible`);
      }
      check(await visible(page, '.onboard-review__last:has-text("Nothing is built until a ticket is labeled.")'), `${tag} D5: the last Review line is visible`);
      check(await page.locator('.onboard-review input').count() === 0 && await visible(page, '.onboard-review dd:has-text("fleet pool")'),
        `${tag} D5: AI account fleet pool, no input`);
      const m2 = await page.evaluate(measure);
      check(m2.scrollWidth <= m2.innerWidth, `${tag} D6: no horizontal body scroll on step 2 (${m2.scrollWidth})`);
      check(errors.length === 0, `${tag}: no page errors${errors.length ? ` (${errors.join(' | ')})` : ''}`);
      await page.close();
    }
  }

  // D2 the two other detect answers, D3b the New repo segment.
  for (const [mode, sel, what] of [['invisible', `a[href="${INSTALL}"]`, 'Install link'], ['error', 'button:has-text("Retry")', 'Retry']]) {
    reset(mode);
    const { page } = await newPage(browser, 'mill', 'dark', 1440, 900);
    await page.goto(`${origin}/projects/new`, { waitUntil: 'networkidle' });
    await page.fill('#onboard-slug', 'example-org/project-11');
    const shown = await page.waitForSelector(sel, { state: 'visible', timeout: 5000 }).then(() => true, () => false);
    check(shown, `D2 ${mode}: a visible ${what}`);
    await page.close();
  }
  {
    reset();
    const { page } = await newPage(browser, 'mill', 'dark', 390, 844);
    await page.goto(`${origin}/projects/new`, { waitUntil: 'networkidle' });
    await page.click('[role="radio"][data-value="new"]');
    const ok = await visible(page, '#onboard-new-owner') && await visible(page, '#onboard-new-name')
      && await page.locator('[role="radio"][data-value="nextjs"], [role="radio"][data-value="worker"], [role="radio"][data-value="empty"]').count() === 3;
    check(ok, 'D3b: New repo shows owner, name and three templates');
    check(await page.isDisabled('button:has-text("Continue")') && await visible(page, '.onboard-hint:has-text("Create the repo first.")'),
      'D3b: Continue disabled with "Create the repo first."');
    await page.close();
  }

  // D4b Issues off.
  {
    reset('off');
    const { page } = await newPage(browser, 'paper', 'light', 1440, 900);
    await page.goto(`${origin}/projects/new`, { waitUntil: 'networkidle' });
    await page.fill('#onboard-slug', 'example-org/project-11');
    await page.waitForSelector('.onboard-facts', { state: 'visible', timeout: 5000 }).catch(() => {});
    await page.click('button:has-text("Continue")');
    const none = await page.locator('[role="radio"][aria-checked="true"]').count();
    check(none === 0, `D4b: no tracker checked (${none})`);
    check(await page.isDisabled('button:has-text("Start setup")'), 'D4b: Start setup disabled');
    check(await visible(page, 'text=Issues are off in this repo.'), 'D4b: the Issues text is visible');
    await page.close();
  }

  // D7 a double click: one POST with a key, then the setup line URL.
  {
    reset();
    log.length = 0;
    const { page } = await newPage(browser, 'mill', 'dark', 1440, 900);
    await page.goto(`${origin}/projects/new`, { waitUntil: 'networkidle' });
    await page.fill('#onboard-slug', 'example-org/project-11');
    await page.waitForSelector('.onboard-facts', { state: 'visible', timeout: 5000 }).catch(() => {});
    await page.click('button:has-text("Continue")');
    await page.dblclick('button:has-text("Start setup")');
    await page.waitForURL(/\/projects\/project-11\/setup\//, { timeout: 5000 }).catch(() => {});
    const posts = log.filter((l) => l.path === '/api/coord/onboarding/runs');
    check(posts.length === 1 && /^[0-9a-f-]{36}$/.test(posts[0].key || ''), `D7: exactly 1 POST with an Idempotency-Key (${posts.length})`);
    check(new URL(page.url()).pathname === `/projects/project-11/setup/${RUN_ID}`, `D7: the setup line URL (${page.url()})`);
    await page.close();
  }
}

let browser = null;
try {
  fs.mkdirSync(outDir, { recursive: true });
  browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  await run(browser);
  fs.writeFileSync(path.join(outDir, 'bh-7935-onboard-computed.json'), `${JSON.stringify(computed, null, 2)}\n`);
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
