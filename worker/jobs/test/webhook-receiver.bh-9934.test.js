// BH-9934 (BH-9926.2): the GitHub receiver's coverage and hardening.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema. Each case opens its own DB, uses its own repo o/bh9934-<case> and
// its own delivery ids.
//   A1  20 identical deliveries at once: 1 delivery row, 1 wake, 1 record write
//   A2  body cap before the HMAC (413, nothing written); A2b-A2e the edges and the row
//   A3  labeled `dequeued`: the record labels and 1 pr wake pull_request.labeled.dequeued
//   A4  the same delivery from a fleet App: the record, 0 wakes, 202 self-app
//   A5  a throw after the signature: 1 github:dead row and 200; A5b no delivery id; A5c 500;
//       A5d record statements not built: a warn, the wake still goes
//   L1-L3 wakeOf label wakes
//   S1-S12 selfAppOf decision table
//   K1-K2 the seed rows and the added columns
//   D1-D3 GET /api/webhook-dead-letters
//   X1-X3 EXPLAIN QUERY PLAN at seeded volume
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { wakeOf, ensureColumns } from '../src/lib/core.js';
import { settingsRows } from '../src/lib/settings-cache.js';
import {
  WEBHOOK_MAX_BODY_BYTES, SELF_ECHO_ACTIONS, bodyCapOf, readCappedBody, selfAppOf, CLAIM_GUARD_SQL,
} from '../src/lib/webhook-receiver.js';
import { upsertSql } from '../src/routes/pr-records.js';
import { checkMergeSql } from '../src/lib/pr-record-intake.js';
import { DEAD_COUNT_SQL, DEAD_NEWEST_SQL } from '../src/routes/webhook-dead-letters.js';

const SECRET = 'tok-fixture-bh9934';
const GH = 'gh-fixture-secret-bh9934';
const NOW_MS = Date.parse('2026-11-24T06:00:00Z');
const T = '2026-11-24T06:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), B = 'b'.repeat(40);
const SELF_APPS = 'cromford cromford-builders app/cromford-board';

async function fresh(t, extraEnv = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { ...o, env: { DB: o.DB, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: GH, ...extraEnv } };
}
const n = (db, sql, ...b) => db.prepare(sql).get(...b).n;
const sign = (body) => 'sha256=' + createHmac('sha256', GH).update(body).digest('hex');
let dn = 0;
const did = () => `dlv-9934-${++dn}`;
async function hook(env, event, payload, { delivery = did(), body: rawBody, headers: extra = {} } = {}) {
  const body = rawBody ?? JSON.stringify(payload);
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-hub-signature-256': sign(body), ...extra };
  if (delivery) headers['x-github-delivery'] = delivery;
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
async function api(env, path, { auth = true } = {}) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: auth ? { authorization: `Bearer ${SECRET}` } : {},
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const repository = (repo) => ({ full_name: repo, default_branch: 'main' });
const prPayload = (repo, action, num, o = {}) => ({
  action, number: num, repository: repository(repo),
  pull_request: {
    number: num, state: 'open', draft: false, merged_at: null, updated_at: ago(60),
    head: { ref: 'ticket/x', sha: A }, base: { ref: 'main', sha: B }, labels: [{ name: 'ai-build' }], ...o,
  },
});
const labeled = (repo, num, name, sender) => ({
  ...prPayload(repo, 'labeled', num, { labels: [{ name: 'ai-build' }, { name }] }),
  label: { name }, ...(sender ? { sender } : {}),
});
const labelsOf = (db, repo, num) => {
  const r = db.prepare('SELECT labels FROM pr_records WHERE repo = ? AND number = ?').get(repo, num);
  return r ? JSON.parse(r.labels) : null;
};

// A DB wrapper that counts the pr_records statements a batch changed rows with.
function counting(DB) {
  const hits = [];
  return {
    hits,
    DB: {
      prepare(sql) {
        const s = DB.prepare(sql);
        // Writes to pr_records only (an INSERT or UPDATE), never the DDL ensureTable runs.
        if (!/^\s*(INSERT|UPDATE)\b/.test(sql) || !/^\s*(INSERT INTO|UPDATE) pr_records\b/.test(sql)) return s;
        const run = s._run.bind(s);
        s._run = () => { const r = run(); if (r.meta.changes > 0) hits.push(sql); return r; };
        return s;
      },
      batch: (stmts) => DB.batch(stmts),
    },
  };
}

// ── A1 ────────────────────────────────────────────────────────────────────────
test('A1 20 identical deliveries at the same time: 1 delivery row, 1 wake row, 1 record write', async (t) => {
  const o = await fresh(t); if (!o) return;
  const c = counting(o.DB);
  const env = { ...o.env, DB: c.DB };
  const repo = 'o/bh9934-a1';
  const payload = prPayload(repo, 'synchronize', 11);
  const id = did();
  const res = await Promise.all(Array.from({ length: 20 }, () => hook(env, 'pull_request', payload, { delivery: id })));
  for (const r of res) assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(n(o.db, "SELECT COUNT(*) AS n FROM webhook_deliveries WHERE delivery_id = ?", id), 1);
  assert.equal(n(o.db, "SELECT COUNT(*) AS n FROM wakes WHERE repo = ?", repo), 1);
  assert.equal(c.hits.length, 1, `exactly one record write changed rows: ${c.hits.length}`);
  assert.equal(res.filter((r) => r.body.duplicate === true).length, 19);
  assert.equal(n(o.db, "SELECT COUNT(*) AS n FROM pr_records WHERE repo = ?", repo), 1);
});

// ── A1b ───────────────────────────────────────────────────────────────────────
// The BH-9935 field statements (status, mergify, head-push) take the same
// delivery claim guard as every other record statement of the wake batch.
test('A1b the status, mergify and head-push record statements change rows only under the delivery claim', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { fieldStmtOf } = await import('../src/lib/pr-record-fields.js');
  const { CLAIM_GUARD_SQL } = await import('../src/lib/webhook-receiver.js');
  const repo = 'o/bh9934-a1b';
  const id = did();
  const first = await hook(o.env, 'pull_request', prPayload(repo, 'synchronize', 12), { delivery: id });
  assert.equal(first.status, 200, JSON.stringify(first.body));
  const claim = o.db.prepare("SELECT claim FROM webhook_deliveries WHERE vendor = 'github' AND delivery_id = ?").get(id).claim;
  assert.ok(claim, 'the delivery row holds its claim');
  const at = ago(1);
  const writes = [
    { kind: 'status', repo, sha: A, name: 'ci/x', value: { state: 'success', at }, at },
    { kind: 'mergify', repo, number: 12, value: { state: 'queued', at, comment_id: 5 }, at, id: 5 },
    { kind: 'head-push', repo, head_ref: 'ticket/x', value: { sha: A, at }, at },
  ];
  const changed = async (w, binds) => (await fieldStmtOf(o.DB, w, 50, { sql: CLAIM_GUARD_SQL, binds }).run()).meta.changes;
  for (const w of writes) {
    assert.equal(await changed(w, [id, 'not-the-claim']), 0, `${w.kind}: a delivery that lost the claim writes nothing`);
    assert.equal(await changed(w, [did(), claim]), 0, `${w.kind}: an unknown delivery writes nothing`);
  }
  // A mergify write for a PR with no record must not insert a row either.
  assert.equal(await changed({ ...writes[1], number: 99 }, [id, 'not-the-claim']), 0);
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM pr_records WHERE repo = ?', repo), 1);
  for (const w of writes) assert.equal(await changed(w, [id, claim]), 1, `${w.kind}: the delivery that holds the claim writes`);
  // No guard: the statement is the unguarded BH-9935 form.
  assert.equal((await fieldStmtOf(o.DB, { ...writes[1], number: 98 }, 50).run()).meta.changes, 1);
});

// ── A2 ────────────────────────────────────────────────────────────────────────
const allCounts = (db) => ['wakes', 'webhook_deliveries', 'pr_records', 'pr_state_events']
  .map((tb) => [tb, n(db, `SELECT COUNT(*) AS n FROM ${tb}`)]);
const padded = (repo, size) => {
  const base = JSON.stringify({ ...prPayload(repo, 'synchronize', 2), pad: '' });
  return base.replace('"pad":""', `"pad":"${'x'.repeat(size - base.length)}"`);
};

test('A2 a body of cap+1 bytes is 413 and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const body = padded('o/bh9934-a2', WEBHOOK_MAX_BODY_BYTES + 1);
  assert.equal(body.length, WEBHOOK_MAX_BODY_BYTES + 1);
  const before = allCounts(o.db);
  const r = await hook(o.env, 'pull_request', null, { body });
  assert.equal(r.status, 413, JSON.stringify(r.body));
  assert.equal(r.body.cap, WEBHOOK_MAX_BODY_BYTES);
  assert.deepEqual(allCounts(o.db), before);
  assert.ok(before.every(([, c]) => c === 0), JSON.stringify(before));
});

test('A2b a body of exactly the cap is not 413', async (t) => {
  const o = await fresh(t); if (!o) return;
  const body = padded('o/bh9934-a2b', WEBHOOK_MAX_BODY_BYTES);
  const r = await hook(o.env, 'pull_request', null, { body });
  assert.equal(r.status, 200, JSON.stringify(r.body));
});

test('A2c a Content-Length smaller than a cap+1 body is still 413 (the stream is counted)', async () => {
  const big = new TextEncoder().encode('y'.repeat(2049));
  let pulled = 0;
  const stream = new ReadableStream({
    pull(ctl) { if (pulled >= big.length) { ctl.close(); return; } ctl.enqueue(big.slice(pulled, pulled + 512)); pulled += 512; },
  });
  const req = { headers: new Headers({ 'content-length': '10' }), body: stream };
  const r = await readCappedBody(req, 2048);
  assert.equal(r.tooLarge, true);
  assert.ok(pulled < big.length + 512, 'the read stopped at the cap');
  // a header over the cap: no read at all
  let read = false;
  const s2 = new ReadableStream({ pull() { read = true; } }, { highWaterMark: 0 });
  assert.deepEqual(await readCappedBody({ headers: new Headers({ 'content-length': '2049' }), body: s2 }, 2048), { tooLarge: true });
  assert.equal(read, false);
  // a streamed body with no Content-Length, through the route
  const o = await openDb(); if (!o) return;
  const env = { DB: o.DB, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: GH };
  const body = 'z'.repeat(WEBHOOK_MAX_BODY_BYTES + 1);
  const enc = new TextEncoder().encode(body);
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', {
    method: 'POST', duplex: 'half',
    headers: { 'x-github-event': 'pull_request', 'x-hub-signature-256': sign(body) },
    body: new ReadableStream({ start(ctl) { ctl.enqueue(enc); ctl.close(); } }),
  }), env);
  assert.equal(res.status, 413);
});

test('A2d the row webhook.github.max_body_bytes=1024 in the snapshot: a 1,025-byte body is 413', async (t) => {
  const o = await fresh(t, { SETTINGS_CACHE_TTL_S: '30' }); if (!o) return;
  o.db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('webhook.github.max_body_bytes','1024','t','t',?)").run(T);
  await settingsRows(o.env);
  assert.equal(bodyCapOf(o.env), 1024);
  const r = await hook(o.env, 'pull_request', null, { body: padded('o/bh9934-a2d', 1025) });
  assert.equal(r.status, 413);
  assert.equal(r.body.cap, 1024);
  const ok = await hook(o.env, 'pull_request', null, { body: padded('o/bh9934-a2d', 1024) });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
});

test('A2e a row that is not a whole number in 1024..26214400 is ignored: the fallback cap applies', async (t) => {
  for (const v of ['abc', '0', '26214401', '1023', '2e6']) {
    const o = await fresh(t, { SETTINGS_CACHE_TTL_S: '30' }); if (!o) return;
    o.db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('webhook.github.max_body_bytes',?,'t','t',?)").run(v, T);
    await settingsRows(o.env);
    assert.equal(bodyCapOf(o.env), WEBHOOK_MAX_BODY_BYTES, `row ${v}`);
    t.mock.timers.reset();
  }
});

// ── A3 / A4 ──────────────────────────────────────────────────────────────────
test('A3 labeled dequeued: the record labels hold dequeued and 1 pr wake pull_request.labeled.dequeued', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9934-a3';
  const r = await hook(o.env, 'pull_request', labeled(repo, 31, 'dequeued'));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(labelsOf(o.db, repo, 31).includes('dequeued'));
  const w = o.db.prepare('SELECT kind, key, event FROM wakes WHERE repo = ?').all(repo);
  assert.deepEqual(w.map((x) => ({ ...x })), [{ kind: 'pr', key: '31', event: 'pull_request.labeled.dequeued' }]);
});

test('A4 the A3 delivery from a fleet App: the record labels update, 0 wakes, 202 self-app', async (t) => {
  const o = await fresh(t, { HARNESS_SELF_APPS: 'cromford cromford-builders' }); if (!o) return;
  const repo = 'o/bh9934-a4';
  const r = await hook(o.env, 'pull_request', labeled(repo, 41, 'dequeued', { login: 'cromford[bot]', type: 'Bot' }));
  assert.equal(r.status, 202, JSON.stringify(r.body));
  assert.equal(r.body.ignored, 'self-app');
  assert.equal(r.body.app, 'cromford');
  assert.ok(labelsOf(o.db, repo, 41).includes('dequeued'));
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM wakes WHERE repo = ?', repo), 0);
  // control: the same delivery from a person wakes
  const p = await hook(o.env, 'pull_request', labeled(repo, 42, 'dequeued', { login: 'cromford', type: 'User' }));
  assert.equal(p.status, 200);
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM wakes WHERE repo = ?', repo), 1);
});

// ── A5 ────────────────────────────────────────────────────────────────────────
function faulty(DB, re) {
  const state = { on: true };
  return {
    state,
    DB: {
      // A statement run on its own (the no-delivery-id wake) faults too.
      prepare: (sql) => {
        const st = DB.prepare(sql);
        if (!re.test(sql)) return st;
        const run = st.run.bind(st);
        st.run = async () => { if (state.on) throw new Error('D1_ERROR: fixture fault bh9934'); return run(); };
        return st;
      },
      batch: async (stmts) => {
        if (state.on && stmts.some((s) => re.test(s._sql || ''))) throw new Error('D1_ERROR: fixture fault bh9934');
        return DB.batch(stmts);
      },
    },
  };
}

test('A5 a batch that throws after the signature: 200 dead_letter, 1 github:dead row, 0 wakes; a redelivery wakes', async (t) => {
  const o = await fresh(t); if (!o) return;
  const f = faulty(o.DB, /INSERT INTO wakes/);
  const env = { ...o.env, DB: f.DB };
  t.mock.method(console, 'warn', () => {});
  const repo = 'o/bh9934-a5';
  const id = did();
  const r = await hook(env, 'pull_request', prPayload(repo, 'opened', 51), { delivery: id });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.dead_letter, true);
  assert.equal(r.body.delivery_id, id);
  const dead = o.db.prepare("SELECT delivery_id, event, error FROM webhook_deliveries WHERE vendor = 'github:dead'").all();
  assert.equal(dead.length, 1);
  assert.equal(dead[0].delivery_id, id);
  assert.equal(dead[0].event, 'pull_request');
  assert.match(dead[0].error, /fixture fault bh9934/);
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM wakes'), 0);
  assert.equal(n(o.db, "SELECT COUNT(*) AS n FROM webhook_deliveries WHERE vendor = 'github'"), 0);
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM pr_records WHERE repo = ?', repo), 0, 'the record rode the failed batch');
  f.state.on = false;
  const again = await hook(env, 'pull_request', prPayload(repo, 'opened', 51), { delivery: id });
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.duplicate, false);
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM wakes WHERE repo = ?', repo), 1);
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM pr_records WHERE repo = ?', repo), 1);
});

test('A5b no delivery header: the dead row id starts none:', async (t) => {
  const o = await fresh(t); if (!o) return;
  const f = faulty(o.DB, /INSERT INTO wakes/);
  t.mock.method(console, 'warn', () => {});
  const r = await hook({ ...o.env, DB: f.DB }, 'pull_request', prPayload('o/bh9934-a5b', 'opened', 52), { delivery: null });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.match(r.body.delivery_id, /^none:[0-9a-f-]{36}$/);
  assert.equal(n(o.db, "SELECT COUNT(*) AS n FROM webhook_deliveries WHERE vendor = 'github:dead' AND delivery_id LIKE 'none:%'"), 1);
});

test('A5c the dead-letter write throws too: 500, nothing committed', async (t) => {
  const o = await fresh(t); if (!o) return;
  t.mock.method(console, 'warn', () => {});
  const DB = {
    prepare: (sql) => {
      if (/INSERT INTO webhook_deliveries \(vendor, delivery_id, at, error, event\)/.test(sql)) throw new Error('D1_ERROR: dead-letter fault');
      return o.DB.prepare(sql);
    },
    batch: async (stmts) => {
      if (stmts.some((s) => /INSERT INTO wakes/.test(s._sql || ''))) throw new Error('D1_ERROR: fixture fault');
      return o.DB.batch(stmts);
    },
  };
  const r = await hook({ ...o.env, DB }, 'pull_request', prPayload('o/bh9934-a5c', 'opened', 53));
  assert.equal(r.status, 500, JSON.stringify(r.body));
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM webhook_deliveries'), 0);
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM wakes'), 0);
});

test('A5d the record statements cannot be built: one warn, the wake still goes, no dead letter', async (t) => {
  const o = await fresh(t); if (!o) return;
  const warns = [];
  t.mock.method(console, 'warn', (...a) => warns.push(a.join(' ')));
  // ensureTable(pr_records) fails; every other statement runs.
  const DB = {
    prepare: (sql) => o.DB.prepare(sql),
    batch: async (stmts) => {
      if (stmts.some((s) => /CREATE TABLE IF NOT EXISTS pr_records/.test(s._sql || ''))) throw new Error('D1_ERROR: ddl fault');
      return o.DB.batch(stmts);
    },
  };
  const repo = 'o/bh9934-a5d';
  const r = await hook({ ...o.env, DB }, 'pull_request', prPayload(repo, 'opened', 54));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.dead_letter, undefined);
  assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM wakes WHERE repo = ?', repo), 1);
  assert.equal(n(o.db, "SELECT COUNT(*) AS n FROM webhook_deliveries WHERE vendor = 'github:dead'"), 0);
  assert.equal(warns.filter((w) => w.includes('[pr-record-intake] webhook record statements not built')).length, 1, warns.join('\n'));
});

// ── L1-L3 ─────────────────────────────────────────────────────────────────────
test('L1 labeled/unlabeled x merge-queue, dequeued, merge-queue-paused: a pr wake pull_request.<action>.<label>', () => {
  for (const action of ['labeled', 'unlabeled']) {
    for (const name of ['merge-queue', 'dequeued', 'merge-queue-paused']) {
      assert.deepEqual(wakeOf('pull_request', { action, number: 7, label: { name } }),
        { kind: 'pr', key: '7', event: `pull_request.${action}.${name}` }, `${action} ${name}`);
    }
  }
});
test('L2 labeled queued stays exactly as today: no event key', () => {
  assert.deepEqual(wakeOf('pull_request', { action: 'labeled', number: 7, label: { name: 'queued' } }), { kind: 'pr', key: '7' });
});
test('L3 no wake: unlabeled queued, Dequeued, merge-queue-x, checking, no label, a label with no name', () => {
  const cases = [['unlabeled', { name: 'queued' }], ['labeled', { name: 'Dequeued' }], ['labeled', { name: 'merge-queue-x' }],
    ['unlabeled', { name: 'checking' }], ['labeled', undefined], ['unlabeled', undefined], ['labeled', {}]];
  for (const [action, label] of cases) {
    const p = { action, number: 7, ...(label !== undefined ? { label } : {}) };
    assert.equal(wakeOf('pull_request', p), null, JSON.stringify(p));
  }
});

// ── S1-S12 ────────────────────────────────────────────────────────────────────
const knobs = { selfEchoActions: SELF_ECHO_ACTIONS };
const S = (event, action, sender, env = { HARNESS_SELF_APPS: SELF_APPS }, k = knobs) =>
  selfAppOf(env, event, { action, ...(sender !== undefined ? { sender } : {}) }, k);
const bot = (login) => ({ login, type: 'Bot' });
test('S1-S3 a fleet App on an echo action is filtered (case, list spelling)', () => {
  assert.equal(S('pull_request', 'labeled', bot('cromford[bot]')), 'cromford');                 // S1
  assert.equal(S('issue_comment', 'created', bot('Cromford-Builders[bot]')), 'cromford-builders'); // S2
  assert.equal(S('pull_request', 'unlabeled', bot('cromford-board[bot]')), 'cromford-board');   // S3 app/ entry
});
test('S4-S12 never filtered: a person, another bot, a near miss, a handoff action, other events, no sender, no list, row ""', () => {
  assert.equal(S('pull_request', 'labeled', { login: 'cromford', type: 'User' }), '');               // S4
  assert.equal(S('pull_request', 'labeled', bot('mergify[bot]')), '');                                    // S5
  assert.equal(S('pull_request', 'labeled', bot('cromford-evil[bot]')), '');                         // S6
  for (const a of ['opened', 'synchronize', 'closed', 'reopened', 'ready_for_review']) {
    assert.equal(S('pull_request', a, bot('cromford-builders[bot]')), '', a);                         // S7
  }
  for (const [e, a] of [['status', ''], ['check_run', 'completed'], ['check_suite', 'completed'], ['workflow_run', 'completed'],
    ['pull_request_review', 'submitted'], ['push', '']]) {
    assert.equal(S(e, a, bot('cromford[bot]')), '', e);                                              // S8
  }
  assert.equal(S('pull_request', 'labeled', undefined), '');                                              // S9
  assert.equal(S('pull_request', 'labeled', bot('cromford[bot]'), {}), '');                          // S10
  assert.equal(S('pull_request', 'labeled', bot('cromford[bot]'), { HARNESS_SELF_APPS: '' }), '');   // S11
  assert.equal(S('pull_request', 'labeled', bot('cromford[bot]'), undefined, { selfEchoActions: [] }), ''); // S12
});

// ── K1 / K2 ───────────────────────────────────────────────────────────────────
test('K1 the composed schema seeds the two receiver rows with the documented values', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.match(jobsSchemaSql(), /webhook\.github\.max_body_bytes/);
  const v = (k) => o.db.prepare('SELECT value FROM settings WHERE key = ?').get(k)?.value;
  assert.equal(v('webhook.github.max_body_bytes'), String(WEBHOOK_MAX_BODY_BYTES));
  assert.equal(v('webhook.github.self_echo_actions'), SELF_ECHO_ACTIONS.join(' '));
});
test('K2 ensureColumns(webhook_deliveries) adds claim, error, event', async (t) => {
  const o = await fresh(t); if (!o) return;
  await ensureColumns(o.env, 'webhook_deliveries');
  const cols = o.db.prepare('PRAGMA table_info(webhook_deliveries)').all().map((r) => r.name);
  for (const c of ['claim', 'error', 'event']) assert.ok(cols.includes(c), `${c} in ${cols}`);
});

// ── D1-D3 ─────────────────────────────────────────────────────────────────────
test('D1 two dead rows: count 2 and the newest row', async (t) => {
  const o = await fresh(t); if (!o) return;
  await ensureColumns(o.env, 'webhook_deliveries');
  const ins = o.db.prepare("INSERT INTO webhook_deliveries (vendor, delivery_id, at, error, event) VALUES (?,?,?,?,?)");
  ins.run('github:dead', 'old-1', ago(600), 'old error', 'push');
  ins.run('github:dead', 'new-2', ago(60), 'new error', 'pull_request');
  ins.run('github', 'live-3', ago(30), null, null);
  const r = await api(o.env, '/api/webhook-dead-letters?vendor=github');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.vendor, 'github');
  assert.equal(r.body.count, 2);
  assert.equal(r.body.newest_at, ago(60));
  assert.deepEqual(r.body.newest, { delivery_id: 'new-2', event: 'pull_request', error: 'new error' });
});
test('D2 no dead rows: count 0, newest null (also before the columns exist)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await api(o.env, '/api/webhook-dead-letters?vendor=github');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.count, 0);
  assert.equal(r.body.newest, null);
});
test('D3 no bearer is 401; a bad vendor is 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await api(o.env, '/api/webhook-dead-letters?vendor=github', { auth: false })).status, 401);
  assert.equal((await api(o.env, '/api/webhook-dead-letters?vendor=GITHUB!')).status, 400);
  assert.equal((await api(o.env, '/api/webhook-dead-letters')).status, 400);
});
test('D4 a dead letter the route wrote reads back through the route', async (t) => {
  const o = await fresh(t); if (!o) return;
  const f = faulty(o.DB, /INSERT INTO wakes/);
  t.mock.method(console, 'warn', () => {});
  await hook({ ...o.env, DB: f.DB }, 'push', { ref: 'refs/heads/main', before: A, after: B, repository: repository('o/bh9934-d4') }, { delivery: 'dlv-d4' });
  const r = await api(o.env, '/api/webhook-dead-letters?vendor=github');
  assert.equal(r.body.count, 1);
  assert.equal(r.body.newest.delivery_id, 'dlv-d4');
  assert.equal(r.body.newest.event, 'push');
});

// ── X1-X3 ─────────────────────────────────────────────────────────────────────
async function seededDeliveries(t) {
  const o = await fresh(t); if (!o) return null;
  await ensureColumns(o.env, 'webhook_deliveries');
  o.db.exec('BEGIN');
  const ins = o.db.prepare('INSERT INTO webhook_deliveries (vendor, delivery_id, at, claim, error, event) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 20000; i++) {
    const dead = i % 400 === 0;
    ins.run(dead ? 'github:dead' : (i % 3 ? 'github' : 'jira'), `d-${i}`, ago(i * 30), dead ? null : `c-${i}`, dead ? 'e' : null, dead ? 'push' : null);
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  assert.equal(n(o.db, "SELECT COUNT(*) AS n FROM webhook_deliveries WHERE vendor = 'github:dead'"), 50);
  return o;
}
test('X1 the claim guard uses the webhook_deliveries primary key on 20,000 rows', async (t) => {
  const o = await seededDeliveries(t); if (!o) return;
  const p = plan(o.db, `SELECT ${CLAIM_GUARD_SQL(1)}`, 'd-7', 'c-7');
  assert.deepEqual(fullScans(p, ['webhook_deliveries']), [], p.join(' | '));
  assert.ok(p.some((l) => /sqlite_autoindex_webhook_deliveries_1|PRIMARY KEY/.test(l)), p.join(' | '));
});
test('X2 the dead-letter count and newest lookup on 20,000 rows (50 dead): no SCAN', async (t) => {
  const o = await seededDeliveries(t); if (!o) return;
  for (const [sql, b] of [[DEAD_COUNT_SQL, ['github:dead']], [DEAD_NEWEST_SQL, ['github:dead', ago(0)]]]) {
    const p = plan(o.db, sql, ...b);
    assert.deepEqual(fullScans(p, ['webhook_deliveries']), [], `${sql}: ${p.join(' | ')}`);
    assert.ok(p.some((l) => /USING/.test(l)), p.join(' | '));
  }
});
test('X3 the guarded upsert and the guarded check merge use ux_pr_records_repo_number on 5,000 rows', async (t) => {
  const o = await seededDeliveries(t); if (!o) return;
  o.db.exec('BEGIN');
  const ins = o.db.prepare('INSERT INTO pr_records (repo, number, state, fields_at, created_at, refreshed_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 5000; i++) ins.run(`o/repo-${i % 40}`, i + 1, 'open', '{}', ago(i), ago(i));
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  const v = JSON.stringify({ status: 'completed', conclusion: 'success', sha: A, at: T });
  for (const [sql, binds] of [
    [upsertSql(['state', 'labels'], { refresh: false, guardAt: 7 }), ['o/repo-7', 4008, T, 'webhook', 'open', '[]', 'd-7', 'c-7']],
    [checkMergeSql({ guardAt: 7 }), ['o/repo-7', 4008, 'test', v, T, '$."test"', 'd-7', 'c-7']],
  ]) {
    const p = plan(o.db, sql, ...binds);
    assert.deepEqual(fullScans(p, ['pr_records', 'webhook_deliveries']), [], p.join(' | '));
    const before = n(o.db, 'SELECT COUNT(*) AS n FROM pr_records');
    o.db.prepare(sql).run(...binds);
    assert.equal(n(o.db, 'SELECT COUNT(*) AS n FROM pr_records'), before, 'the upsert hit the existing (repo, number) row');
    // a claim that does not match changes nothing
    const r = o.db.prepare(sql).run(...binds.slice(0, -1), 'c-other');
    assert.equal(Number(r.changes), 0, sql);
  }
});
