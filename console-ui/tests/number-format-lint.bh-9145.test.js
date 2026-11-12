import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

// BH-9145: a count a person reads goes through fmtNum (lib/format.js), so
// 12224 reads 12,224. Plain JS has no types, so this lint flags 4 shapes of
// `${...}` that are numbers by construction or by name:
//   S1 `${<path>.length}` / `${<path>.size}` (a call chain is fine; no
//      arithmetic at the top level, so `${100 / STEPS.length}` is geometry)
//   S2 `${Math.round(` / floor / ceil / trunc
//   S3 `${<path>}` where the same line compares that path to 1 (the plural
//      pattern `x === 1 ? 'item' : 'items'` proves x is a count)
//   S4 `${<path>}` whose last segment is total/count or ends in Total/Count
// A `${` directly after `=` is an htm attribute or prop binding, not text,
// so it never counts. The scan is line based: a `${...}` that spans lines is
// not seen (the BH-9119 lint has the same limit).

const ROOT = fileURLToPath(new URL('../src/screens/', import.meta.url));
const ALLOW = {
  'WorldHex.js': 'a cache key, not text a person reads',
};
// One line the scanner flags that is not a count, keyed by file and a slice of
// the line. Each entry says what the value is instead.
const SITE_ALLOW = [
  ['FlyIdlePanel.js', 'html`<span>${r.size}</span>`', 'a Fly machine size name such as shared-cpu-1x'],
  ['PR.js', '<span class="num" data-usd-basis="api">${total} ', 'a preformatted "$" cost string'],
  ['Ideas.js', '>${mockupCount}</span>', 'mockupCountText() prose, not a number'],
  ['Outcomes.js', 'style=${`width:${Math.round(r.share * 100)}%`}', 'a CSS meter width'],
];
const siteAllowed = (name, line) => SITE_ALLOW.some(([f, slice]) => f === name && line.includes(slice));
// A ratchet, not zero tolerance: a file's count may go down, never up.
// C1 of #9145 converts these files and DELETES this map.
const BASELINE = {
  'Fleet.js': 6, 'Project.js': 5, 'Staff.js': 4, 'Now.js': 3, 'Settings.js': 3,
  'SetupLine.js': 3, 'Ticket.js': 3, 'roadmap/list-view.js': 3, 'staff/agent-learning.js': 3,
  'Connections.js': 2, 'CostBreakdown.js': 2, 'Hub.js': 2, 'Utilization.js': 2,
  'roadmap/board-view.js': 2, 'Config.js': 1, 'ConfigDetail.js': 1, 'Controls.js': 1,
  'CostCapHistory.js': 1, 'Flags.js': 1, 'Lessons.js': 1, 'LlmSites.js': 1,
  'TriageWaste.js': 1, 'WaitingPanel.js': 1, 'roadmap/wave-actions.js': 1,
};

const PATH = String.raw`[A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*)*`;
const PURE_PATH = new RegExp(`^${PATH}$`);
const LEN_PATH = /^(?:\(\)|[A-Za-z_$][\w$]*)(?:\??\.[A-Za-z_$][\w$]*|\(\)|\[\])*\??\.(?:length|size)$/;
const MATH = /^Math\.(?:round|floor|ceil|trunc)\(/;
const COUNT_NAME = /^(?:total|count)$|[a-z0-9_$](?:Total|Count)$/;
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// From the index just after `${`, return [end index of the matching `}`,
// skeleton] where the skeleton keeps only top-level text: the contents of
// (...) and [...] collapse to () and [], and strings collapse to ''.
function readExpr(line, from) {
  let depth = 0;
  let skel = '';
  for (let i = from; i < line.length; i++) {
    const c = line[i];
    if (c === '"' || c === "'" || c === '`') {
      let j = i + 1;
      let tdepth = 0;
      for (; j < line.length; j++) {
        if (line[j] === '\\') { j++; continue; }
        if (c === '`' && line[j] === '$' && line[j + 1] === '{') { tdepth++; j++; continue; }
        if (c === '`' && tdepth > 0 && line[j] === '}') { tdepth--; continue; }
        if (line[j] === c && tdepth === 0) break;
      }
      if (depth === 0) skel += "''";
      i = j;
      continue;
    }
    if (c === '(' || c === '[' || c === '{') {
      if (depth === 0) skel += c;
      depth++;
      continue;
    }
    if (c === ')' || c === ']' || c === '}') {
      if (depth === 0) return [i, skel.trim()];
      depth--;
      if (depth === 0) skel += c;
      continue;
    }
    if (depth === 0) skel += c;
  }
  return [-1, skel.trim()];
}

function scanLine(line) {
  const out = [];
  for (let i = line.indexOf('${'); i !== -1; i = line.indexOf('${', i + 2)) {
    if (i > 0 && line[i - 1] === '=') continue;
    const [end, skel] = readExpr(line, i + 2);
    if (end === -1) continue;
    const expr = line.slice(i + 2, end).trim();
    let hit = false;
    if (MATH.test(expr)) hit = true;
    else if (LEN_PATH.test(skel)) hit = true;
    else if (PURE_PATH.test(expr)) {
      const last = expr.split(/\??\./).pop();
      if (COUNT_NAME.test(last)) hit = true;
      else if (new RegExp(`(?<![\\w$.])${esc(expr)}(?![\\w$])\\s*(?:===|!==|>=|<=|>|<)\\s*1(?![\\d.])`).test(line)) hit = true;
    }
    if (hit && !out.includes(i)) out.push(i);
  }
  return out;
}
const countFile = (src, name = '') => src.split('\n')
  .reduce((n, line) => n + (siteAllowed(name, line) ? 0 : scanLine(line).length), 0);

const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
  e.isDirectory() ? walk(join(dir, e.name)) : e.name.endsWith('.js') ? [join(dir, e.name)] : []);
const files = walk(ROOT).map((p) => ({ name: relative(ROOT, p), src: readFileSync(p, 'utf8') }));
const sites = (f) => f.src.split('\n').flatMap((line, i) => (siteAllowed(f.name, line) ? [] : scanLine(line)).map(() => `${f.name}:${i + 1}: ${line.trim()}`));

test('L1: no screen adds a bare number interpolation over its baseline', () => {
  const over = files.filter((f) => !ALLOW[f.name])
    .filter((f) => countFile(f.src, f.name) > (BASELINE[f.name] ?? 0));
  const detail = over.map((f) => `${f.name}: ${countFile(f.src, f.name)} > baseline ${BASELINE[f.name] ?? 0}\n  `
    + sites(f).join('\n  '));
  assert.deepEqual(over.map((f) => f.name), [],
    'wrap the number in fmtNum(...) from lib/format.js:\n' + detail.join('\n'));
});

test('L2: every baseline, allowlist and site-allow entry is live', () => {
  for (const name of [...Object.keys(BASELINE), ...Object.keys(ALLOW)]) {
    assert.ok(files.find((x) => x.name === name), `listed file ${name} exists`);
  }
  for (const name of Object.keys(ALLOW)) {
    const f = files.find((x) => x.name === name);
    assert.ok(countFile(f.src) > 0, `allowlisted file ${name} still has a bare-number site`);
  }
  for (const [name, slice, why] of SITE_ALLOW) {
    const f = files.find((x) => x.name === name);
    assert.ok(f, `site-allow file ${name} exists`);
    const lines = f.src.split('\n').filter((l) => l.includes(slice));
    assert.ok(lines.length > 0 && lines.every((l) => scanLine(l).length > 0),
      `site-allow ${name} "${slice}" (${why}) still matches a flagged line`);
  }
});

test('L3: the walker sees the screens, including subfolders', () => {
  assert.ok(files.length >= 80, `expected at least 80 screen files, found ${files.length}`);
  assert.ok(files.some((f) => f.name.includes('/')), 'a file in a screens/ subfolder is scanned');
});

test('L4: the scanner decision table', () => {
  const flag = [
    '`${rows.length} rows`',
    '`${rows.filter((r) => r.off === true).length} off`',
    '`${seen.size} seen`',
    '`${Math.round(r.share * 100)}%`',
    '`${Math.floor(s / 60)}m`',
    "`${failed} failed ${failed === 1 ? 'probe' : 'probes'}`",
    "`${names.unstamped} ${names.unstamped === 1 ? 'alert' : 'alerts'}`",
    '`${stops.total} stops`',
    '`${grandTotal} tickets`',
    '`${r.freqCount} merges`',
    'html`<b>${x?.count}</b>`',
  ];
  const pass = [
    '`${fmtNum(rows.length)} rows`',
    '`${fmtNum(Math.round(x))}%`',
    'html`<${Skeleton} rows=${rows.length}/>`',
    '`width:${100 / STEPS.length}%`',
    '`${Math.min(a, 6)}`',
    '`#${pr.number}`',
    '`${r.year}`',
    '`${port}`',
    '`${r.account}`',
    "`${n} of ${m} ${m === 10 ? 'x' : 'y'}`",
    '`${r.merged} ${r.mergedAt === 1}`',
    '`${y.x} ${x === 1}`',
    '`${totals}`',
    '`${label}`',
  ];
  for (const s of flag) assert.equal(scanLine(s).length, 1, `flags exactly once: ${s}`);
  for (const s of pass) assert.deepEqual(scanLine(s), [], `passes: ${s}`);
});
