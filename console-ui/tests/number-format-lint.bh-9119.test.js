import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

// BH-9119: a number a person reads goes through lib/format.js (fmtNum, fmtUsd),
// which groups thousands. A `toFixed(` or a literal `$${` in a screen prints an
// ungrouped number, so neither may come back outside this allowlist.

const ROOT = fileURLToPath(new URL('../src/screens/', import.meta.url));
const ALLOW = {
  'WorldHex.js': 'SVG viewBox and coordinates, not read by a person',
};
const BANNED = [/\.toFixed\(/, /\$\$\{/];

const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
  e.isDirectory() ? walk(join(dir, e.name)) : e.name.endsWith('.js') ? [join(dir, e.name)] : []);
const files = walk(ROOT).map((p) => ({ name: relative(ROOT, p), src: readFileSync(p, 'utf8') }));
const hits = (f) => f.src.split('\n').flatMap((line, i) =>
  BANNED.some((re) => re.test(line)) ? [`${f.name}:${i + 1}: ${line.trim()}`] : []);

test('no screen prints a number with toFixed( or a literal $${ outside the allowlist', () => {
  const offenders = files.filter((f) => !ALLOW[f.name]).flatMap(hits);
  assert.deepEqual(offenders, [], 'use fmtNum/fmtUsd from lib/format.js:\n' + offenders.join('\n'));
});

test('the walker sees the screens, including subfolders', () => {
  assert.ok(files.length >= 80, `expected at least 80 screen files, found ${files.length}`);
  assert.ok(files.some((f) => f.name.includes('/')), 'a file in a screens/ subfolder is scanned');
});

test('every allowlist entry still matches something', () => {
  for (const name of Object.keys(ALLOW)) {
    const f = files.find((x) => x.name === name);
    assert.ok(f, `allowlisted file ${name} exists`);
    assert.ok(hits(f).length > 0, `allowlisted file ${name} still has a banned pattern`);
  }
});
