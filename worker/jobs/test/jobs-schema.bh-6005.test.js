import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { composeSchema, jobsSchemaSql, jobsSchemaFile } from './lib/jobs-schema.js';

// BH-6005 (test-corpus child): the node corpus reads the jobs schema through
// lib/jobs-schema.js, which composes worker/jobs/schema.d/. These cases pin
// that the helper gives the same bytes as bin/schema-build.sh, refuses what it
// refuses, sorts the way it sorts, and never writes worker/jobs/schema.sql.

const WORKER = fileURLToPath(new URL('../', import.meta.url));

function scratch(t) {
  const d = mkdtempSync(join(tmpdir(), 'jobs-schema-fixture-'));
  t.after(() => rmSync(d, { recursive: true, force: true }));
  return d;
}

test('J1: jobsSchemaSql() is byte for byte bin/schema-build.sh --worker jobs', () => {
  const want = execFileSync('bash', ['../../bin/schema-build.sh', '--worker', 'jobs'], {
    cwd: WORKER, maxBuffer: 64 * 1024 * 1024,
  });
  assert.ok(want.length > 0, 'schema-build.sh printed a composition');
  assert.equal(Buffer.compare(Buffer.from(jobsSchemaSql(), 'utf8'), want), 0);
});

test('J2: an entry schema-build.sh would refuse makes composeSchema throw', async (t) => {
  await t.test('a stray notes.txt', () => {
    const d = scratch(t);
    writeFileSync(join(d, '0000-a.sql'), 'CREATE TABLE IF NOT EXISTS fixture_a (id INTEGER);\n');
    writeFileSync(join(d, 'notes.txt'), 'fixture\n');
    assert.throws(() => composeSchema(d), (e) => /notes\.txt/.test(e.message) && /is not a fragment/.test(e.message));
  });
  await t.test('a subdirectory with a fragment name', () => {
    const d = scratch(t);
    writeFileSync(join(d, '0000-a.sql'), 'CREATE TABLE IF NOT EXISTS fixture_a (id INTEGER);\n');
    mkdirSync(join(d, '0001-d.sql'));
    assert.throws(() => composeSchema(d), /0001-d\.sql is not a fragment/);
  });
  await t.test('an upper-case name', () => {
    const d = scratch(t);
    writeFileSync(join(d, '0001-A.sql'), 'CREATE TABLE IF NOT EXISTS fixture_a (id INTEGER);\n');
    assert.throws(() => composeSchema(d), /0001-A\.sql is not a fragment/);
  });
  await t.test('an empty dir', () => {
    const d = scratch(t);
    assert.throws(() => composeSchema(d), /holds no fragment/);
  });
});

test('J3: fragments compose in LC_ALL=C order', (t) => {
  const d = scratch(t);
  for (const n of ['0001-a-x', '0001-a_x', '0001-b', '0000-z']) writeFileSync(join(d, `${n}.sql`), `${n}\n`);
  const got = composeSchema(d).split('\n').filter(Boolean);
  assert.deepEqual(got, ['0000-z', '0001-a-x', '0001-a_x', '0001-b']);
  const c = execFileSync('bash', ['-c', 'LC_ALL=C ls | LC_ALL=C sort'], { cwd: d, encoding: 'utf8' })
    .split('\n').filter(Boolean).map((n) => n.replace(/\.sql$/, ''));
  assert.deepEqual(got, c);
});

test('J4: jobsSchemaFile() holds jobsSchemaSql() in a temp dir, never worker/jobs/schema.sql', () => {
  const f = jobsSchemaFile();
  assert.equal(readFileSync(f, 'utf8'), jobsSchemaSql());
  assert.ok(!f.endsWith(join('worker', 'jobs', 'schema.sql')), f);
  assert.ok(f.startsWith(tmpdir()), f);
  assert.equal(jobsSchemaFile(), f, 'one file a process');
});

test('J5: the composition applies twice to a fresh SQLite', async (t) => {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  db.exec(jobsSchemaSql());
  db.close();
});
