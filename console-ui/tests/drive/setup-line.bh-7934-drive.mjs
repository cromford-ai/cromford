// Headless drive of the setup line, /projects/:project/setup/:runId (BH-7934.3).
//
// Not a unit test. It serves the BUILT dist/ over http with
// GET /api/coord/onboarding/runs/<id> answered from fixtures (one run id per
// case) and the two POSTs logged, opens the page in chromium in the mill
// (dark) and paper (light) themes, and checks what a user sees:
//   D1 1440: .setup-strip visible, 7 `ol.setup-stations > li`, on the failed
//      run a visible .setup-fixbox, button.setup-retry and a.setup-fix;
//      details.setup-log opens on a click and shows a visible pre
//   D2 390: the strip is display:none, the list is visible, no horizontal
//      body scroll, Retry and Cancel are at least 44px high
//   D3 Cancel opens a visible .modal and window.confirm is never called;
//      Escape closes it with no POST; CANCEL RUN sends exactly one POST
//   D4 a Retry click sends exactly one POST .../retry with body {}, and the
//      page then shows the label station QUEUED
//   D5 a GET held 1500 ms: .setup-skeleton is visible before the answer
//   D6 a done run: a.setup-open has href /p/demo and no second GET in 6 s;
//      a running run: a second GET within 6 s
//   D7 a 500 first load shows the ErrorBox; a 404 shows "No setup run"; an
//      excerpt `<img src=x onerror=…>` makes no img element in the fix box
// Viewport shots setup-<theme>-<width>.png and computed.md (theme, width,
// element, property, value) go to --shots (default ./shots, git-ignored).
//
//   npm run build && node tests/drive/setup-line.bh-7934-drive.mjs [--shots <dir>]
//
// Exit 0 = every check passed and the 4 PNGs and computed.md are on disk,
// 1 = a check failed, 2 = a bad argument or no dist/ (nothing is written).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');
const USAGE = 'usage: node tests/drive/setup-line.bh-7934-drive.mjs [--shots <dir>]';

const args = process.argv.slice(2);
const opts = {};
for (let i = 0; i < args.length; i += 2) {
  if (args[i] !== '--shots' || args[i + 1] === undefined || args[i + 1].startsWith('--')) {
    console.error(`${USAGE} (bad argument: ${args[i]})`);
    process.exit(2);
  }
  opts.shots = args[i + 1];
}
const shotDir = path.resolve(opts.shots || path.join(root, 'shots'));
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
const STATIONS = ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready'];
const NOW = Date.now();  // determinism: ok the single anchor; the fixtures' step times are offsets from it so the page's durations read a few minutes
const ago = (s) => new Date(NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ID = {
  failed: 'ob_00000000000000000f01',
  running: 'ob_00000000000000000a01',
  cancel: 'ob_00000000000000000c01',
  done: 'ob_00000000000000000d01',
  slow: 'ob_00000000000000000501',
  broken: 'ob_00000000000000000e01',
  missing: 'ob_00000000000000000401'
};

// The {run, steps} shape GET /api/onboarding/runs/:id answers.
function fixture(id, runState, states, excerpt = {}) {
  return {
    run: { id, project: 'demo', repo: 'example-org/demo', state: runState, station: null, created_by: null,
      created_at: ago(400), updated_at: ago(60), finished_at: ['done', 'failed', 'cancelled'].includes(runState) ? ago(60) : null,
      inputs: { box: 'shared', project: 'demo', repo: 'example-org/demo', tracker: 'github-issues' } },
    steps: states.map((st, i) => ({
      station: STATIONS[i], ord: i + 1, state: st,
      started_at: st === 'queued' || st === 'skipped' ? null : ago(300 - i * 30),
      finished_at: st === 'done' || st === 'failed' ? ago(280 - i * 30) : null,
      retries: 0, error_code: st === 'failed' ? 'app_no_issues_write' : null,
      log_excerpt: excerpt[i] !== undefined ? excerpt[i] : st === 'queued' ? null : `${STATIONS[i]}: ok`
    }))
  };
}
const FAILED_STATES = ['done', 'done', 'failed', 'skipped', 'skipped', 'skipped', 'skipped'];
const RUNNING_STATES = ['done', 'done', 'done', 'running', 'queued', 'queued', 'queued'];
const EVIL = 'gh: 403 Resource not accessible by integration\n<img src=x onerror="window.__xss=1"><script>window.__xss=2</script>';

let runs = {};
function resetRuns() {
  runs = {
    [ID.failed]: fixture(ID.failed, 'failed', FAILED_STATES, { 2: EVIL }),
    [ID.running]: fixture(ID.running, 'running', RUNNING_STATES),
    [ID.cancel]: fixture(ID.cancel, 'running', RUNNING_STATES),
    [ID.done]: fixture(ID.done, 'done', Array(7).fill('done')),
    [ID.slow]: fixture(ID.slow, 'running', RUNNING_STATES)
  };
}
resetRuns();

const log = [];
const SHELL = {
  '/api/dash/fleet': { snapshot_age_min: 1, watchdog: { boxes: { hub: '1m ago' } }, open_alerts: 0 },
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
      const m = /^\/api\/coord\/onboarding\/runs\/(ob_[0-9a-f]{20})(?:\/(retry|cancel))?$/.exec(p);
      if (!m) return send(res, 200, SHELL[p] || {});
      log.push({ method: req.method, path: p, body });
      const [, id, verb] = m;
      if (req.method === 'GET' && !verb) {
        if (id === ID.broken) return send(res, 500, { error: 'onboarding_runs unavailable' });
        if (!runs[id]) return send(res, 404, { error: 'not_found' });
        const answer = () => send(res, 200, runs[id]);
        return id === ID.slow ? setTimeout(answer, 1500) : answer(); // fixed-wait: ok the fixture server holds this answer on purpose so D5 can see the skeleton
      }
      if (req.method === 'POST' && verb && runs[id]) {
        const r = runs[id];
        if (verb === 'retry') {
          if (r.run.state !== 'failed') return send(res, 409, { error: 'not_failed', state: r.run.state });
          r.run.state = 'queued';
          r.steps.forEach((s) => { if (s.state !== 'done') { s.state = 'queued'; s.error_code = null; } });
          return send(res, 200, { id, state: 'queued' });
        }
        if (['done', 'cancelled'].includes(r.run.state)) return send(res, 409, { error: 'already_terminal', state: r.run.state });
        r.run.state = 'cancelled';
        r.steps.forEach((s) => { if (s.state !== 'done') s.state = 'skipped'; });
        return send(res, 200, { id, state: 'cancelled' });
      }
      return send(res, 405, { error: 'not allowed' });
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
const posts = (id, verb) => log.filter((l) => l.method === 'POST' && l.path === `/api/coord/onboarding/runs/${id}/${verb}`);
const gets = (id) => log.filter((l) => l.method === 'GET' && l.path === `/api/coord/onboarding/runs/${id}`);

// In the page: what a reader sees.
function measure() {
  const visible = (el) => {
    if (!el || el.getClientRects().length === 0) return false;
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0 && r.width > 0 && r.height > 0;
  };
  const q = (s) => document.querySelector(s);
  const pick = (el, props) => (el ? Object.fromEntries(props.map((p) => [p, getComputedStyle(el)[p]])) : null);
  const h = (el) => (el ? Math.round(el.getBoundingClientRect().height) : 0);
  const TEXT = ['fontFamily', 'fontSize', 'color', 'backgroundColor'];
  return {
    strip: { visible: visible(q('.setup-strip')), display: q('.setup-strip') ? getComputedStyle(q('.setup-strip')).display : null },
    items: [...document.querySelectorAll('ol.setup-stations > li')].map((li) => ({ visible: visible(li), text: li.textContent.replace(/\s+/g, ' ').trim() })),
    list: visible(q('ol.setup-stations')),
    fixbox: visible(q('.setup-fixbox')),
    retry: { visible: visible(q('button.setup-retry')), height: h(q('button.setup-retry')) },
    fix: { visible: visible(q('a.setup-fix')), href: q('a.setup-fix') ? q('a.setup-fix').getAttribute('href') : null },
    cancel: { visible: visible(q('button.setup-cancel')), height: h(q('button.setup-cancel')) },
    open: q('a.setup-open') ? { href: q('a.setup-open').getAttribute('href'), disabled: q('a.setup-open').getAttribute('aria-disabled') } : null,
    eyebrow: q('.line-chip') ? q('.line-chip').textContent.trim() : null,
    injected: document.querySelectorAll('.setup-fixbox img, .setup-fixbox script, .setup-log img, .setup-log script').length,
    xss: window.__xss || 0,
    excerpt: q('.setup-fixbox pre') ? q('.setup-fixbox pre').textContent : null,
    page: { scrollWidth: document.documentElement.scrollWidth, innerWidth },
    computed: {
      'li failed pill': pick(q('ol.setup-stations > li:nth-child(3) .pill'), TEXT),
      'fixbox': pick(q('.setup-fixbox'), ['backgroundColor', 'borderColor']),
      'fixbox pre': pick(q('.setup-fixbox pre'), ['fontFamily', 'fontSize', 'whiteSpace']),
      'button.setup-retry': pick(q('button.setup-retry'), ['minHeight', 'height']),
      'button.setup-cancel': pick(q('button.setup-cancel'), ['minHeight', 'height']),
      '.setup-bar': pick(q('.setup-bar'), ['position', 'bottom', 'backgroundColor']),
      '.setup-strip': pick(q('.setup-strip'), ['display'])
    }
  };
}

async function newPage(browser, themeId, scheme, width, height) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1, colorScheme: scheme });
  await page.addInitScript((id) => {
    window.localStorage.setItem('ui.theme', id);
    window.__confirmCalls = 0;
    window.confirm = () => { window.__confirmCalls += 1; return true; };
  }, themeId);
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  return { page, errors };
}
const settle = async (page, sel) => {
  await page.waitForSelector(sel, { timeout: 15000 }).catch(() => {});
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(200);
};

const THEMES = [['mill', 'dark'], ['paper', 'light']];
const VIEWPORTS = [[1440, 900], [390, 844]];
const table = [];
const shots = [];

async function run(browser) {
  await new Promise((r) => server.listen(0, r));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const at = (id) => `${origin}/projects/demo/setup/${id}`;

  // D1, D2, D7 (excerpt as text) on the failed run, per theme and width.
  for (const [themeId, scheme] of THEMES) {
    for (const [width, height] of VIEWPORTS) {
      const tag = `${themeId} ${width}px`;
      resetRuns();
      const { page, errors } = await newPage(browser, themeId, scheme, width, height);
      await page.goto(at(ID.failed), { waitUntil: 'networkidle' });
      await settle(page, 'ol.setup-stations');
      const m = await page.evaluate(measure);
      check(m.eyebrow === 'STATION 3 OF 7', `${tag}: the eyebrow reads STATION 3 OF 7 (${m.eyebrow})`);
      check(m.items.length === 7 && m.items.every((i) => i.visible), `${tag}: 7 visible stations (${m.items.length})`);
      check(m.list, `${tag}: the station list is visible`);
      check(m.fixbox && m.retry.visible, `${tag}: the fix box and RETRY are visible`);
      check(m.fix.visible && m.fix.href === 'https://github.com/settings/installations', `${tag}: the fix link is visible (${m.fix.href})`);
      check(m.injected === 0 && m.xss === 0, `${tag}: the excerpt made no img or script (${m.injected}, xss ${m.xss})`);
      check((m.excerpt || '').includes('<img src=x'), `${tag}: the excerpt shows as literal text`);
      check(m.open && m.open.disabled === 'true' && m.open.href === null, `${tag}: OPEN PROJECT is disabled on a failed run`);
      if (width >= 1000) {
        check(m.strip.visible, `${tag}: the station strip is visible`);
      } else {
        check(m.strip.display === 'none', `${tag}: the station strip is hidden (display ${m.strip.display})`);
        check(m.retry.height >= 44 && m.cancel.height >= 44, `${tag}: RETRY and CANCEL are >= 44px high (${m.retry.height}, ${m.cancel.height})`);
      }
      check(m.page.scrollWidth <= m.page.innerWidth, `${tag}: no horizontal body scroll (${m.page.scrollWidth} <= ${m.page.innerWidth})`);
      const file = path.join(shotDir, `setup-${themeId}-${width}.png`);
      await page.screenshot({ path: file });
      shots.push(file);
      await page.click('details.setup-log > summary');
      await page.waitForTimeout(150);
      const logPre = await page.evaluate(() => {
        const pre = document.querySelector('details.setup-log[open] pre');
        return Boolean(pre && pre.getBoundingClientRect().height > 0 && getComputedStyle(pre).display !== 'none');
      });
      check(logPre, `${tag}: the LOG pane opens on a click and shows its excerpts`);
      for (const [el, props] of Object.entries(m.computed)) {
        if (props) for (const [p, v] of Object.entries(props)) table.push([themeId, width, el, p, v]);
      }
      check(errors.length === 0, `${tag}: no page errors${errors.length ? ` (${errors.join(' | ')})` : ''}`);
      await page.close();
    }
  }

  // D4 Retry: one POST with body {}, then the label station reads QUEUED.
  resetRuns();
  {
    const { page } = await newPage(browser, 'mill', 'dark', 1440, 900);
    await page.goto(at(ID.failed), { waitUntil: 'networkidle' });
    await settle(page, 'button.setup-retry');
    await page.click('button.setup-retry');
    await page.waitForFunction(() => /QUEUED/.test(document.querySelector('ol.setup-stations > li:nth-child(3)')?.textContent || ''), null, { timeout: 8000 }).catch(() => {});
    const p = posts(ID.failed, 'retry');
    check(p.length === 1 && p[0].body === '{}', `D4: one POST .../retry with body {} (${p.length}, ${p[0] ? p[0].body : '-'})`);
    const label = await page.evaluate(() => document.querySelector('ol.setup-stations > li:nth-child(3)')?.textContent || '');
    check(/QUEUED/.test(label), `D4: the label station reads QUEUED after the retry (${label.replace(/\s+/g, ' ').trim()})`);
    await page.close();
  }

  // D3 Cancel: an in-app modal, Escape sends nothing, CANCEL RUN sends one POST.
  {
    const { page } = await newPage(browser, 'mill', 'dark', 1440, 900);
    await page.goto(at(ID.cancel), { waitUntil: 'networkidle' });
    await settle(page, 'button.setup-cancel');
    await page.click('button.setup-cancel');
    const modalOpen = await page.waitForSelector('.modal', { state: 'visible', timeout: 3000 }).then(() => true, () => false);
    check(modalOpen, 'D3: CANCEL RUN opens a visible in-app modal');
    await page.keyboard.press('Escape');
    const closed = await page.waitForSelector('.modal', { state: 'detached', timeout: 3000 }).then(() => true, () => false);
    check(closed && posts(ID.cancel, 'cancel').length === 0, `D3: Escape closes the modal and sends no POST (${posts(ID.cancel, 'cancel').length})`);
    await page.click('button.setup-cancel');
    await page.waitForSelector('.modal', { state: 'visible', timeout: 3000 }).catch(() => {});
    await page.click('.modal .btn--danger');
    await page.waitForTimeout(500);
    check(posts(ID.cancel, 'cancel').length === 1, `D3: CANCEL RUN sends exactly one POST (${posts(ID.cancel, 'cancel').length})`);
    const confirms = await page.evaluate(() => window.__confirmCalls);
    check(confirms === 0, `D3: window.confirm was never called (${confirms})`);
    await page.close();
  }

  // D5 the skeleton before a slow first answer.
  {
    const { page } = await newPage(browser, 'mill', 'dark', 1440, 900);
    await page.goto(at(ID.slow), { waitUntil: 'domcontentloaded' });
    const skel = await page.waitForSelector('.setup-skeleton', { state: 'visible', timeout: 1200 }).then(() => true, () => false);
    check(skel, 'D5: .setup-skeleton is visible before the delayed answer');
    await settle(page, 'ol.setup-stations');
    check(await page.$('ol.setup-stations') !== null, 'D5: the stations replace the skeleton');
    await page.close();
  }

  // D6 the poll: none after a done run, a second GET for a running run.
  {
    const { page } = await newPage(browser, 'mill', 'dark', 1440, 900);
    await page.goto(at(ID.done), { waitUntil: 'networkidle' });
    await settle(page, 'a.setup-open');
    const href = await page.getAttribute('a.setup-open', 'href');
    check(href === '/p/demo', `D6: OPEN PROJECT links to /p/demo on a done run (${href})`);
    await page.waitForTimeout(6000);
    check(gets(ID.done).length === 1, `D6: no poll after a done run (${gets(ID.done).length} GET)`);
    await page.goto(at(ID.running), { waitUntil: 'networkidle' });
    await page.waitForTimeout(6000);
    check(gets(ID.running).length >= 2, `D6: a running run is read again within 6 s (${gets(ID.running).length} GET)`);
    await page.close();
  }

  // D7 a broken first load and an unknown run.
  {
    const { page } = await newPage(browser, 'paper', 'light', 390, 844);
    await page.goto(at(ID.broken), { waitUntil: 'networkidle' });
    const banner = await page.waitForSelector('.banner', { state: 'visible', timeout: 5000 }).then(() => true, () => false);
    check(banner, 'D7: a 500 first load shows the ErrorBox');
    await page.goto(at(ID.missing), { waitUntil: 'networkidle' });
    const empty = await page.waitForSelector('text=No setup run', { state: 'visible', timeout: 5000 }).then(() => true, () => false);
    check(empty, 'D7: an unknown run shows "No setup run"');
    await page.close();
  }
}

let browser = null;
try {
  fs.mkdirSync(shotDir, { recursive: true });
  browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  await run(browser);
  const md = ['| theme | width | element | property | value |', '|---|---|---|---|---|',
    ...table.map((r) => `| ${r.join(' | ')} |`)].join('\n');
  fs.writeFileSync(path.join(shotDir, 'computed.md'), `${md}\n`);
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
