import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { clientModeGlobalRefusal, clientModeLoosening, modeKeyOfRepo, repoInClientMode } from '../src/lib/client-mode-guard.js';

// The client approval gate (project-3, 2026-11-12): a bearer may set
// lead_authority_mode.<owner>.<name>=client, but only the human verdict token may
// move it away from client, or remove a protected path of a repo in client mode.
// Driven through worker.fetch over schema.sql in an in-memory sqlite, the
// retired-mode-values.bh-5035 harness.

const HUMAN = 'human-token-fixture';
const SECRET = 'test-secret-fixture';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }
const NO_DB = !DatabaseSync;

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}

function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET, HUMAN_VERDICT_TOKEN: HUMAN } };
}

async function put(env, key, value, human = false) {
  const headers = { authorization: 'Bearer ' + SECRET, 'content-type': 'application/json' };
  if (human) headers['x-human-verdict-token'] = HUMAN;
  const res = await worker.fetch(new Request('https://jobs.test/api/settings', {
    method: 'PUT', headers, body: JSON.stringify({ key, value, actor: 'operator@example.com' }),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const row = (db, k) => { const r = db.prepare('SELECT * FROM settings WHERE key=?').get(k); return r ? { ...r } : null; };


async function lpp(env, op, repo, glob, human = false) {
  const headers = { authorization: 'Bearer ' + SECRET, 'content-type': 'application/json' };
  if (human) headers['x-human-verdict-token'] = HUMAN;
  const res = await worker.fetch(new Request('https://jobs.test/api/lead-protected-paths', {
    method: 'PUT', headers, body: JSON.stringify({ repo, glob, op, added_by: 'test' }),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const KEY = 'lead_authority_mode.example-org.project-3';
const REPO = 'example-org/project-3';

test('CM1: a bearer sets client (tightening); leaving client needs the human token', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  let r = await put(env, KEY, 'client');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(row(db, KEY).value, 'client');
  for (const v of ['lane', 'Lane ']) {
    r = await put(env, KEY, v);
    assert.equal(r.status, 403, JSON.stringify(r.body));
    assert.match(r.body.error, /client approval gate/);
    assert.equal(row(db, KEY).value, 'client', 'nothing written on a refusal');
  }
  r = await put(env, KEY, ' CLIENT ');
  assert.equal(r.status, 200, 'client to client is not a loosening: ' + JSON.stringify(r.body));
  r = await put(env, KEY, 'lane', true);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(row(db, KEY).value, 'lane');
});

test('CM2: a repo with no client row keeps the bearer-only writes', { skip: NO_DB }, async () => {
  const { env } = fresh();
  assert.equal((await put(env, 'lead_authority_mode.example-org.demo-os', 'lane')).status, 200);
  assert.equal((await lpp(env, 'add', 'example-org/demo-os', 'src/a/**')).status, 201);
  assert.equal((await lpp(env, 'remove', 'example-org/demo-os', 'src/a/**')).status, 200);
});

test('CM3: in client mode a bearer may add a glob, not remove one', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  assert.equal((await put(env, KEY, 'client')).status, 200);
  assert.equal((await lpp(env, 'add', REPO, 'src/app/member/*')).status, 201);
  let r = await lpp(env, 'remove', REPO, 'src/app/member/*');
  assert.equal(r.status, 403, JSON.stringify(r.body));
  const live = db.prepare("SELECT COUNT(*) AS n FROM lead_protected_paths WHERE repo='example-org/project-3' AND removed_at IS NULL").get();
  assert.equal(Number(live.n), 1, 'the row stays live');
  r = await lpp(env, 'remove', REPO, 'src/app/member/*', true);
  assert.equal(r.status, 200, JSON.stringify(r.body));
});

test('CM4: clientModeLoosening decision table', () => {
  assert.equal(clientModeLoosening(KEY, 'client', 'lane'), true);
  assert.equal(clientModeLoosening('lead_authority_mode', ' Client', 'x'), true);
  assert.equal(clientModeLoosening(KEY, 'client', 'CLIENT'), false);
  assert.equal(clientModeLoosening(KEY, 'lane', 'client'), false);
  assert.equal(clientModeLoosening(KEY, null, 'lane'), false);
  assert.equal(clientModeLoosening('lead_authority.example-org.project-3', 'client', 'lane'), false);
  assert.equal(clientModeLoosening('lead_authority_modex', 'client', 'lane'), false);
  assert.equal(modeKeyOfRepo('example-org/project-3'), KEY);
});

test('CM5: client is refused on the global key and counts only on the per-repo key', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  for (const v of ['client', ' Client ']) {
    const r = await put(env, 'lead_authority_mode', v);
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.match(r.body.error, /per-repo value only/);
  }
  assert.equal(row(db, 'lead_authority_mode'), null);
  assert.equal((await put(env, 'lead_authority_mode', 'lane')).status, 200);
  db.prepare("UPDATE settings SET value='client' WHERE key='lead_authority_mode'").run();
  assert.equal(await repoInClientMode(env, REPO), false, 'a global client row (raw write) does not make a repo client');
  assert.equal((await put(env, KEY, 'client')).status, 200);
  assert.equal(await repoInClientMode(env, REPO), true);
  assert.equal(clientModeGlobalRefusal('lead_authority_mode', 'lane'), null);
  assert.equal(clientModeGlobalRefusal(KEY, 'client'), null);
});
