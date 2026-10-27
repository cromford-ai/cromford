// Headless drive of the tracker connect sheets (BH-7936) at a phone width.
//
// Not a unit test. The sheets are not mounted on a route yet (onboarding wave
// 2's Onboard.js step 2 mounts them), so this serves a one-file host page that
// imports src/ui/TrackerSheets.js from source, with an import map for preact
// and htm from node_modules and the console's own styles.css plus
// TrackerSheets.css. In chromium at 390x844 it opens each sheet (linear, jira,
// board) and checks what acceptance test 6 asks:
//   - the sheet and every field are visible;
//   - the sheet's bottom edge is the viewport's bottom edge (a bottom sheet);
//   - the body does not scroll sideways (scrollWidth <= innerWidth);
//   - Later closes it, and Escape closes it.
// At 1440x900 the same sheet is a centred panel (its bottom edge is above the
// viewport's). One screenshot per kind and width goes to --shots (default
// ./shots).
//
//   node tests/drive/tracker-sheets.bh-7936-drive.mjs [--shots <dir>]
//
// Exit 0 = every check passed, 1 = a check failed, 2 = a bad argument, no
// node_modules, or no playwright/chromium on this machine.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  if (args[i] !== '--shots' || args[i + 1] === undefined) {
    console.error(`usage: node tests/drive/tracker-sheets.bh-7936-drive.mjs [--shots <dir>] (bad argument: ${args[i]})`);
    process.exit(2);
  }
}
const shotDir = path.resolve(args.includes('--shots') ? args[args.indexOf('--shots') + 1] : path.join(root, 'shots'));
if (!fs.existsSync(path.join(root, 'node_modules', 'preact'))) {
  console.error('console-ui/node_modules is not installed — run `npm ci` first');
  process.exit(2);
}

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch {
  try {
    process.env.NODE_PATH = execSync('npm root -g').toString().trim();
    require('node:module').Module._initPaths();
    ({ chromium } = require('playwright'));
  } catch {
    console.error('playwright is not installed here; the drive cannot run');
    process.exit(2);
  }
}

const HOST = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="/src/styles.css"><link rel="stylesheet" href="/src/ui/TrackerSheets.css">
<script type="importmap">{"imports":{
  "preact":"/node_modules/preact/dist/preact.module.js",
  "preact/hooks":"/node_modules/preact/hooks/dist/hooks.module.js",
  "htm":"/node_modules/htm/dist/htm.module.js"}}</script></head>
<body><div id="app"></div>
<script type="module">
import { h, render } from 'preact';
import { useState } from 'preact/hooks';
import { TrackerSheet } from '/src/ui/TrackerSheets.js';
function Host() {
  const [kind, setKind] = useState(null);
  return h('main', null,
    ['linear', 'jira', 'board'].map((k) => h('button', { id: 'open-' + k, type: 'button', onClick: () => setKind(k) }, 'open ' + k)),
    h('p', { id: 'state' }, kind ? 'open' : 'closed'),
    kind ? h(TrackerSheet, { kind, project: 'drive', onLater: () => setKind(null), onConnected: () => {} }) : null);
}
render(h(Host), document.getElementById('app'));
</script></body></html>`;

const MIME = { '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/') { res.writeHead(200, { 'content-type': 'text/html' }); res.end(HOST); return; }
  const file = path.join(root, path.normalize(u.pathname));
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404); res.end(); return;
  }
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/`;

const FIELDS = { linear: ['api_key', 'team', 'label'], jira: ['site', 'email', 'api_token', 'project_key', 'status_todo', 'status_in_progress', 'status_review', 'status_closed'], board: ['api_base', 'token'] };
const fails = [];
const check = (name, cond, detail = '') => { if (!cond) fails.push(`${name}${detail ? ` (${detail})` : ''}`); };

let browser;
try {
  browser = await chromium.launch();
} catch (e) {
  console.error(`chromium could not start: ${e.message.split('\n')[0]}`);
  server.close();
  process.exit(2);
}
fs.mkdirSync(shotDir, { recursive: true });
try {
  for (const [w, hgt] of [[390, 844], [1440, 900]]) {
    const page = await browser.newPage({ viewport: { width: w, height: hgt } });
    await page.goto(base);
    for (const kind of Object.keys(FIELDS)) {
      await page.click(`#open-${kind}`);
      const sheet = page.locator('.tsheet[role="dialog"]');
      await sheet.waitFor({ state: 'visible' });
      for (const f of FIELDS[kind]) {
        const input = page.locator(`.tsheet input[name="${f}"]`);
        await input.scrollIntoViewIfNeeded();
        check(`${w}px ${kind}: ${f} visible`, await input.isVisible());
      }
      check(`${w}px ${kind}: Later visible`, await page.getByRole('button', { name: 'Later' }).isVisible());
      check(`${w}px ${kind}: Test and connect visible`, await page.getByRole('button', { name: 'Test and connect' }).isVisible());
      const box = await sheet.boundingBox();
      const bottom = box.y + box.height;
      if (w === 390) {
        check(`390px ${kind}: bottom sheet`, Math.abs(bottom - hgt) <= 1, `bottom=${bottom} viewport=${hgt}`);
        check(`390px ${kind}: full width`, Math.abs(box.width - w) <= 1, `width=${box.width}`);
      } else {
        check(`1440px ${kind}: centred panel`, bottom < hgt - 1 && box.width <= 521, `bottom=${bottom} width=${box.width}`);
      }
      const sw = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
      check(`${w}px ${kind}: no horizontal body scroll`, sw[0] <= sw[1], `scrollWidth=${sw[0]} innerWidth=${sw[1]}`);
      await page.screenshot({ path: path.join(shotDir, `tracker-sheet-${kind}-${w}.png`) });
      await page.getByRole('button', { name: 'Later' }).click();
      check(`${w}px ${kind}: Later closes`, (await sheet.count()) === 0 && (await page.textContent('#state')) === 'closed');
      await page.click(`#open-${kind}`);
      await sheet.waitFor({ state: 'visible' });
      await page.keyboard.press('Escape');
      check(`${w}px ${kind}: Escape closes`, (await sheet.count()) === 0 && (await page.textContent('#state')) === 'closed');
    }
    await page.close();
  }
} finally {
  await browser.close();
  server.close();
}
for (const f of fails) console.log(`FAIL: ${f}`);
console.log(`tracker-sheets drive: ${fails.length ? 'FAILED' : 'ok'} (${fails.length} failed); shots in ${shotDir}`);
process.exit(fails.length ? 1 : 0);
