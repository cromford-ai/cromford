import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import worker from '../src/index.js';
const token = 'fixture-watchdog-only';
const env = { WATCHDOG_SECRET: token, HARNESS_SECRET: 'fixture-jobs-only', KV: { get: async () => '{}' } };
const get = (path, bearer, bindings = env) => worker.fetch(new Request('https://watchdog.example.com' + path,
  { headers: bearer === undefined ? {} : { authorization: `Bearer ${bearer}` } }), bindings);
test('only the dedicated watchdog bearer authenticates a snapshot read', async () => {
  assert.equal((await get('/api/tickets-snapshot', token)).status, 200);
  for (const candidate of [undefined, '', 'fixture-wrong', env.HARNESS_SECRET]) {
    assert.equal((await get('/api/tickets-snapshot', candidate)).status, 403);
  }
});
test('query secrets and missing watchdog configuration fail closed', async () => {
  assert.equal((await get(`/api/tickets-snapshot?s=${token}`)).status, 403);
  assert.equal((await get('/api/tickets-snapshot', token, { ...env, WATCHDOG_SECRET: '' })).status, 403);
});
test('reusing the jobs secret for watchdog authentication fails closed', async () => {
  for (const bindings of [
    { ...env, HARNESS_SECRET: token },
    { ...env, HARNESS_SECRET: ` ${token} `, WATCHDOG_SECRET: ` ${token} ` },
  ]) {
    assert.equal((await get('/api/tickets-snapshot', token, bindings)).status, 403);
  }
  assert.equal((await get('/api/tickets-snapshot', token, { ...env, HARNESS_SECRET: ' ' })).status, 200);
});
test('curl carries the dedicated bearer on a descriptor, never its argument list', () => {
  const lib = fileURLToPath(new URL('../../../bin/lib/watchdog-url.sh', import.meta.url));
  const r = spawnSync('bash', ['-c', '. "$1"; curl() { printf "args:%s\\n" "$*"; cat /dev/fd/3; }; watchdog_curl https://watchdog.example.com/api/status', '_', lib],
    { env: { ...process.env, WATCHDOG_SECRET: token }, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const [args, ...config] = r.stdout.split('\n');
  assert.ok(!args.includes(token));
  assert.match(config.join('\n'), /Authorization: Bearer fixture-watchdog-only/);
});
test('curl does not fall back to the jobs credential', () => {
  const lib = fileURLToPath(new URL('../../../bin/lib/watchdog-url.sh', import.meta.url));
  const r = spawnSync('bash', ['-c', '. "$1"; curl() { echo called; }; watchdog_curl https://watchdog.example.com/api/status', '_', lib],
    { env: { PATH: process.env.PATH, HARNESS_SECRET: 'fixture-jobs-only', WATCHDOG_SECRET: '', HENV: '/nonexistent-fixture' }, encoding: 'utf8' });
  assert.notEqual(r.status, 0);
  assert.equal(r.stdout, '');
});

test('the dedicated file wins over the environment and curl preserves streamed JSON', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'fixture-watchdog-'));
  try {
    const secretFile = join(scratch, '.watchdog-secret');
    writeFileSync(secretFile, 'fixture-file-secret\n', { mode: 0o600 });
    const lib = fileURLToPath(new URL('../../../bin/lib/watchdog-url.sh', import.meta.url));
    const r = spawnSync('bash', ['-c', '. "$1"; curl() { cat /dev/fd/3; cat; }; printf fixture-json-body | watchdog_curl --data-binary @- https://watchdog.example.com/api/status', '_', lib],
      { env: { PATH: process.env.PATH, WATCHDOG_SECRET_FILE: secretFile, WATCHDOG_SECRET: 'fixture-env-secret' }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /Bearer fixture-file-secret/);
    assert.ok(!r.stdout.includes('fixture-env-secret'));
    assert.ok(r.stdout.endsWith('fixture-json-body'));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test('curl refuses values that could inject configuration lines', () => {
  const lib = fileURLToPath(new URL('../../../bin/lib/watchdog-url.sh', import.meta.url));
  for (const secret of ['fixture-"secret', 'fixture-\\secret', 'fixture-\nsecret', 'fixture-\rsecret']) {
    const r = spawnSync('bash', ['-c', '. "$1"; curl() { echo called; }; watchdog_curl https://watchdog.example.com/api/status', '_', lib],
      { env: { PATH: process.env.PATH, WATCHDOG_SECRET: secret, HENV: '/nonexistent-fixture' }, encoding: 'utf8' });
    assert.notEqual(r.status, 0);
    assert.equal(r.stdout, '');
  }
});
