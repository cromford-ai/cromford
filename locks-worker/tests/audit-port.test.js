import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';

// Fixes ported from an outside audit (cromford-ai/cromford#5 and #6), driven
// through worker.fetch against schema.sql in node:sqlite. No wrangler, no network.
//   F05  Bearer constructor / toString is not a harness token.
//   F07  the minter listing matches its prefix literally (_ and % are not wildcards).
//   F08  the mint cap is one conditional INSERT, counted on tokens, not locks_log.
//   6c   an expired lease cannot be renewed.
const SCHEMA = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');
const ADMIN = 'testadmin';
const STATIC = '{"static-tok":"fleet-a"}';

function d1(db) {
  const wrap = (sql, binds) => ({
    first: async () => db.prepare(sql).get(...binds) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => ({ meta: { changes: Number(db.prepare(sql).run(...binds).changes) || 0 } }),
  });
  return {
    prepare: (sql) => ({ ...wrap(sql, []), bind: (...b) => wrap(sql, b) }),
    batch: async (stmts) => { const out = []; for (const s of stmts) out.push(await s.run()); return out; },
  };
}
const open = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const sha = (s) => createHash('sha256').update(s).digest('hex');

const call = (db, path, { method = 'GET', token = ADMIN, body, vars = {}, DB = d1(db) } = {}) => {
  const req = new Request(`https://locks.test${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const env = { DB, ADMIN_TOKEN: ADMIN, HARNESS_TOKENS: STATIC, ...vars };
  return worker.fetch(req, env, { waitUntil() {} })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const mint = (db, token, name, vars, DB) =>
  call(db, '/v1/admin/tokens', { method: 'POST', token, body: { name }, vars, DB });

async function minter(db, prefix) {
  const r = await call(db, '/v1/admin/tokens', { method: 'POST', body: { name: `${prefix}minter`, role: 'minter', prefix } });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body.token;
}

function seedToken(db, id, name, role, prefix, secret = id) {
  const now = Math.floor(Date.now() / 1000);
  db.prepare('INSERT INTO tokens (id,name,token_hash,created_by,created_at,expires_at,role,prefix) VALUES (?,?,?,?,?,?,?,?)')
    .run(id, name, sha(secret), 'admin', now, now + 9999, role, prefix);
}

test('F05 prototype keys are not harness tokens; the static token still works', async () => {
  const db = open();
  for (const tok of ['constructor', 'toString', '__proto__', 'hasOwnProperty']) {
    const r = await call(db, '/v1/locks', { token: tok });
    assert.equal(r.status, 401, `${tok} -> ${r.status}`);
  }
  assert.equal((await call(db, '/v1/locks', { token: 'static-tok' })).status, 200);
});

test('F05 a static token whose value is not a string is refused, the others keep working', async () => {
  const db = open();
  const vars = { HARNESS_TOKENS: '{"obj-tok":{"x":1},"static-tok":"fleet-a"}' };
  assert.equal((await call(db, '/v1/locks', { token: 'obj-tok', vars })).status, 401);
  assert.equal((await call(db, '/v1/locks', { token: 'static-tok', vars })).status, 200);
});

test('F07 a minter listing treats _ in its prefix literally and lists machine tokens only', async () => {
  const db = open();
  seedToken(db, '1', 'a_b-one', 'machine', null);
  seedToken(db, '2', 'axb-two', 'machine', null);
  seedToken(db, '3', 'a_b-min', 'minter', 'a_b-');
  seedToken(db, '4', 'a_b-m2', 'minter', 'a_b-', 'minter-secret');
  const r = await call(db, '/v1/admin/tokens', { token: 'minter-secret' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.tokens.map((t) => t.name), ['a_b-one']);
});

test('F07 a % prefix cannot list everything', async () => {
  const db = open();
  seedToken(db, '1', 'zzz-one', 'machine', null);
  seedToken(db, '2', 'm', 'minter', '%', 'mt');
  const r = await call(db, '/v1/admin/tokens', { token: 'mt' });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.tokens, []);
});

test('F08 the mint cap counts tokens rows: a log wipe does not reset it, a revoked token still counts', async () => {
  const db = open();
  const tok = await minter(db, 'cyg-');
  const vars = { MINT_CAP: '2' };
  assert.equal((await mint(db, tok, 'cyg-one', vars)).status, 201);
  assert.equal((await mint(db, tok, 'cyg-two', vars)).status, 201);
  db.exec('DELETE FROM locks_log');
  const third = await mint(db, tok, 'cyg-three', vars);
  assert.equal(third.status, 429, JSON.stringify(third.body));
  db.exec("UPDATE tokens SET revoked_at=1 WHERE name='cyg-one'");
  assert.equal((await mint(db, tok, 'cyg-four', vars)).status, 429);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM tokens WHERE name LIKE 'cyg-%' AND role='machine'").get().n, 2);
});

test('F08 the cap is one conditional INSERT in a batch with the audit row', async () => {
  const db = open();
  const tok = await minter(db, 'cyg-');
  const seen = [];
  const inner = d1(db);
  const spy = { prepare: (sql) => { seen.push(sql); return inner.prepare(sql); }, batch: (s) => { seen.push('BATCH'); return inner.batch(s); } };
  const r = await mint(db, tok, 'cyg-x', { MINT_CAP: '5' }, spy);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.ok(seen.includes('BATCH'), 'mint uses a D1 batch');
  assert.ok(seen.some((s) => /INSERT INTO tokens[\s\S]*SELECT[\s\S]*WHERE \(SELECT COUNT\(\*\) FROM tokens/.test(s)), seen.join('\n'));
});

test('F08 EXPLAIN QUERY PLAN: the cap count uses the (created_by, created_at) index', () => {
  const db = open();
  const now = Math.floor(Date.now() / 1000);
  const ins = db.prepare('INSERT INTO tokens (id,name,token_hash,created_by,created_at,expires_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 5000; i++) ins.run(`i${i}`, `n${i}`, `h${i}`, `u${i % 50}`, now - i, now + 999);
  const plan = db.prepare('EXPLAIN QUERY PLAN SELECT COUNT(*) FROM tokens WHERE created_by=?1 AND created_at>?2')
    .all('u1', now - 86400).map((r) => r.detail).join(' | ');
  assert.match(plan, /USING (COVERING )?INDEX tokens_created_by_at/, plan);
});

test('6c an expired lease cannot be renewed; a live one can', async () => {
  const db = open();
  const acq = await call(db, '/v1/acquire', { method: 'POST', token: 'static-tok', body: { key: 'k1', ttl_s: 120 } });
  assert.equal(acq.status, 201);
  const renew = () => call(db, '/v1/renew', { method: 'POST', token: 'static-tok', body: { key: 'k1', lease_id: acq.body.lease_id } });
  assert.equal((await renew()).status, 200);
  db.exec('UPDATE locks SET expires_at=1');
  assert.equal((await renew()).status, 404);
  assert.equal(db.prepare("SELECT expires_at FROM locks WHERE key='k1'").get().expires_at, 1);
});
