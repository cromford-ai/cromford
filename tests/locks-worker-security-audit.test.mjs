import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { setImmediate as nextTurn } from 'node:timers/promises';
import worker from '../locks-worker/src/index.js';

const ADMIN = 'fixture-locks-admin';
const MINTER = 'fixture-locks-minter';
const STATIC = 'fixture-locks-static';
const epoch = () => Math.floor(Date.now() / 1000);
const hash = async (value) => Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))).toString('hex');

function database(t) {
  const sql = new DatabaseSync(':memory:');
  sql.exec(readFileSync(new URL('../locks-worker/schema.sql', import.meta.url), 'utf8'));
  t.after(() => sql.close());
  const prepare = (query, bindings = []) => ({
    query, bindings,
    bind: (...values) => prepare(query, values),
    first: async () => {
      const row = sql.prepare(query).get(...bindings) ?? null;
      // Real D1 requests can overlap between awaits. Yield after the read so
      // separate quota checks cannot accidentally look atomic in this adapter.
      await nextTurn();
      return row;
    },
    all: async () => ({ results: sql.prepare(query).all(...bindings) }),
    run: async () => ({ meta: { changes: Number(sql.prepare(query).run(...bindings).changes) } }),
  });
  const DB = {
    prepare,
    // D1 batch is one transaction: no unrelated request can interleave its
    // statements, and a failed audit insertion rolls back token issuance.
    batch: async (statements) => {
      await nextTurn();
      sql.exec('BEGIN IMMEDIATE');
      try {
        const result = statements.map(({ query, bindings }) => ({ meta: { changes: Number(sql.prepare(query).run(...bindings).changes) } }));
        sql.exec('COMMIT');
        return result;
      } catch (error) {
        sql.exec('ROLLBACK');
        throw error;
      }
    },
  };
  return { sql, DB };
}

async function seed(sql, { name = 'partner_minter', token = MINTER, role = 'minter', prefix = 'partner_', createdBy = 'fixture-admin', createdAt = epoch(), revokedAt = null } = {}) {
  sql.prepare(`INSERT INTO tokens (id,name,token_hash,created_by,created_at,expires_at,revoked_at,last_used_at,role,prefix)
    VALUES (?,?,?,?,?,?,?,?,?,?)`).run(`fixture-${name}`, name, await hash(token), createdBy, createdAt, epoch() + 86400, revokedAt, epoch(), role, prefix);
}

async function request(DB, path = '/v1/locks', { token = STATIC, body, env = {} } = {}) {
  const pending = [];
  try {
    const response = await worker.fetch(new Request(`https://locks.example${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }), { DB, ADMIN_TOKEN: ADMIN, HARNESS_TOKENS: JSON.stringify({ [STATIC]: 'fixture-static-machine' }), MINT_CAP: '3', ...env }, {
      waitUntil: (promise) => pending.push(promise),
    });
    return { status: response.status, body: await response.json() };
  } finally {
    await Promise.all(pending);
  }
}

test('F05: every inherited Object.prototype bearer is denied', async (t) => {
  const { DB } = database(t);
  for (const token of Object.getOwnPropertyNames(Object.prototype)) {
    const response = await request(DB, '/v1/locks', { token, env: { HARNESS_TOKENS: '{}' } });
    assert.equal(response.status, 401, token);
  }
});

test('F05: malformed static maps and non-string or empty identities fail closed', async (t) => {
  const { DB } = database(t);
  for (const value of [null, [], STATIC, 7, { [STATIC]: {} }, { [STATIC]: 7 }, { [STATIC]: '' }, { [STATIC]: '  ' }]) {
    assert.equal((await request(DB, '/v1/locks', { env: { HARNESS_TOKENS: JSON.stringify(value) } })).status, 401, JSON.stringify(value));
  }
  assert.equal((await request(DB, '/v1/locks', { env: { HARNESS_TOKENS: '{' } })).status, 401);
});

for (const prefix of ['partner_', 'partner.', 'partner-']) {
  test(`F07: minter list uses literal ${prefix} and machine-only scope`, async (t) => {
    const { sql, DB } = database(t);
    await seed(sql, { name: `${prefix}minter`, prefix });
    await seed(sql, { name: `${prefix}machine`, token: 'fixture-machine', prefix: null, role: 'machine' });
    await seed(sql, { name: 'partnerXoutside', token: 'fixture-outside', prefix: null, role: 'machine' });
    const response = await request(DB, '/v1/admin/tokens', { token: MINTER });
    assert.equal(response.status, 200);
    assert.deepEqual(response.body.tokens.map(({ name }) => name), [`${prefix}machine`]);
    const admin = await request(DB, '/v1/admin/tokens', { token: ADMIN });
    assert.equal(admin.body.tokens.length, 3);
  });
}

test('F08: concurrent requests admit exactly one token at cap=1', async (t) => {
  const { sql, DB } = database(t);
  await seed(sql);
  const results = await Promise.all(Array.from({ length: 8 }, (_, i) => request(DB, '/v1/admin/tokens', {
    token: MINTER, body: { name: `partner_fixture-${i}` }, env: { MINT_CAP: '1' },
  })));
  assert.equal(results.filter(({ status }) => status === 201).length, 1);
  assert.equal(results.filter(({ status }) => status === 429).length, 7);
  assert.equal(sql.prepare("SELECT count(*) AS n FROM tokens WHERE role='machine'").get().n, 1);
  assert.equal(sql.prepare("SELECT count(*) AS n FROM locks_log WHERE action='token-mint'").get().n, 1);
  assert.ok(results.filter(({ status }) => status === 429).every(({ body }) => !body.token));
});

test('F08: rolling limit includes revoked tokens, excludes old issuance, and survives audit retention', async (t) => {
  const { sql, DB } = database(t);
  await seed(sql);
  await seed(sql, { name: 'partner_revoked', token: 'fixture-revoked', role: 'machine', prefix: null, createdBy: 'partner_minter', revokedAt: epoch() });
  await seed(sql, { name: 'partner_old', token: 'fixture-old', role: 'machine', prefix: null, createdBy: 'partner_minter', createdAt: epoch() - 86410 });
  const results = await Promise.all(Array.from({ length: 8 }, (_, i) => request(DB, '/v1/admin/tokens', {
    token: MINTER, body: { name: `partner_fixture-${i}` },
  })));
  assert.equal(results.filter(({ status }) => status === 201).length, 2);
  assert.equal(results.filter(({ status }) => status === 429).length, 6);
  sql.exec('DELETE FROM locks_log');
  assert.equal((await request(DB, '/v1/admin/tokens', { token: MINTER, body: { name: 'partner_fixture-extra' } })).status, 429);
});

test('F08: an audit write failure rolls back token issuance', async (t) => {
  const { sql, DB } = database(t);
  await seed(sql);
  sql.exec("CREATE TRIGGER fixture_reject_audit BEFORE INSERT ON locks_log WHEN NEW.action='token-mint' BEGIN SELECT RAISE(ABORT, 'fixture audit unavailable'); END");
  await assert.rejects(request(DB, '/v1/admin/tokens', { token: MINTER, body: { name: 'partner_fixture-new' } }), /fixture audit unavailable/);
  assert.equal(sql.prepare("SELECT count(*) AS n FROM tokens WHERE role='machine'").get().n, 0);
});

test('static, minted-machine, minter and full-admin lanes preserve their permissions', async (t) => {
  const { sql, DB } = database(t);
  assert.equal((await request(DB, '/v1/acquire', { body: { key: 'fixture-static-key' } })).status, 201);
  const minter = await request(DB, '/v1/admin/tokens', { token: ADMIN, body: { name: 'partner_minter', role: 'minter', prefix: 'partner_' } });
  assert.equal(minter.status, 201);
  assert.equal((await request(DB, '/v1/acquire', { token: minter.body.token, body: { key: 'fixture-denied-key' } })).status, 401);
  assert.equal((await request(DB, '/v1/admin/log', { token: minter.body.token })).status, 403);
  assert.equal((await request(DB, '/v1/admin/tokens', { token: minter.body.token, body: { name: 'outside-fixture' } })).status, 403);
  assert.equal((await request(DB, '/v1/admin/tokens', { token: minter.body.token, body: { name: 'partner_other-minter', role: 'minter' } })).status, 403);
  const machine = await request(DB, '/v1/admin/tokens', { token: minter.body.token, body: { name: 'partner_machine' } });
  assert.equal(machine.status, 201);
  assert.equal((await request(DB, '/v1/acquire', { token: machine.body.token, body: { key: 'fixture-minted-key' } })).status, 201);
  assert.equal((await request(DB, '/v1/admin/tokens', { token: machine.body.token })).status, 401);
  assert.equal((await request(DB, '/v1/admin/revoke', { token: minter.body.token, body: { name: 'partner_minter' } })).body.revoked, 0);
  assert.equal((await request(DB, '/v1/admin/revoke', { token: minter.body.token, body: { id: minter.body.id } })).status, 403);
  assert.equal((await request(DB, '/v1/admin/revoke', { token: minter.body.token, body: { id: machine.body.id } })).body.revoked, 1);
  assert.equal((await request(DB, '/v1/locks', { token: machine.body.token })).status, 401);
  assert.equal((await request(DB, '/v1/admin/log', { token: ADMIN })).status, 200);
  assert.equal(sql.prepare("SELECT count(*) AS n FROM tokens WHERE name='partner_machine'").get().n, 1);
});
