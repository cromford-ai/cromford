// Headless drive of the AI accounts on Settings (BH-7966, BH-7937.2).
//
// Not a unit test. It serves the BUILT dist/ over http with the reads the
// Settings hub tab makes stubbed, plus an in-memory fake of the four AI
// account calls and the envelope POST. It opens /settings (the legacy path the
// side menu redirects to /settings/fleet/lanes) in chromium at 1440x900 and
// 390x844, in the mill (dark) and paper (light) themes, and checks what a user
// sees:
//   - ACCOUNTS ON THE FLEET is visible with its 8 headers; a click on each
//     header sets aria-sort on it (ascending, then descending on a 2nd click);
//   - the body never scrolls sideways; the fleet table scrolls inside
//     .aiacct__wrap (overflow-x:auto);
//   - + ADD ACCOUNT opens the sheet: it is visible, and at 390px its bottom
//     edge is the viewport bottom (a bottom sheet); at 1440 it is on the right;
//   - an sk-abc label is refused with the label rule's text and 0 POSTs;
//   - a real save (openrouter / team-a / a fixture token) sends an envelope
//     whose ciphertext does not hold the token, then the account POST; the
//     table lists openrouter / team-a pending; the sheet says STILL WAITING
//     after the stubbed ai_account_status_wait_s (5 s);
//   - Escape closes the sheet and focus returns to + ADD ACCOUNT;
//   - CHOOSE… on a PROJECT ACCOUNTS row opens the choice sheet; USE THE FLEET
//     POOL opens the confirm modal; PIN writes account.<project> = shared.
// It writes ai-accounts-<theme>-<width>.png and computed.md to --shots.
//
//   npm run build && node tests/drive/ai-accounts.bh-7966-drive.mjs [--shots <dir>]
//
// Exit 0 = every check passed, or `SKIP: no chromium` (playwright or its
// browser is not installed on this box), 1 = a check failed, 2 = a bad
// argument or no dist/.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { webcrypto } from 'node:crypto';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');
const USAGE = 'usage: node tests/drive/ai-accounts.bh-7966-drive.mjs [--shots <dir>]';
const args = process.argv.slice(2);
const opts = {};
for (let i = 0; i < args.length; i += 2) {
  if (args[i] !== '--shots' || args[i + 1] === undefined) { console.error(USAGE); process.exit(2); }
  opts.shots = args[i + 1];
}
const shotDir = path.resolve(opts.shots || path.join(root, 'shots'));
if (!fs.existsSync(path.join(dist, 'index.html'))) { console.error('dist/ is not built — run `npm run build` first'); process.exit(2); }

const require = createRequire(import.meta.url);
let chromium = null;
try {
  ({ chromium } = require('playwright'));
} catch {
  try {
    process.env.NODE_PATH = [process.env.NODE_PATH, execSync('npm root -g').toString().trim()].filter(Boolean).join(path.delimiter);
    require('node:module').Module._initPaths();
    ({ chromium } = require('playwright'));
  } catch { chromium = null; }
}
let browser = null;
if (chromium) browser = await chromium.launch().catch(() => null);
if (!browser) { console.log('SKIP: no chromium (playwright or its browser is not installed here)'); process.exit(0); }

const TOKEN = 'tok-fixture-openrouter-bh7966-drive';
const kp = await webcrypto.subtle.generateKey(
  { name: 'RSA-OAEP', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['encrypt', 'decrypt']);
const spki = Buffer.from(await webcrypto.subtle.exportKey('spki', kp.publicKey)).toString('base64');
const PEM = `-----BEGIN PUBLIC KEY-----\n${spki.match(/.{1,64}/g).join('\n')}\n-----END PUBLIC KEY-----\n`;

// Per page: the fake's own state, so each theme and width starts the same.
let state;
const reset = () => {
  state = {
    posts: [],
    pins: { 'account.beta-os': 'zeta' },
    accounts: [
      { id: 'acc-fixture-zeta', vendor: 'claude', label: 'zeta', plan: 'max', use_kind: 'project', projects: ['beta-os'], today: 2.5, boxes: 3, state: 'active', revoked_at: null },
      { id: 'acc-fixture-alpha', vendor: 'xai', label: 'alpha', plan: null, use_kind: 'fallback', projects: [], today: 0, boxes: null, state: 'pending', revoked_at: null }
    ]
  };
};
const settingsBody = () => ({
  settings: [
    { key: 'hub_envelope_public_key', value: PEM },
    { key: 'ai_account_status_poll_s', value: '1' },
    { key: 'ai_account_status_wait_s', value: '5' },
    ...Object.entries(state.pins).map(([key, value]) => ({ key, value, actor: 'console', updated_at: '2026-10-23T10:00:00Z' }))
  ]
});
const STUBS = {
  '/api/coord/lanes/registry': { registry: { lanes: [] } },
  '/api/coord/lanes/status': { projects: ['beta-os', 'demo'], lanes: [] },
  '/api/dash/fleet': { snapshot_age_min: 1, watchdog: { boxes: { hub: '1m ago' } }, open_alerts: 0 },
  '/api/coord/whoami': { access: 'on', email: 'operator@example.com' }
};
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const send = (status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  if (url.pathname.startsWith('/api/')) {
    let raw = '';
    for await (const c of req) raw += c;
    const body = raw ? JSON.parse(raw) : null;
    if (req.method !== 'GET') state.posts.push({ method: req.method, path: url.pathname, raw });
    if (req.method === 'GET' && url.pathname === '/api/coord/settings') return send(200, settingsBody());
    if (req.method === 'PUT' && url.pathname === '/api/coord/settings') { state.pins[body.key] = body.value; return send(200, { setting: body }); }
    if (req.method === 'GET' && url.pathname === '/api/coord/ai-accounts') return send(200, { accounts: state.accounts, limit: 500, truncated: false });
    if (req.method === 'POST' && url.pathname === '/api/coord/secrets/envelope') return send(200, { id: webcrypto.randomUUID(), expires_at: '2099-01-01T00:00:00Z' });
    if (req.method === 'POST' && url.pathname === '/api/coord/ai-accounts') {
      const id = webcrypto.randomUUID();
      state.accounts.push({ id, vendor: body.vendor, label: body.label, plan: body.plan, use_kind: body.use_kind, projects: [], today: 0, boxes: null, state: 'pending', revoked_at: null });
      return send(200, { id, state: 'pending' });
    }
    if (req.method === 'GET' && /^\/api\/coord\/secrets\/envelope\/[0-9a-f-]{36}\/status$/.test(url.pathname)) return send(200, { state: 'pending' });
    return send(200, STUBS[url.pathname] || {});
  }
  let file = path.join(dist, url.pathname === '/' ? 'index.html' : url.pathname.slice(1));
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(dist, 'index.html');
  const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png' };
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  res.end(fs.readFileSync(file));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;

const fail = [];
const check = (ok, what) => { console.log(`${ok ? 'pass' : 'FAIL'} ${what}`); if (!ok) fail.push(what); };
const computed = [];
fs.mkdirSync(shotDir, { recursive: true });

const fleet = (page) => page.locator('.section', { has: page.locator('.section__title', { hasText: 'ACCOUNTS ON THE FLEET' }) });
const HEADS = ['VENDOR', 'LABEL', 'PLAN', 'PROJECTS', 'TODAY', 'BOXES', 'STATE', 'ACTION'];

for (const [themeId, scheme] of [['mill', 'dark'], ['paper', 'light']]) {
  for (const [width, height] of [[1440, 900], [390, 844]]) {
    reset();
    const tag = `${themeId} ${width}px`;
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1, colorScheme: scheme });
    await page.addInitScript((id) => { window.localStorage.setItem('ui.theme', id); }, themeId);
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(`${origin}/settings`, { waitUntil: 'networkidle' });
    const sec = fleet(page);
    await sec.waitFor({ state: 'visible', timeout: 15000 }).catch(() => {});
    check(await sec.isVisible(), `${tag}: ACCOUNTS ON THE FLEET is visible from /settings (${page.url().replace(origin, '')})`);
    await sec.locator('tbody tr').first().waitFor({ timeout: 10000 }).catch(() => {});
    check((await sec.locator('tbody tr').count()) === 2, `${tag}: the table lists the 2 stubbed accounts`);
    for (const h of HEADS) {
      const th = sec.locator('thead th', { hasText: h });
      await th.locator('button').click();
      const a1 = await th.getAttribute('aria-sort');
      await th.locator('button').click();
      const a2 = await th.getAttribute('aria-sort');
      // VENDOR is the default sort (ascending), so its first click flips it.
      const want = h === 'VENDOR' ? ['descending', 'ascending'] : ['ascending', 'descending'];
      check(a1 === want[0] && a2 === want[1], `${tag}: ${h} sorts ${want.join(' then ')} (${a1}, ${a2})`);
    }
    const m = await page.evaluate(() => {
      const wrap = document.querySelector('.aiacct__wrap');
      return { scrollWidth: document.documentElement.scrollWidth, innerWidth: window.innerWidth, wrapOverflow: wrap ? getComputedStyle(wrap).overflowX : null };
    });
    check(m.scrollWidth <= m.innerWidth, `${tag}: no body scroll sideways (scrollWidth ${m.scrollWidth} <= ${m.innerWidth})`);
    check(m.wrapOverflow === 'auto', `${tag}: .aiacct__wrap is overflow-x:auto (${m.wrapOverflow})`);
    await page.screenshot({ path: path.join(shotDir, `ai-accounts-${themeId}-${width}.png`), fullPage: false });

    // The add sheet.
    const addBtn = sec.getByRole('button', { name: '+ ADD ACCOUNT' });
    await addBtn.click();
    const sheet = page.getByRole('dialog', { name: 'ADD AI ACCOUNT' });
    await sheet.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
    check(await sheet.isVisible(), `${tag}: + ADD ACCOUNT opens a visible sheet`);
    const box = await sheet.boundingBox();
    if (width <= 640) check(box && Math.abs(box.y + box.height - height) <= 1 && box.width >= width - 1, `${tag}: the sheet is a bottom sheet (bottom ${box && Math.round(box.y + box.height)} of ${height}, width ${box && Math.round(box.width)})`);
    else check(box && Math.abs(box.x + box.width - width) <= 1 && box.width < width / 2, `${tag}: the sheet is a side sheet on the right (x ${box && Math.round(box.x)}, width ${box && Math.round(box.width)})`);
    const cs = await sheet.evaluate((el) => { const c = getComputedStyle(el); return { background: c.backgroundColor, width: c.width, padding: c.padding, borderRadius: c.borderRadius }; });
    computed.push([themeId, width, '.aisheet', JSON.stringify(cs)]);
    await page.screenshot({ path: path.join(shotDir, `ai-accounts-sheet-${themeId}-${width}.png`) });
    check(await sheet.locator('select').first().evaluate((el) => el === document.activeElement), `${tag}: focus moves to the first field`);

    // sk-abc is refused before anything is sent.
    const before = state.posts.length;
    await sheet.locator('select').first().selectOption('openrouter');
    await sheet.getByLabel('LABEL').fill('sk-abc');
    await sheet.getByLabel('TOKEN').fill(TOKEN);
    await sheet.getByRole('button', { name: 'TEST AND SAVE' }).click();
    const alert = sheet.getByRole('alert');
    await alert.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
    check(await alert.isVisible() && /looks like a token/.test(await alert.textContent()), `${tag}: an sk-abc label shows the refusal`);
    check(state.posts.length === before, `${tag}: the refusal sent 0 POSTs`);
    check((await sheet.getByLabel('TOKEN').inputValue()) === '', `${tag}: the token field is cleared after the attempt`);

    // A real save.
    await sheet.getByLabel('LABEL').fill('team-a');
    await sheet.getByLabel('TOKEN').fill(TOKEN);
    await sheet.getByRole('button', { name: 'TEST AND SAVE' }).click();
    const waiting = sheet.getByText('STILL WAITING');
    await waiting.waitFor({ state: 'visible', timeout: 12000 }).catch(() => {});
    check(await waiting.isVisible(), `${tag}: after ai_account_status_wait_s the sheet says STILL WAITING`);
    const posted = state.posts.slice(before).map((p) => p.path);
    check(JSON.stringify(posted) === JSON.stringify(['/api/coord/secrets/envelope', '/api/coord/ai-accounts']), `${tag}: the save POSTs the envelope, then the account (${posted.join(', ')})`);
    check(state.posts.every((p) => !p.raw.includes(TOKEN)), `${tag}: no request body holds the token`);
    // Escape closes and focus returns to the opener.
    await page.keyboard.press('Escape');
    await sheet.waitFor({ state: 'detached', timeout: 3000 }).catch(() => {});
    check(!(await sheet.isVisible()), `${tag}: Escape closes the sheet`);
    check(await addBtn.evaluate((el) => el === document.activeElement), `${tag}: focus returns to + ADD ACCOUNT`);
    const newRow = sec.locator('tbody tr', { hasText: 'team-a' });
    await newRow.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
    check(await newRow.isVisible() && /openrouter/.test(await newRow.textContent()) && /pending/.test(await newRow.textContent()), `${tag}: the table lists openrouter / team-a pending`);

    // The per-project choice.
    const pa = page.locator('.section', { has: page.locator('.section__title', { hasText: 'PROJECT ACCOUNTS' }) });
    await pa.getByRole('button', { name: 'choose the AI account for demo' }).click();
    const choice = page.getByRole('dialog', { name: 'AI account for demo' });
    await choice.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
    check(await choice.isVisible(), `${tag}: CHOOSE… opens the choice sheet for demo`);
    await choice.locator('option', { hasText: 'zeta' }).waitFor({ state: 'attached', timeout: 5000 }).catch(() => {});
    check((await choice.locator('option', { hasText: 'zeta' }).count()) === 1 && (await choice.locator('option', { hasText: 'alpha' }).count()) === 0, `${tag}: only the active account is offered`);
    await choice.getByRole('button', { name: 'USE THE FLEET POOL' }).click();
    const modal = page.locator('.modal');
    await modal.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
    check(await modal.isVisible(), `${tag}: the confirm modal shows before any write`);
    check(state.pins['account.demo'] === undefined, `${tag}: nothing is written before the confirm`);
    await modal.getByRole('button', { name: 'UNPIN' }).click();
    await page.waitForTimeout(300);
    check(state.pins['account.demo'] === 'shared', `${tag}: account.demo = shared after the confirm (${state.pins['account.demo']})`);
    check(!(await choice.isVisible()), `${tag}: the choice sheet closes after the write`);
    check(errors.length === 0, `${tag}: no page error (${errors.join(' | ')})`);
    await page.close();
  }
}
fs.writeFileSync(path.join(shotDir, 'computed.md'), ['| theme | width | element | computed |', '|---|---|---|---|', ...computed.map((r) => `| ${r.join(' | ')} |`)].join('\n') + '\n');
await browser.close();
server.close();
console.log(fail.length ? `FAILED ${fail.length} check(s)` : 'all checks passed');
process.exit(fail.length ? 1 : 0);
