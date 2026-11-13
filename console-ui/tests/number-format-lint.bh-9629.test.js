import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

// BH-9629 (C1 of #9145): a number a person reads goes through fmtNum
// (lib/format.js), which is fixed to en-US. `.toLocaleString(` with no locale
// changes with the browser, and with a locale it is a second formatter beside
// fmtNum. So no screen calls it. Dates (toLocaleDateString,
// toLocaleTimeString) are out of this scope.

const ROOT = fileURLToPath(new URL('../src/screens/', import.meta.url));
const hitsLocale = (line) => /\.toLocaleString\(/.test(line);

const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
  e.isDirectory() ? walk(join(dir, e.name)) : e.name.endsWith('.js') ? [join(dir, e.name)] : []);
const files = walk(ROOT).map((p) => ({ name: relative(ROOT, p), src: readFileSync(p, 'utf8') }));

test('L5: no screen formats a number with .toLocaleString(', () => {
  const hits = files.flatMap((f) => f.src.split('\n')
    .flatMap((line, i) => (hitsLocale(line) ? [`${f.name}:${i + 1}: ${line.trim()}`] : [])));
  assert.deepEqual(hits, [], 'use fmtNum(...) from lib/format.js:\n  ' + hits.join('\n  '));
});

test('L6: the walker sees the screens, including subfolders', () => {
  assert.ok(files.length >= 80, `expected at least 80 screen files, found ${files.length}`);
  assert.ok(files.some((f) => f.name.includes('/')), 'a file in a screens/ subfolder is scanned');
});

test('L7: the toLocaleString decision table', () => {
  const flag = [
    '`${n.toLocaleString()}`',
    'html`<span>${r.apiCalls.toLocaleString()}</span>`',
    "x.toLocaleString('en-US')",
  ];
  const pass = [
    'fmtNum(r.apiCalls)',
    'd.toLocaleDateString()',
    'd.toLocaleTimeString()',
    "'toLocaleString'",
    'toLocaleStringify(x)',
  ];
  for (const s of flag) assert.equal(hitsLocale(s), true, `flags: ${s}`);
  for (const s of pass) assert.equal(hitsLocale(s), false, `passes: ${s}`);
});
