// Headless drive of the BUILT bundle's /staff screens at 1280px and 390px
// (BH-5567).
//
// Serves dist/ with the staff reads and the flags API STUBBED IN MEMORY: a PUT
// on /api/coord/flags really turns the row on and a DELETE really clears it,
// so the next GET answers what the write left. It drives what a person does:
// open the roster, click an agent, click a finding, follow its ticket link,
// kill an agent in the in-app modal and resume it. It asserts what no unit
// test can see: 8 roster rows, every data header sorting both ways, no native
// dialog, no sideways body scroll on a phone, and the exact flag bodies.
//
// The stub proves the SCREEN, not the data: prod staff_findings is empty until
// the staff heartbeat (BH-5561) claims a finding.
//
//   npm run build && npm run drive:staff [-- --shots <dir>]
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

// The shape GET /api/staff/roster answers (worker/jobs/src/routes/staff-screen.js),
// with the BH-5559 seed's seven agents.
const STAFF = [
  ['archivist', 'memory', 0], ['clerk', 'records', 1], ['dispatcher', 'health', 0], ['inspector', 'quality', 3],
  ['millwright', 'maintenance', 0], ['quartermaster', 'cost', 0], ['watchman', 'security', 2]
];
const ROSTER = {
  agents: [
    { name: 'archie', kind: 'overlooker', role: 'overlooker', accountable: 'operator@example.com', autonomy: 'per-class', cap: null, status: null, open_findings: 0, precision: null, spend_usd: null },
    ...STAFF.map(([name, role, n]) => ({ name, kind: 'staff', role, accountable: 'operator@example.com', autonomy: 'automation', cap: 'augmentation', status: 'active', open_findings: n, precision: null, spend_usd: null }))
  ],
  sources: { precision: 'not built: BH-5563 (#5563)', spend: 'not built: BH-5561 (#5561)' },
  as_of: '2026-10-10T00:00:00Z'
};
const TICKET = 'https://github.com/example-org/cromford/issues/5567';
const FINDINGS = [
  { id: 4, fingerprint: 'a'.repeat(64), agent: 'watchman', title: 'Secret in a public repo', source_kind: 'alert', source_url: 'https://example.com/alerts/fixture-4', source_labels: '["ops","fixture"]', source_filed_by: null, status: 'filed', ticket_url: TICKET, observed_at: '2026-10-09T02:00:00Z', claimed_at: '2026-10-09T02:01:00Z', updated_at: '2026-10-09T02:30:00Z' },
  { id: 7, fingerprint: 'b'.repeat(64), agent: 'watchman', title: 'Token in a log line', source_kind: 'issue', source_url: 'https://example.com/alerts/fixture-7', source_labels: '["fixture"]', source_filed_by: null, status: 'claimed', ticket_url: null, observed_at: '2026-10-09T03:00:00Z', claimed_at: '2026-10-09T03:01:00Z', updated_at: '2026-10-09T03:01:00Z' }
];
const COLS = ['id', 'fingerprint', 'agent', 'title', 'source_kind', 'source_url', 'status', 'ticket_url', 'observed_at', 'claimed_at', 'updated_at'];
const pick = (f) => Object.fromEntries(COLS.map((k) => [k, f[k]]));

// pause_flags in memory, keyed by name (fleet scope).
const flags = new Map();
const writes = [];
const flagRow = (name, on, reason) => ({
  scope: 'fleet', name, value: null, set_by: 'console', reason, set_at: '2026-10-10T00:00:00Z',
  cleared_at: on ? null : '2026-10-10T00:05:00Z', active: on ? 1 : 0
});

function api(method, p, q, body) {
  if (p === '/api/coord/staff/roster') return [200, ROSTER];
  if (p === '/api/coord/staff/findings') {
    const agent = (q.get('agent') || '').trim().toLowerCase();
    if (!ROSTER.agents.some((a) => a.name === agent)) return [404, { error: 'agent not found' }];
    const list = FINDINGS.filter((f) => f.agent === agent).sort((a, b) => b.id - a.id).map(pick);
    return [200, { agent, findings: list, truncated: false, as_of: '2026-10-10T00:00:00Z' }];
  }
  if (p === '/api/coord/staff/finding') {
    const f = FINDINGS.find((x) => String(x.id) === q.get('id'));
    if (!f) return [404, { error: 'finding not found' }];
    return [200, { finding: { ...f, source_labels: JSON.parse(f.source_labels) } }];
  }
  if (p === '/api/coord/flags') {
    if (method === 'PUT') {
      writes.push({ method, body });
      flags.set(body.name, flagRow(body.name, true, body.reason));
      return [200, { ok: true }];
    }
    if (method === 'DELETE') {
      writes.push({ method, q: Object.fromEntries(q) });
      const name = q.get('name');
      if (flags.has(name)) flags.set(name, flagRow(name, false, q.get('reason')));
      return [200, { ok: true }];
    }
    const prefix = q.get('prefix') || '';
    return [200, { flags: [...flags.values()].filter((r) => r.name.startsWith(prefix)), as_of: '2026-10-10T00:00:00Z' }];
  }
  if (p === '/api/dash/fleet') return [200, { projects: ['cromford'], snapshot_age_min: 1, watchdog: { ok: true } }];
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

async function noSideScroll(page, what) {
  const o = await page.evaluate(() => ({
    sw: document.body.scrollWidth, iw: window.innerWidth,
    loose: [...document.querySelectorAll('table.tbl')].filter((t) => !t.closest('.tablewrap')).length
  }));
  check(o.sw <= o.iw, `E7 ${what}: document.body.scrollWidth ${o.sw} <= innerWidth ${o.iw}`);
  check(o.loose === 0, `${what}: every table sits inside a .tablewrap that scrolls on its own`);
}

const firstCells = (page) => page.$$eval('table.tbl tbody tr', (trs) => trs.map((tr) => tr.children[0].innerText.trim()));
const columnText = (page, i) => page.$$eval('table.tbl tbody tr', (trs, idx) => trs.map((tr) => tr.children[idx].innerText.trim()), i);
const killCell = (page, name) => page.$eval(`table.tbl tbody tr:has(a[href="/staff/${name}"])`, (tr) => tr.children[9].innerText.trim());

// The cell text of an absent value. lib/sort.js sinks an absent value to the
// bottom in both directions, so only the present values can flip.
const ABSENT = new Set(['n/a', 'none yet', '']);

// E6: every header with a sort button, twice: ascending, then descending, and
// the column's own order flips when its present values differ.
async function sortsEveryHeader(page, what) {
  const labels = await page.$$eval('table.tbl thead th', (ths) => ths.map((th) => ({
    label: (th.querySelector('button') ? th.querySelector('button').innerText : th.innerText).replace(/[↑↓]/g, '').replace(/\s+/g, '').trim(),
    button: !!th.querySelector('button')
  })));
  const unsortable = labels.filter((l) => !l.button).map((l) => l.label);
  check(unsortable.every((l) => l === 'ACTION'), `E6 ${what}: only ACTION has no sort button (${JSON.stringify(unsortable)})`);
  for (let i = 0; i < labels.length; i++) {
    if (!labels[i].button) continue;
    const th = `table.tbl thead th:nth-child(${i + 1})`;
    // A column that is already the active sort starts from another column, so
    // its first click is ascending.
    if (await page.$eval(th, (e) => e.getAttribute('aria-sort')) !== 'none') {
      const other = labels.findIndex((l, j) => l.button && j !== i);
      await page.click(`table.tbl thead th:nth-child(${other + 1}) button`);
    }
    await page.click(`${th} button`);
    const a1 = await page.$eval(th, (e) => e.getAttribute('aria-sort'));
    const v1 = await columnText(page, i);
    await page.click(`${th} button`);
    const a2 = await page.$eval(th, (e) => e.getAttribute('aria-sort'));
    const v2 = await columnText(page, i);
    const present = (v) => v.filter((x) => !ABSENT.has(x));
    const differ = new Set(present(v1)).size > 1;
    check(a1 === 'ascending' && a2 === 'descending' && (!differ || present(v1).join('|') !== present(v2).join('|')),
      `E6 ${what}: ${labels[i].label} sorts ascending then descending${differ ? ' and the order flips' : ' (all values equal)'}`);
  }
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

  for (const [name, width, height] of [['desktop', 1280, 900], ['mobile', 390, 844]]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    const errors = [];
    let dialogs = 0;
    page.on('dialog', async (d) => { dialogs += 1; await d.dismiss(); });
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));

    // E1 the roster
    await page.goto(`${base}/staff`, { waitUntil: 'networkidle' });
    await page.waitForSelector('table.tbl tbody tr', { timeout: 15000 });
    const rows = await page.$$('table.tbl tbody tr');
    check(rows.length === 8, `E1 ${name}: /staff lists ${rows.length} roster rows (want 8)`);
    // The default sort is OPEN FINDINGS descending; sort by AGENT to read the order.
    await page.click('table.tbl thead th:nth-child(1) button');
    const agents = (await firstCells(page)).map((t) => t.split('\n')[0]);
    check(agents[0] === 'Archie', `E1 ${name}: the first row by name is Archie (${agents[0]})`);
    const mill = ['Archivist', 'Clerk', 'Dispatcher', 'Inspector', 'Millwright', 'Quartermaster', 'Watchman'];
    check(mill.every((m) => agents.includes(m)), `E1 ${name}: the 7 mill names show (${agents.join(', ')})`);
    check(await page.$(navLink('/staff')) !== null, `${name}: STAFF is in the nav`);
    const na = await page.$$eval('table.tbl tbody td span[title^="not built"]', (s) => s.map((x) => x.innerText.trim()));
    check(na.length === 16 && na.every((t) => t === 'n/a'), `${name}: PRECISION and SPEND read n/a on all 8 rows (${na.length})`);
    await noSideScroll(page, `${name} /staff`);
    await page.screenshot({ path: path.join(shotDir, `staff-${name}.png`), fullPage: true });

    if (name === 'desktop') {
      // E6 on the roster
      await sortsEveryHeader(page, 'roster');

      // E5 kill Watchman, read it back, resume it
      await page.click('table.tbl tbody tr:has(a[href="/staff/watchman"]) button:has-text("KILL…")');
      await page.waitForSelector('.modal[role="dialog"]');
      check(true, 'E5 KILL… opens the in-app modal');
      const confirm = '.modal__actions button:last-child';
      check(await page.$eval(confirm, (b) => b.disabled), 'E5 CONFIRM is disabled before a reason is typed');
      await page.fill('.modal input[aria-label="reason"]', 'drive fixture: noisy');
      check(!(await page.$eval(confirm, (b) => b.disabled)), 'E5 CONFIRM is enabled once a reason is typed');
      await page.click(confirm);
      await page.waitForSelector('.modal', { state: 'detached', timeout: 5000 }).catch(() => {});
      const puts = writes.filter((w) => w.method === 'PUT');
      const b = puts[0] && puts[0].body;
      check(puts.length === 1 && b.name === 'staff-kill-watchman' && b.scope === 'fleet' && b.active === 1 && b.reason === 'drive fixture: noisy',
        `E5 the stub recorded exactly one PUT /api/coord/flags (${JSON.stringify(puts.map((w) => w.body))})`);
      const back = await page.evaluate(async () => (await fetch('/api/coord/flags?prefix=staff-kill-')).json());
      const row = back.flags.find((r) => r.name === 'staff-kill-watchman');
      check(row && row.cleared_at === null && row.active === 1, 'E5 GET /api/coord/flags?prefix=staff-kill- reads staff-kill-watchman ON');
      await page.waitForFunction(() => {
        const tr = document.querySelector('table.tbl tbody tr:has(a[href="/staff/watchman"])');
        return tr && tr.children[9].innerText.trim() === 'ON';
      }, null, { timeout: 5000 }).catch(() => {});
      check(await killCell(page, 'watchman') === 'ON', 'E5 the KILL cell reads ON');

      await page.click('table.tbl tbody tr:has(a[href="/staff/watchman"]) button:has-text("RESUME…")');
      await page.waitForSelector('.modal[role="dialog"]');
      await page.fill('.modal input[aria-label="reason"]', 'drive fixture: quiet');
      await page.click(confirm);
      await page.waitForFunction(() => {
        const tr = document.querySelector('table.tbl tbody tr:has(a[href="/staff/watchman"])');
        return tr && tr.children[9].innerText.trim() === 'off';
      }, null, { timeout: 5000 }).catch(() => {});
      const dels = writes.filter((w) => w.method === 'DELETE');
      check(dels.length === 1 && dels[0].q.name === 'staff-kill-watchman' && dels[0].q.scope === 'fleet',
        `E5 RESUME… sent exactly one DELETE (${JSON.stringify(dels.map((w) => w.q))})`);
      check(await killCell(page, 'watchman') === 'off', 'E5 the read-back after RESUME… is off');
    }

    // E2 click Watchman
    await page.click('table.tbl tbody a.cell-name[href="/staff/watchman"]');
    await page.waitForSelector('table.tbl tbody tr', { timeout: 5000 });
    check(new URL(page.url()).pathname === '/staff/watchman', `E2 ${name}: the URL is /staff/watchman (${new URL(page.url()).pathname})`);
    const titles = await columnText(page, 1);
    check(titles.length === 2 && titles.includes('Secret in a public repo') && titles.includes('Token in a log line'),
      `E2 ${name}: the 2 stub findings show (${titles.join(', ')})`);
    await noSideScroll(page, `${name} /staff/watchman`);
    await page.screenshot({ path: path.join(shotDir, `staff-agent-${name}.png`), fullPage: true });
    if (name === 'desktop') await sortsEveryHeader(page, 'findings');

    // E3 click a finding title
    await page.click('table.tbl tbody a.cell-name:has-text("Secret in a public repo")');
    await page.waitForSelector('dl.lanekv', { timeout: 5000 });
    check(new URL(page.url()).pathname === '/staff/finding/4', `E3 ${name}: the URL is /staff/finding/4 (${new URL(page.url()).pathname})`);
    // E4 the ticket link
    const href = await page.$eval(`dl.lanekv a[href="${TICKET}"]`, (a) => a.getAttribute('href')).catch(() => null);
    check(href === TICKET, `E4 ${name}: the detail links the ticket_url (${href})`);
    await noSideScroll(page, `${name} /staff/finding/4`);
    await page.screenshot({ path: path.join(shotDir, `staff-finding-${name}.png`), fullPage: true });

    check(dialogs === 0, `${name}: no native dialog opened (${dialogs})`);
    check(errors.length === 0, `${name}: console is clean${errors.length ? `: ${errors.slice(0, 2).join(' | ')}` : ''}`);
    await page.close();
  }

  await browser.close();
  server.close();
  console.log(fail.length ? `\nFAILED: ${fail.length}` : `\nall good, shots in ${shotDir}`);
  process.exit(fail.length ? 1 : 0);
}

run().catch((e) => { console.error(e); process.exit(1); });
