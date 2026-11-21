// Headless drive of the BUILT bundle for the project Signals page (BH-9839).
//
// Not a unit test. It serves dist/ over http with an in-memory fake of the
// four signal-keys calls (list, set, clear, test) and the project list; every
// other /api/ read answers {}. It opens the console in chromium at 1440x900
// and 390x844, in the light (paper) and dark (mill) themes:
//   - both cards are visible (a non-zero box, visibility visible);
//   - at 390 the page does not scroll sideways (scrollWidth <= innerWidth);
//   - Set PostHog: labels, a wrong prefix shows the error on blur, Save, the
//     test result shows in the sheet, Done; Replace opens with the secret
//     empty; Clear through the confirm dialog; the card says "Not set";
//   - the page is reached from the settings menu row and from a Fleet pill.
// Screenshots and a computed-value table (computed.tsv) go to --shots.
//
//   npm run build && node tests/drive/signals.bh-9839-drive.mjs [--shots <dir>]
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

const P = 'project-6-fixture';
// Built from parts, so no scanner reads a literal key in this file.
const PH_KEY = `${['ph', 'x_'].join('')}fixtureDrive0123456789`;
const BAD_KEY = `${['ph', 'c_'].join('')}fixtureDrive0123456789`;
const KINDS = [
  {
    kind: 'sentry', label: 'Sentry', scope_note: 'Sentry: read scopes plus event:write, no admin.',
    fields: [
      { name: 'org', label: 'Organization slug', placeholder: 'my-org', re: '^[a-z0-9][a-z0-9_-]{0,63}$', secret: 0 },
      { name: 'project', label: 'Project slug', placeholder: 'my-project', re: '^[a-z0-9][a-z0-9_-]{0,63}$', secret: 0 },
      { name: 'token', label: 'API token', placeholder: 'sntryu_…', re: '^[A-Za-z0-9_=+/.-]+$', secret: 1, prefixes: [['sntry', 'u_'].join(''), ['sntry', 's_'].join('')] }
    ]
  },
  {
    kind: 'posthog', label: 'PostHog', scope_note: 'PostHog: read scopes plus annotation write, scoped to the one project.',
    fields: [
      { name: 'host', label: 'Host', placeholder: 'https://us.posthog.com', re: '^https://[^\\s]{1,200}$', secret: 0 },
      { name: 'project_id', label: 'Project id', placeholder: '12345', re: '^[0-9]{1,12}$', secret: 0 },
      { name: 'key', label: 'Personal API key', placeholder: 'phx_…', re: '^[A-Za-z0-9_=+/.-]+$', secret: 1, prefixes: [['ph', 'x_'].join('')] }
    ]
  }
];
let rows = [];
const reset = () => {
  rows = [{
    project: P, kind: 'sentry', fields: { org: 'acme-fixture', project: 'web-fixture-with-a-long-slug-to-wrap' }, secret_set: true,
    updated_at: '2026-08-01T09:00:00Z', updated_by: 'operator-fixture@example.com', last_used_at: null,
    last_test_at: '2026-08-01T09:01:00Z', last_test_status: 200, last_test_result: 'ok',
    rotate_by: '2024-10-30T09:00:00Z', rotate_overdue: true
  }];
};

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };
const readBody = (req) => new Promise((r) => { let s = ''; req.on('data', (c) => { s += c; }); req.on('end', () => r(s ? JSON.parse(s) : {})); });
function api(pathname, method, body, url) {
  if (pathname === '/api/dash/projects') return [200, { projects: [{ project: P, last_run_age_min: 1, last_summary: 'ok', last_rc: 0 }], projects_source: 'fleet_status', snapshot_age_min: 1 }];
  if (pathname === '/api/coord/signal-keys' && method === 'GET') {
    const q = url.searchParams.get('project');
    return [200, { kinds: KINDS, rows: q ? rows.filter((r) => r.project === q) : rows, more: false, rotate_days: 90, as_of: '2026-11-20T10:00:00Z' }];
  }
  if (pathname === '/api/coord/signal-keys/set') {
    const clear = Object.fromEntries(Object.entries(body.fields || {}).filter(([k]) => k !== 'key' && k !== 'token'));
    rows = rows.filter((r) => !(r.project === body.project && r.kind === body.kind));
    rows.push({ project: body.project, kind: body.kind, fields: clear, secret_set: true, updated_at: '2026-11-20T10:00:00Z', updated_by: 'operator-fixture@example.com', last_used_at: null, last_test_at: null, last_test_status: null, last_test_result: null, rotate_by: '2099-02-18T10:00:00Z', rotate_overdue: false });
    return [200, { stored: true, project: body.project, kind: body.kind, fields: clear }];
  }
  if (pathname === '/api/coord/signal-keys/test') return [200, { ok: true, result: 'ok', status: 200, reason: 'the vendor accepted the key', tested_at: '2026-11-20T10:00:05Z' }];
  if (pathname === '/api/coord/signal-keys/clear') {
    rows = rows.filter((r) => !(r.project === body.project && r.kind === body.kind));
    return [200, { cleared: true }];
  }
  return [200, {}];
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    const body = req.method === 'POST' ? await readBody(req) : {};
    const [status, payload] = api(decodeURIComponent(url.pathname), req.method, body, url);
    res.writeHead(status, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(payload));
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
const visible = (page, sel) => page.evaluate((s) => {
  const el = document.querySelector(s);
  if (!el) return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility === 'visible';
}, sel);

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
  const table = ['view\ttheme\tselector\tproperty\tvalue'];

  for (const [name, width, height] of [['desktop', 1440, 900], ['phone', 390, 844]]) {
    for (const theme of ['paper', 'mill']) {
      reset();
      const tag = `${name}-${theme}`;
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
      await page.addInitScript((t) => { try { localStorage.setItem('ui.theme', t); } catch { /* private mode */ } }, theme);

      // Entry point 1: the settings menu row.
      await page.goto(`${base}/settings/p/${P}`, { waitUntil: 'networkidle' });
      await page.click(`nav.settings-menu a[href="/settings/p/${P}/signals"]`);
      await page.waitForSelector('.signals__card[data-kind="posthog"]', { timeout: 15000 });
      check(await visible(page, '.signals__card[data-kind="sentry"]'), `${tag}: the Sentry card is visible`);
      check(await visible(page, '.signals__card[data-kind="posthog"]'), `${tag}: the PostHog card is visible`);
      check(await visible(page, '.signals__card[data-kind="sentry"] .signals__rotate'), `${tag}: the rotate pill is visible`);
      const sw = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
      check(sw[0] <= sw[1], `${tag}: scrollWidth ${sw[0]} <= innerWidth ${sw[1]}`);
      for (const [sel, prop] of [['.signals__card', 'padding'], ['.signals__card', 'border-radius'], ['.signals__card', 'background-color'],
        ['.signals__title', 'font-size'], ['.signals__actions .btn', 'min-height'], ['.signals__cards', 'grid-template-columns']]) {
        const v = await page.evaluate(([s, p]) => { const el = document.querySelector(s); return el ? getComputedStyle(el).getPropertyValue(p) : 'absent'; }, [sel, prop]);
        table.push(`${name}\t${theme}\t${sel}\t${prop}\t${v}`);
      }
      await page.screenshot({ path: path.join(shotDir, `signals-${tag}.png`), fullPage: true });

      // Set PostHog: a wrong prefix shows the error on blur, then a good save.
      await page.click('.signals__card[data-kind="posthog"] button:has-text("Set")');
      await page.waitForSelector('.ksheet[role="dialog"]');
      check(await visible(page, 'label[for="ksheet-posthog-key"]'), `${tag}: the key label is visible`);
      await page.fill('#ksheet-posthog-host', 'https://us.posthog.com');
      await page.fill('#ksheet-posthog-project_id', '4242');
      await page.fill('#ksheet-posthog-key', BAD_KEY);
      await page.locator('#ksheet-posthog-host').focus();
      check(await visible(page, '#ksheet-posthog-key-err'), `${tag}: the prefix error shows under the field`);
      check((await page.inputValue('#ksheet-posthog-key')) === BAD_KEY, `${tag}: the typed value stays`);
      const sw2 = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
      check(sw2[0] <= sw2[1], `${tag}: sheet scrollWidth ${sw2[0]} <= ${sw2[1]}`);
      await page.screenshot({ path: path.join(shotDir, `signals-sheet-error-${tag}.png`) });
      await page.fill('#ksheet-posthog-key', `  ${PH_KEY}\n`);
      await page.click('.ksheet button:has-text("Save")');
      await page.waitForSelector('.ksheet .ksheet__note:has-text("Saved. Test: ok")', { timeout: 15000 });
      check(true, `${tag}: Saved. Test: ok shows in the sheet`);
      check((await page.inputValue('#ksheet-posthog-key')) === '', `${tag}: the secret field is empty after the save`);
      await page.screenshot({ path: path.join(shotDir, `signals-sheet-saved-${tag}.png`) });
      await page.click('.ksheet button:has-text("Done")');
      await page.waitForSelector('.signals__card[data-kind="posthog"] button:has-text("Replace")');
      check(!(await page.content()).includes(PH_KEY), `${tag}: no node holds the typed key after close`);

      // Replace: the secret is empty.
      await page.click('.signals__card[data-kind="posthog"] button:has-text("Replace")');
      await page.waitForSelector('.ksheet[role="dialog"]');
      check((await page.inputValue('#ksheet-posthog-key')) === '', `${tag}: Replace opens with the secret empty`);
      check((await page.inputValue('#ksheet-posthog-project_id')) === '4242', `${tag}: Replace fills the non-secret fields`);
      await page.keyboard.press('Escape');
      await page.waitForSelector('.ksheet', { state: 'detached' });

      // Clear through the confirm dialog.
      await page.click('.signals__card[data-kind="posthog"] .signals__danger button');
      await page.waitForSelector('.modal[role="dialog"]');
      const title = await page.getAttribute('.modal[role="dialog"]', 'aria-label');
      check(title === `Clear the PostHog key of ${P}`, `${tag}: the confirm names the project and kind (${title})`);
      await page.screenshot({ path: path.join(shotDir, `signals-clear-${tag}.png`) });
      await page.click('.modal button:has-text("CLEAR")');
      await page.waitForSelector('.signals__card[data-kind="posthog"] button:has-text("Set")', { timeout: 15000 });
      check(true, `${tag}: after Clear the PostHog card is Not set`);

      // Entry point 2: the Fleet pill.
      await page.goto(`${base}/`, { waitUntil: 'networkidle' });
      const pill = `a.tag[href="/settings/p/${P}/signals"]`;
      await page.waitForSelector(pill, { timeout: 15000 });
      await page.click(pill);
      await page.waitForSelector('.signals__card[data-kind="sentry"]', { timeout: 15000 });
      check((await page.evaluate(() => location.pathname)) === `/settings/p/${P}/signals`, `${tag}: a Fleet pill lands on the Signals page`);
      await page.close();
    }
  }

  fs.writeFileSync(path.join(shotDir, 'computed.tsv'), `${table.join('\n')}\n`);
  await browser.close();
  server.close();
  if (fail.length) {
    console.log(`\n${fail.length} check(s) failed`);
    process.exit(1);
  }
  console.log('\nall checks passed');
}

run().catch((e) => { console.error(e); server.close(); process.exit(1); });
