import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// POST /api/wakes/nudge (BH-2754, Ask 2 of #2751).
//
// Until this route only a GitHub webhook wrote a `wakes` row, so a ticket
// nobody touched on GitHub never rang the doorbell. bin/untriaged-wake.sh posts
// here once per untriaged or dep-unblocked ticket. The once-only key is the
// existing UNIQUE idx_wakes_dedupe(repo,kind,key,minute) with minute
// 'nudge:<dedupe>', so the assertions are on rows LEFT in a node:sqlite
// database that had schema.sql applied, driven through `worker.fetch` (D2).
// A bad body must run no INSERT at all (D11), so every statement is recorded.

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';

// Same D1-shaped adapter as wakes-prune.bh-1267: `all` answers {results},
// `run` answers {meta:{changes}}, every statement is recorded.
function d1(db, calls) {
  const exec = (sql) => {
    calls.push(sql.replace(/\s+/g, ' ').trim());
    return db.prepare(sql);
  };
  const shape = (sql, binds) => ({
    all: async () => ({ results: exec(sql).all(...binds) }),
    first: async () => exec(sql).get(...binds) ?? null,
    run: async () => {
      const r = exec(sql).run(...binds);
      return { meta: { changes: r.changes, last_row_id: Number(r.lastInsertRowid) } };
    },
  });
  return {
    prepare(sql) {
      return { bind: (...b) => shape(sql, b), ...shape(sql, []) };
    },
  };
}

async function fixture(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const calls = [];
  return { db, calls, DB: d1(db, calls) };
}

const nudge = (fx, body, { secret = SECRET } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (secret !== null) headers.authorization = `Bearer ${secret}`;
  const req = new Request('https://jobs.test/api/wakes/nudge', {
    method: 'POST', headers, body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const rows = (fx) => fx.db.prepare(
  'SELECT repo, kind, key, typeof(key) kt, event, minute FROM wakes ORDER BY id ASC').all()
  .map((r) => ({ ...r }));
const inserts = (fx) => fx.calls.filter((s) => /^INSERT/i.test(s));

const OK = { repo: 'example-org/x', key: 12, reason: 'untriaged', dedupe: 'untriaged:12' };

test('nudge: inserts one kind=issue row with a TEXT key, event nudge:<reason>, minute nudge:<dedupe>', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await nudge(fx, OK);
  assert.equal(r.status, 200);
  assert.equal(r.body.inserted, 1);
  assert.deepEqual(rows(fx), [{
    repo: 'example-org/x', kind: 'issue', key: '12', kt: 'text',
    event: 'nudge:untriaged', minute: 'nudge:untriaged:12',
  }]);
});

test('nudge: a replay of the same body inserts nothing and answers inserted 0', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  assert.equal((await nudge(fx, OK)).body.inserted, 1);
  const again = await nudge(fx, OK);
  assert.equal(again.status, 200);
  assert.equal(again.body.inserted, 0);
  assert.equal(rows(fx).length, 1);
});

test('nudge: unblocked:12:7 then unblocked:12:9 are two rows', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const a = await nudge(fx, { ...OK, reason: 'unblocked', dedupe: 'unblocked:12:7' });
  const b = await nudge(fx, { ...OK, reason: 'unblocked', dedupe: 'unblocked:12:9' });
  assert.equal(a.body.inserted, 1);
  assert.equal(b.body.inserted, 1);
  const got = rows(fx);
  assert.equal(got.length, 2);
  assert.deepEqual(got.map((r) => r.event), ['nudge:unblocked', 'nudge:unblocked']);
  assert.deepEqual(got.map((r) => r.minute), ['nudge:unblocked:12:7', 'nudge:unblocked:12:9']);
});

test('nudge: a webhook row for the same key and a nudge never block each other', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  // The way routes/webhooks.js writes it: key is wakeOf's decimal string.
  fx.db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)')
    .run('example-org/x', 'issue', '12', 'issues.opened', '2026-09-26T10:00:00Z', '2026-09-26T10:00:05Z');
  assert.equal((await nudge(fx, OK)).body.inserted, 1);
  const hook = fx.db.prepare(
    `INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)
     ON CONFLICT(repo, kind, key, minute) DO NOTHING`)
    .run('example-org/x', 'issue', '12', 'issues.edited', '2026-09-26T10:05:00Z', '2026-09-26T10:05:01Z');
  assert.equal(hook.changes, 1);
  assert.equal(rows(fx).length, 3);
  // …and the nudge row shares the webhook's key space: a numeric bind would
  // store INTEGER 12, which never compares equal to '12'.
  const same = fx.db.prepare("SELECT COUNT(*) n FROM wakes WHERE key = '12'").get();
  assert.equal(same.n, 3);
});

const BAD = [
  ['key as a string', { ...OK, key: '12' }],
  ['key fractional', { ...OK, key: 1.5 }],
  ['key negative', { ...OK, key: -1 }],
  ['key zero', { ...OK, key: 0 }],
  ['key missing', { repo: OK.repo, reason: OK.reason, dedupe: OK.dedupe }],
  ['key past 1e9', { ...OK, key: 1e9 + 1 }],
  ['reason other', { ...OK, reason: 'other' }],
  ['dedupe uppercase', { ...OK, dedupe: 'UNTRIAGED:1' }],
  ['dedupe 65 chars', { ...OK, dedupe: 'a'.repeat(65) }],
  ['dedupe with a space', { ...OK, dedupe: 'a b' }],
  ['dedupe empty', { ...OK, dedupe: '' }],
  ['repo not a slug', { ...OK, repo: 'nope' }],
  ['repo not a string', { ...OK, repo: ['example-org/x'] }],
  ['body is JSON null', null],
];

for (const [name, body] of BAD) {
  test(`nudge: ${name} is a 400 and runs no INSERT`, async (t) => {
    const fx = await fixture(t);
    if (!fx) return;
    const r = await nudge(fx, body);
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.deepEqual(inserts(fx), []);
    assert.equal(rows(fx).length, 0);
  });
}

test('nudge: a 64-char dedupe is accepted (the bound is inclusive)', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await nudge(fx, { ...OK, dedupe: 'a'.repeat(64) });
  assert.equal(r.status, 200);
  assert.equal(r.body.inserted, 1);
});

test('nudge: no Authorization header is a 401 and writes nothing', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await nudge(fx, OK, { secret: null });
  assert.equal(r.status, 401);
  assert.deepEqual(inserts(fx), []);
});
