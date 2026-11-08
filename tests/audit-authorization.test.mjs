import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { generateKeyPairSync } from 'node:crypto';
import worker from '../worker/jobs/src/index.js';
import { openDb, d1 } from '../worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { onRequest as coord } from '../console-ui/functions/api/coord/[[path]].js';
import { onRequest as dash } from '../console-ui/functions/api/[[path]].js';
import { _resetCertsCache } from '../console-ui/functions/_lib/access-identity.js';

const MAIN = 'fixture-fleet-token';
const OPS = 'fixture-owner-token';
const QA = 'fixture-qa-read-token';
const OWNER = 'owner@example.com';
const envFor = (o) => ({ DB: o.DB, HARNESS_SECRET: MAIN, BOX_OPS_TOKEN: OPS, BOX_OPS_OWNERS: OWNER, QA_READ_TOKEN: QA });
const command = { box: 'hub', type: 'orgo_stop', target: 'newbox', confirm: true, reason: 'fixture maintenance', actor: OWNER };
const request = (path, { method = 'GET', body, headers = {} } = {}) => new Request(`https://example.test${path}`, {
  method, headers: { 'content-type': 'application/json', ...headers }, ...(body ? { body: JSON.stringify(body) } : {})
});
const jobs = (env, path, opts = {}) => worker.fetch(request(`/api/${path}`, { ...opts, headers: { authorization: `Bearer ${MAIN}`, ...opts.headers } }), env);
const proxy = (path, env, opts = {}) => coord({ request: request(`/api/coord/${path}`, {
  ...opts, headers: { cookie: 'dash=fixture-owner', ...opts.headers }
}), env, params: { path: path.split('/') } });

test('F01 fleet credentials cannot impersonate an owner; independent owner credential preserves the command flow', async () => {
  const o = await openDb(); const env = envFor(o);
  for (const token of [undefined, '', 'fixture-wrong-owner-token', MAIN]) {
    const res = await jobs(env, 'box-commands', { method: 'POST', body: command,
      headers: token === undefined ? {} : { 'x-box-ops-token': token } });
    assert.equal(res.status, 403, `owner credential ${token}`);
    assert.equal(o.db.prepare('SELECT count(*) AS n FROM box_commands_v2').get().n, 0);
  }
  for (const configured of ['', undefined, MAIN]) {
    assert.equal((await jobs({ ...env, BOX_OPS_TOKEN: configured }, 'box-commands', { method: 'POST', body: command,
      headers: { 'x-box-ops-token': MAIN } })).status, 403);
  }
  assert.equal((await jobs(env, 'box-commands', { method: 'POST', body: { ...command, actor: 'other@example.com' },
    headers: { 'x-box-ops-token': OPS } })).status, 403);
  const approved = await jobs(env, 'box-commands', { method: 'POST', body: command, headers: { 'x-box-ops-token': OPS } });
  assert.equal(approved.status, 201, await approved.clone().text());
  assert.equal((await approved.json()).command.requested_by, OWNER);
});

test('F01 Pages releases its owner credential only with verified Access identity, overwriting browser credentials', async (t) => {
  _resetCertsCache();
  const key = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  const jwk = { ...await crypto.subtle.exportKey('jwk', key.publicKey), kid: 'fixture-key' };
  const enc = (v) => Buffer.from(JSON.stringify(v)).toString('base64url');
  const data = `${enc({ alg: 'RS256', kid: jwk.kid })}.${enc({ email: OWNER, iss: 'https://fixture.cloudflareaccess.com',
    aud: ['fixture-aud'], exp: 9999999999 })}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key.privateKey, new TextEncoder().encode(data));
  const token = `${data}.${Buffer.from(sig).toString('base64url')}`;
  const o = await openDb(); const env = { ...envFor(o), CF_ACCESS_TEAM_DOMAIN: 'fixture.cloudflareaccess.com', CF_ACCESS_AUD: 'fixture-aud' };
  const seen = [];
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    if (String(url).includes('/cdn-cgi/access/certs')) return Response.json({ keys: [jwk] });
    if (String(url).includes('/api/dash/fleet')) return Response.json({});
    seen.push(init);
    return worker.fetch(new Request(url, init), env);
  });
  for (const headers of [{}, { 'cf-access-authenticated-user-email': OWNER },
    { 'cf-access-authenticated-user-email': OWNER, 'cf-access-jwt-assertion': 'fixture-forgery', 'x-box-ops-token': OPS }]) {
    assert.equal((await proxy('box-commands', env, { method: 'POST', body: command, headers })).status, 403);
    assert.equal(seen.length, 0);
  }
  const res = await proxy('box-commands', env, { method: 'POST', body: { ...command, actor: 'other@example.com' },
    headers: { 'cf-access-authenticated-user-email': OWNER, 'cf-access-jwt-assertion': token, 'x-box-ops-token': 'fixture-browser' } });
  assert.equal(res.status, 201, await res.clone().text());
  assert.equal(seen[0].headers['x-box-ops-token'], OPS);
  assert.equal((await res.json()).command.requested_by, OWNER);
});

test('F02 QA reads are explicitly scoped at the proxy and worker, even beside a forged dash cookie', async (t) => {
  const o = await openDb(); const env = envFor(o); const seen = [];
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    if (String(url).includes('/api/dash/fleet')) return Response.json({});
    seen.push(init); return worker.fetch(new Request(url, init), env);
  });
  for (const cookie of ['dashqa=fixture-preview', 'dash=fixture-forged; dashqa=fixture-preview']) {
    for (const path of ['otp', 'box-commands', 'settings', 'settings/hub_envelope_public_key', 'new-secret-route', 'steer/outbox',
      'heartbeats', 'jobs/', 'jobs/../otp', 'jobs%2f..%2fotp']) {
      const before = seen.length;
      assert.equal((await proxy(path, env, { headers: { cookie } })).status, 403, path);
      assert.equal(seen.length, before, 'sensitive route must never reach jobs');
    }
    const res = await proxy('jobs', env, { headers: { cookie } });
    assert.equal(res.status, 200, await res.clone().text());
    assert.equal(seen.at(-1).headers.authorization, `Bearer ${QA}`);
  }
  const missing = await proxy('jobs', { ...env, QA_READ_TOKEN: undefined }, { headers: { cookie: 'dashqa=fixture-preview' } });
  assert.equal(missing.status, 503);
  for (const path of ['otp', 'box-commands', 'settings', 'new-secret-route', 'jobs/fixture-job']) {
    assert.equal((await jobs(env, path, { headers: { authorization: `Bearer ${QA}` } })).status, 401, path);
  }
  assert.equal((await jobs(env, 'jobs', { method: 'POST', body: {}, headers: { authorization: `Bearer ${QA}` } })).status, 401);
  assert.equal((await jobs(env, 'jobs', { headers: { authorization: `Bearer ${QA}` } })).status, 200);
});

test('F02 QA jobs expose display fields only, including when new opaque columns are added; operator data is preserved', async (t) => {
  const o = await openDb(); const env = envFor(o);
  o.db.exec('ALTER TABLE jobs ADD COLUMN future_opaque TEXT');
  o.db.prepare(`INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at, meta, future_opaque)
    VALUES ('fixture-job', 'fixture-project', 'build', 'box3', 'execute', 'running', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z', ?, ?)`)
    .run('{"payload":"fixture-sensitive-metadata"}', 'fixture-future-secret');
  o.db.prepare("INSERT INTO job_heartbeats (job_id, beat_at, box, note) VALUES ('fixture-job', '2026-11-05T00:00:00Z', 'box3', 'fixture-sensitive-note')").run();
  o.db.prepare("INSERT INTO pause_flags (name, active, actor, reason, updated_at, value) VALUES ('fixture-flag', 1, 'fixture-actor', 'fixture-sensitive-reason', '2026-11-05T00:00:00Z', 'fixture-sensitive-value')").run();
  const qaRes = await jobs(env, 'jobs', { headers: { authorization: `Bearer ${QA}` } });
  const data = await qaRes.json();
  assert.equal(qaRes.status, 200); assert.equal(data.jobs[0].id, 'fixture-job');
  assert.equal(data.jobs[0].project, 'fixture-project'); assert.equal(data.jobs[0].heartbeating, true);
  for (const key of ['meta', 'beat_note', 'retry_reason', 'future_opaque']) assert.equal(key in data.jobs[0], false, key);
  assert.doesNotMatch(JSON.stringify(data), /fixture-sensitive|fixture-future-secret/);
  const operator = await (await jobs(env, 'jobs')).json();
  assert.equal(operator.jobs[0].future_opaque, 'fixture-future-secret');
  assert.equal(operator.jobs[0].beat_note, 'fixture-sensitive-note');
  assert.match(operator.jobs[0].meta, /fixture-sensitive-metadata/);
  const qaFlags = await (await jobs(env, 'flags', { headers: { authorization: `Bearer ${QA}` } })).json();
  assert.equal(qaFlags.flags.find((f) => f.name === 'fixture-flag').active, 1);
  assert.doesNotMatch(JSON.stringify(qaFlags), /fixture-sensitive|fixture-actor/);
  const operatorFlags = await (await jobs(env, 'flags')).json();
  assert.match(JSON.stringify(operatorFlags), /fixture-sensitive-reason/);
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => String(url).includes('/api/dash/fleet')
    ? Response.json({}) : worker.fetch(new Request(url, init), env));
  const throughPages = await (await proxy('jobs', env, { headers: { cookie: 'dashqa=fixture-preview' } })).json();
  assert.equal(throughPages.jobs[0].id, 'fixture-job');
  assert.doesNotMatch(JSON.stringify(throughPages), /fixture-sensitive|fixture-future-secret/);
});

test('F06 unauthenticated or unverifiable merge retries cannot alter the command ledger; verified retry rekeys once', async (t) => {
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE commands (id INTEGER PRIMARY KEY, ckey TEXT UNIQUE, type TEXT, status TEXT, result TEXT, payload TEXT);
    INSERT INTO commands VALUES (1, 'fixture-project:TK-1:merge_pr', 'merge_pr', 'refused', 'refused: head moved since sha aaaaaaaa', '{}')`);
  const env = { CONSOLE_DB: d1(db) }; let probe = 403; let calls = 0;
  t.mock.method(globalThis, 'fetch', async (url) => {
    calls++;
    if (probe === 'offline') throw new Error('fixture offline');
    return Response.json({}, { status: String(url).endsWith('/api/dash/fleet') ? probe : 200 });
  });
  const body = { type: 'merge_pr', project: 'fixture-project', ticket: 'TK-1', verdict_sha: 'b'.repeat(40) };
  const run = (cookie) => dash({ request: request('/api/dash/action', { method: 'POST', body, headers: cookie ? { cookie } : {} }), env });
  const snapshot = () => JSON.stringify(db.prepare('SELECT * FROM commands ORDER BY id').all());
  const before = snapshot();
  for (const cookie of [undefined, 'dash=fixture-invalid']) {
    assert.equal((await run(cookie)).status, 403);
    assert.equal(snapshot(), before);
  }
  probe = 'offline'; assert.equal((await run('dash=fixture-owner')).status, 403); assert.equal(snapshot(), before);
  probe = 200; assert.equal((await run('dash=fixture-owner')).status, 200);
  assert.equal(db.prepare('SELECT ckey FROM commands').get().ckey, 'fixture-project:TK-1:merge_pr:refused:1');
  const after = snapshot(); assert.equal((await run('dash=fixture-owner')).status, 200); assert.equal(snapshot(), after);
  assert.ok(calls > 0);
});

test('F09 generic settings cannot overwrite the hub key; its dedicated credential gate remains usable', async () => {
  const o = await openDb(); const env = { ...envFor(o), ENVELOPE_HUB_TOKEN: 'fixture-hub-token' };
  const value = () => o.db.prepare("SELECT value FROM settings WHERE key='hub_envelope_public_key'").get().value;
  const before = value();
  const res = await jobs(env, 'settings', { method: 'PUT', body: { key: 'hub_envelope_public_key', value: 'fixture-corrupted-key' } });
  assert.equal(res.status, 403); assert.equal(value(), before);
  const pem = generateKeyPairSync('rsa', { modulusLength: 2048 }).publicKey.export({ type: 'spki', format: 'pem' });
  for (const token of [undefined, 'fixture-wrong-hub-token']) {
    const headers = token ? { 'x-envelope-hub-token': token } : {};
    assert.equal((await jobs(env, 'secrets/envelope/public-key', { method: 'PUT', body: { pem }, headers })).status, 403);
    assert.equal(value(), before);
  }
  assert.equal((await jobs(env, 'secrets/envelope/public-key', { method: 'PUT', body: { pem },
    headers: { 'x-envelope-hub-token': env.ENVELOPE_HUB_TOKEN } })).status, 200);
  assert.equal(value(), pem);
  assert.equal(o.db.prepare("SELECT count(*) AS n FROM secret_envelope_events WHERE event='public_key_set'").get().n, 1);
});
