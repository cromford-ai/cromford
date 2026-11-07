// BH-9208: the harness-jobs deploy uploads a source map, so a stack from the
// deployed worker names src/ files and lines, not a bundled index.js line
// (Sentry CROMFORD-HARNESS-1Z gave only index.js:74377 and index.js:29323).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const cfg = readFileSync(new URL('../wrangler.jsonc', import.meta.url), 'utf8');

test('S1: wrangler.jsonc sets upload_source_maps to true, and nowhere false', () => {
  assert.match(cfg, /^\s*"upload_source_maps"\s*:\s*true\s*,?\s*$/m);
  const lines = cfg.split('\n').filter((l) => /"upload_source_maps"/.test(l) && !/^\s*\/\//.test(l));
  assert.equal(lines.length, 1, lines.join('\n'));
  assert.ok(!/false/.test(lines[0]), lines[0]);
});
