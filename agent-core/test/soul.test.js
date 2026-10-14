// SPDX-License-Identifier: Apache-2.0
// BH-5558: parseSoul / validateSoul, against the REAL archie soul files.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseSoul, validateSoul } from '../src/index.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const SOUL_DIR = join(HERE, '..', '..', 'prompts', 'archie-soul.d');
// Every reader composes the soul as `cat prompts/archie-soul.d/*.md`: sorted, concatenated.
const archie = readdirSync(SOUL_DIR).filter((f) => f.endsWith('.md')).sort()
  .map((f) => readFileSync(join(SOUL_DIR, f), 'utf8')).join('');
const norm = (s) => s.toLowerCase().replace(/`/g, '').replace(/\s+/g, ' ').trim().replace(/\.$/, '');

test('P1: the archie soul parses into non-empty MAY, NEVER and REPORT lists', () => {
  const s = parseSoul(archie);
  assert.ok(s.may.length > 0, 'MAY is empty');
  assert.ok(s.report.length > 0, 'REPORT is empty');
  assert.equal(s.never.length, 7, `NEVER: ${JSON.stringify(s.never)}`);
  const never = s.never.map(norm);
  assert.ok(never.includes('a push to main'), JSON.stringify(never));
  assert.ok(never.includes('a production db write'), JSON.stringify(never));
  assert.ok(never.includes('a direct merge (gh pr merge)'), JSON.stringify(never));
  assert.ok(never.includes('a write to a client-visible board other than a ticket comment the triage rules allow'), JSON.stringify(never));
  // BH-5751: each box launch is money the owner approves; the parenthesis keeps it one item
  assert.ok(never.some((n) => n.startsWith("launching a box without the owner's yes for that one launch")), JSON.stringify(never));
  assert.ok(s.report.map(norm).includes('a daily factory digest'), JSON.stringify(s.report));
  // the comma inside "(client repos included)" does not split the item
  assert.ok(s.may.some((m) => m.includes('(client repos included)')), JSON.stringify(s.may));
});

test('P2: a soul with no NEVER block fails validation; the archie soul passes', () => {
  const noNever = 'Identity.\nMAY: comment, file tickets.\nREPORT: a digest.\n';
  const v = validateSoul(parseSoul(noNever));
  assert.equal(v.ok, false);
  assert.ok(v.errors.includes('NEVER block missing or empty'), JSON.stringify(v.errors));
  const a = validateSoul(parseSoul(archie));
  assert.equal(a.ok, true, JSON.stringify(a.errors));
  assert.deepEqual(a.errors, []);
  const noMay = validateSoul(parseSoul('NEVER: x.\nREPORT: y.\n'));
  assert.equal(noMay.ok, false);
  assert.ok(noMay.errors.some((e) => e.includes('MAY')));
});

test('P3: list form, CRLF, mid-line labels, repeated labels, bad input', () => {
  assert.deepEqual(parseSoul('NEVER:\n- a\n- b\n').never, ['a', 'b']);
  assert.deepEqual(parseSoul('NEVER:\n* a, still one\n* b\n').never, ['a, still one', 'b']);
  const lf = 'MAY: x, y.\nNEVER: a push to main; a deploy.\nREPORT: z.\n';
  assert.deepEqual(parseSoul(lf.replace(/\n/g, '\r\n')), parseSoul(lf));
  assert.deepEqual(parseSoul(lf).never, ['a push to main', 'a deploy']);
  // a comma or semicolon inside parentheses does not split an item
  assert.deepEqual(parseSoul('NEVER: a merge (gh pr merge, or a rebase; any kind), a push.\n').never,
    ['a merge (gh pr merge, or a rebase; any kind)', 'a push']);
  const mid = 'The NEVER list, and anything else, stays.\nYou MAY change skills: add one, drop one.\nSee REPORT: below.\n';
  assert.deepEqual(parseSoul(mid), { may: [], never: [], report: [] });
  // a block ends at a blank line
  assert.deepEqual(parseSoul('NEVER: a,\nb.\n\nc, d.\n').never, ['a', 'b']);
  // a label that appears twice appends
  assert.deepEqual(parseSoul('NEVER: a.\nMAY: m.\nNEVER: b.\n').never, ['a', 'b']);
  assert.deepEqual(parseSoul(''), { may: [], never: [], report: [] });
  assert.throws(() => parseSoul(undefined), TypeError);
  assert.throws(() => parseSoul(42), TypeError);
});
