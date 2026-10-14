// Headless drive of the BUILT bundle for the Kanban card step labels (BH-6668).
//
// Not a unit test. It serves dist/ over http with the kanban pipeline read
// stubbed (one card each in building, review, merge_queue and merged_deployed,
// plus one failed card; any other /api/* read answers from fixtures.mjs or {}),
// opens /kanban in chromium at 390x844 and 1280x900, and measures what the
// ticket promised:
//   both:  inside every card track, no two visible step labels intersect, and
//          at least one card shows exactly one label (so an empty board fails);
//   390px: the page never scrolls sideways.
// It writes one screenshot per viewport to --shots (default ./shots).
//
//   npm run build && node tests/drive/kanban-steps.bh-6668-drive.mjs [--shots <dir>]
//
// Exit 0 = every check passed, 1 = a check failed, 2 = a bad argument or no dist/.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { ROUTES } from './fixtures.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  if (args[i] !== '--shots' || args[i + 1] === undefined) {
    console.error(`usage: node tests/drive/kanban-steps.bh-6668-drive.mjs [--shots <dir>] (bad argument: ${args[i]})`);
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

const card = (id, ticket, project, stage, over = {}) => ({ id, project, ticket, ticket_key: ticket, bkey: ticket, stage, age_min: 12, tier: 2, ...over });
const pipeline = {
  snapshot_age_min: 3,
  counts: { queued: 0, building: 1, merge_queue: 1, review: 1, merged_deployed: 1, dead_failed: 1 },
  columns: {
    queued: [],
    building: [card(101, 'TK-104', 'project-3', 'executing')],
    merge_queue: [card(103, 'TK-7', 'project-1', 'queued', { pr_url: 'https://github.com/example-org/project-1/pull/7' })],
    review: [card(105, 'TK-3', 'project-9', 'pr_created', { pr_url: 'https://github.com/example-org/project-9/pull/3' })],
    merged_deployed: [card(107, 'TK-99', 'project-3', 'merged')],
    dead_failed: [card(109, 'TK-70', 'project-3', 'failed', { verdict: 'typecheck failed three times' })]
  }
};
const EXTRA = { '/api/dash/kanban/pipeline': pipeline };
const VIEWPORTS = [[390, 844], [1280, 900]];

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(EXTRA[url.pathname] || ROUTES[url.pathname] || {}));
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

// In the page: per card track, the visible labels and every pair that intersects.
function measureLabels() {
  return [...document.querySelectorAll('.card .card__track')].map((t) => {
    const lbls = [...t.querySelectorAll('.st .lbl')].filter((el) => el.getClientRects().length > 0);
    const boxes = lbls.map((el) => ({ text: el.textContent.trim(), r: el.getBoundingClientRect() }));
    const overlaps = [];
    for (let i = 0; i < boxes.length; i++) {
      for (let j = i + 1; j < boxes.length; j++) {
        const a = boxes[i].r; const b = boxes[j].r;
        if (a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom) overlaps.push(`${boxes[i].text} x ${boxes[j].text}`);
      }
    }
    return { track: t.querySelector('.track')?.getAttribute('aria-label') || '?', visible: boxes.map((b) => b.text), overlaps };
  });
}

async function run() {
  fs.mkdirSync(shotDir, { recursive: true });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();
  for (const [width, height] of VIEWPORTS) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(`${base}/kanban`, { waitUntil: 'networkidle' });
    await page.waitForSelector('.card .card__track', { timeout: 15000 });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(300);

    const tracks = await page.evaluate(measureLabels);
    check(tracks.length >= 4, `${width}px: ${tracks.length} card tracks drawn (4 expected)`);
    for (const t of tracks) {
      check(t.overlaps.length === 0, `${width}px ${t.track}: visible labels [${t.visible.join(', ')}]${t.overlaps.length ? ` overlap: ${t.overlaps.join('; ')}` : ' do not overlap'}`);
    }
    check(tracks.some((t) => t.visible.length === 1), `${width}px: at least one card shows exactly one label`);
    if (width === 390) {
      const sw = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth }));
      check(sw.sw <= sw.iw, `390px: no horizontal page scroll (scrollWidth ${sw.sw} <= innerWidth ${sw.iw})`);
    }
    check(errors.length === 0, `${width}px: no page errors${errors.length ? ` (${errors.join(' | ')})` : ''}`);
    const shot = path.join(shotDir, `kanban-steps-${width}.png`);
    await page.screenshot({ path: shot, fullPage: true });
    console.log(`shot ${shot}`);
    await page.close();
  }
  await browser.close();
  server.close();
  console.log(fail.length ? `${fail.length} check(s) failed` : 'all checks passed');
  process.exit(fail.length ? 1 : 0);
}

run().catch((e) => { console.error(e); server.close(); process.exit(1); });
