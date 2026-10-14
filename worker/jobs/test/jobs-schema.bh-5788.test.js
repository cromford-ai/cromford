import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { composeSchema } from './lib/jobs-schema.js';

// BH-5788: a new schema.d fragment is <yyyymmddhhmm>-<ticket-key>-<name>.sql.
// The node reader must accept the same names bin/schema-build.sh composes, in
// the same order (every NNNN fragment first, then the stamps), byte for byte.

const REPO = fileURLToPath(new URL('../../../', import.meta.url));

function scratch(t) {
  const root = mkdtempSync(join(tmpdir(), 'jobs-schema-5788-fixture-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const d = join(root, 'worker', 'jobs', 'schema.d');
  mkdirSync(d, { recursive: true });
  return { root, d };
}

test('J6: a stamp-key fragment composes after every NNNN one, the same bytes as schema-build.sh', (t) => {
  const { root, d } = scratch(t);
  writeFileSync(join(d, '202610140000-bh-1-b.sql'), 'CREATE TABLE IF NOT EXISTS fixture_b (id INTEGER);\n');
  writeFileSync(join(d, '0001-a.sql'), 'CREATE TABLE IF NOT EXISTS fixture_a (id INTEGER);\n');
  const got = composeSchema(d);
  assert.equal(got, 'CREATE TABLE IF NOT EXISTS fixture_a (id INTEGER);\n'
    + 'CREATE TABLE IF NOT EXISTS fixture_b (id INTEGER);\n');
  const shell = execFileSync('bash', [join(REPO, 'bin', 'schema-build.sh'), '--root', root, '--worker', 'jobs'], {
    encoding: 'utf8', env: { ...process.env, HARNESS_TEST_SANDBOX: '1' },
  });
  assert.equal(got, shell);
});

test('J6: an 8-digit date prefix is not a fragment name', (t) => {
  const { d } = scratch(t);
  writeFileSync(join(d, '0001-a.sql'), 'CREATE TABLE IF NOT EXISTS fixture_a (id INTEGER);\n');
  writeFileSync(join(d, '20261014-x.sql'), 'CREATE TABLE IF NOT EXISTS fixture_x (id INTEGER);\n');
  assert.throws(() => composeSchema(d), /20261014-x\.sql is not a fragment/);
});
