import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5750 T1.4: the owner gate, driven through the real worker.fetch on real
// SQLite. Every Orgo / Fly pool type is accepted only from an actor named in
// the worker secret BOX_OPS_OWNERS; anyone else gets 403 owner_only, one
// refused:owner audit row, and no command row. The five BH-2518 types are not
// gated.

const SECRET = 'test-secret-fixture';
const OWNER = 'owner@example.com';
const NOW_MS = Date.parse('2026-10-10T12:00:00Z');

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return env;
}
const UNSET = Symbol('unset');
async function call(env, body, owners = OWNER) {
  const e = { DB: env.DB, HARNESS_SECRET: SECRET };
  if (owners !== UNSET) e.BOX_OPS_OWNERS = owners;
  const res = await worker.fetch(new Request('https://jobs.test/api/box-commands', {
    method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: JSON.stringify(body),
  }), e);
  return { status: res.status, body: await res.json() };
}
const cmds = (db) => db.prepare('SELECT * FROM box_commands_v2 ORDER BY id').all();
const refused = (db) => db.prepare("SELECT * FROM hub_lease_changes WHERE action='box_command_refused' ORDER BY id").all();
const restart = (over = {}) => ({ box: 'hub', type: 'orgo_restart', target: 'project-3', reason: 'hung', confirm: true, actor: OWNER, ...over });

test('O1: the owner is 201 and the row records the owner as requested_by', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env, restart());
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.command.type, 'orgo_restart');
  assert.equal(r.body.command.target, 'project-3');
  assert.equal(r.body.command.requested_by, OWNER);
  assert.equal(cmds(env.db).length, 1);
});

test('O2/O3: a non-owner, console, unknown, a look-alike and no actor are 403 owner_only, audited, nothing queued', async (t) => {
  const env = await open(t); if (!env) return;
  const actors = ['someone@example.net', 'console', 'unknown', 'owner@example.com.example.net', 'xowner@example.com', undefined, ''];
  for (const actor of actors) {
    const r = await call(env, restart({ actor }));
    assert.equal(r.status, 403, `actor ${JSON.stringify(actor)}`);
    assert.deepEqual(r.body, { error: 'owner_only' });
  }
  assert.equal(cmds(env.db).length, 0);
  const a = refused(env.db);
  assert.equal(a.length, actors.length);
  for (const x of a) { assert.equal(x.outcome, 'refused:owner'); assert.equal(x.target, 'hub'); }
});

test('O4: an unset or blank secret makes nobody an owner, the owner too', async (t) => {
  const env = await open(t); if (!env) return;
  for (const owners of [UNSET, '', '  ', ' , ']) {
    const r = await call(env, restart(), owners);
    assert.equal(r.status, 403, `owners ${String(owners)}`);
  }
  assert.equal(cmds(env.db).length, 0);
});

test('O5: owner matching trims and lower-cases both sides, in a comma list', async (t) => {
  const env = await open(t); if (!env) return;
  const r1 = await call(env, restart(), ' other@example.net , OWNER@EXAMPLE.COM ');
  assert.equal(r1.status, 201);
  const r2 = await call(env, restart({ target: 'project-4', actor: ' Owner@Example.com ' }), OWNER);
  assert.equal(r2.status, 201, 'an actor with another case or spaces is the same owner');
});

test('O6: the five BH-2518 types stay open to console', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env, { box: 'hub', type: 'backup_now', reason: 'nightly', confirm: true, actor: 'console' }, UNSET);
  assert.equal(r.status, 201);
});

test('O7: every one of the nine new types is gated, before its args are read', async (t) => {
  const env = await open(t); if (!env) return;
  for (const type of ['orgo_restart', 'orgo_stop', 'orgo_resize_quote', 'orgo_resize', 'orgo_retire',
    'orgo_launch_quote', 'orgo_launch', 'fly_pool_cap', 'fly_onboard']) {
    const r = await call(env, { box: 'hub', type, target: 'x', reason: 'r', confirm: true, actor: 'console' });
    assert.equal(r.status, 403, type);
  }
});
