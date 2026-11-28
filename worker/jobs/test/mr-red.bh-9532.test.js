// BH-9532 (C0, #9539): Mr Red's audit table and its route family, driven
// through the REAL worker.fetch against the composed jobs schema (the
// node:sqlite D1 shim).
//
//   seeds      every staff.mr-red.* settings row the tracer seeds, by value
//   roster     GET /api/staff/agents (the read behind /staff) lists mr-red,
//              active, with its lane staff-mr-red; GET /api/staff/agent too
//   add-only   the schema fragment has no DROP, ALTER or DELETE
//   post-replay     the same payload twice: one row, 200 existing:true
//   post-conflict   the same key with another repo or dry_run: 409 key_mismatch
//   post-validation bad lever, fingerprint, repo, state, dry_run, evidence: 400
//   patch-unverified  state=cleared with a verification time missing: 400
//   patch-verified    cleared with both times (body, or row + body): 200
//   patch-404         an unknown key: 404
//   get-paging   250 rows, limit 100: 3 pages, no duplicate, no gap; limit=500 -> 100
//   get-filters  repo, lever, state, fingerprint, target
//   get-wrong-repo  0 rows for another repo
//   explain      50k rows: list, repo, fingerprint+target, state and the
//                action_key lookup each use their index, never a bare SCAN
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const REPO = 'example-org/cromford';
const call = (DB, path, { method = 'POST', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const fp = (s) => createHash('sha256').update(s).digest('hex');
const keyOf = (lever, target, f, approach = 'none') => fp(`${lever}|${target}|${f}|${approach}`);
const post = (DB, over = {}) => call(DB, '/api/mr-red/actions', {
  body: {
    lever: 'observe', target: '#7001', fingerprint: fp('fixture-7001'), repo: REPO, project: 'cromford',
    target_kind: 'pr', state: 'observed', dry_run: 0, red_check: 'harness-ci', evidence_json: { head: 'a'.repeat(40) },
    ...over,
  },
});
const patch = (DB, key, body) => call(DB, `/api/mr-red/actions/${key}`, { method: 'PATCH', body });
const get = (DB, q = '') => call(DB, `/api/mr-red/actions${q}`, { method: 'GET' });
const FRAG = new URL('../schema.d/202611111407-bh-9532-mr-red.sql', import.meta.url);

test('BH-9532 Mr Red routes and schema', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('seeds: every staff.mr-red row and its value', async () => {
    const { db } = await openDb();
    const want = {
      'staff.mr-red.level': 'act', 'staff.mr-red.metric': 'red_minutes', 'staff.mr-red.target': '0',
      'staff.mr-red.authority.merge': 'off', 'staff.mr-red.authority.prod_apply': 'off',
      'staff.mr-red.authority.force_push': 'off', 'staff.mr-red.authority.secrets': 'off',
      'staff.mr-red.max_items_tick': '50', 'staff.mr-red.lookback_h': '24', 'staff.mr-red.tick_timeout_s': '240',
      'staff.mr-red.loop_same_fix_max': '3', 'staff.mr-red.migration_gate_checks': 'migration-gate',
    };
    for (const [k, v] of Object.entries(want)) {
      const row = db.prepare('SELECT value, note FROM settings WHERE key=?').get(k);
      assert.ok(row, `${k} not seeded`);
      assert.equal(row.value, v, k);
      assert.ok(row.note && row.note.length > 10, `${k} has no note`);
    }
  });

  await t.test('roster: /staff lists mr-red, active, with its lane', async () => {
    const { DB } = await openDb();
    const r = await call(DB, '/api/staff/agents', { method: 'GET' });
    assert.equal(r.status, 200);
    const a = r.body.agents.find((x) => x.name === 'mr-red');
    assert.ok(a, `mr-red not on the roster: ${JSON.stringify(r.body.invalid)}`);
    assert.equal(a.status, 'active');
    assert.ok(JSON.stringify(a).includes('staff-mr-red'), JSON.stringify(a));
    const one = await call(DB, '/api/staff/agent?name=mr-red', { method: 'GET' });
    assert.equal(one.status, 200);
    assert.equal(one.body.agent.status, 'active');
  });

  await t.test('add-only: the fragment drops, alters and deletes nothing', () => {
    const sql = readFileSync(FRAG, 'utf8').split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');
    assert.ok(/CREATE TABLE IF NOT EXISTS mr_red_actions/.test(sql));
    assert.equal(/\b(DROP|ALTER|DELETE)\b/i.test(sql), false);
    assert.equal(readdirSync(new URL('../src/routes/retention.d/', import.meta.url)).some((f) => f.includes('mr-red')), false,
      'retention is BH-9532.4 (#9543), not this slice');
  });

  await t.test('post-replay: the same payload twice is one row', async () => {
    const { DB, db } = await openDb();
    const r1 = await post(DB);
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    assert.equal(r1.body.existing, false);
    assert.equal(r1.body.action.action_key, keyOf('observe', '#7001', fp('fixture-7001')));
    assert.equal(r1.body.action.state, 'observed');
    assert.deepEqual(r1.body.action.evidence, { head: 'a'.repeat(40) });
    const r2 = await post(DB, { evidence_json: { head: 'a'.repeat(40), seen_count: 2 } });
    assert.equal(r2.status, 200);
    assert.equal(r2.body.existing, true);
    assert.equal(r2.body.action.id, r1.body.action.id);
    assert.equal(db.prepare('SELECT count(*) AS n FROM mr_red_actions').get().n, 1);
  });

  await t.test('post-conflict: the same key with another repo or dry_run is 409', async () => {
    const { DB, db } = await openDb();
    assert.equal((await post(DB)).status, 200);
    const a = await post(DB, { repo: 'example-org/other' });
    assert.equal(a.status, 409);
    assert.equal(a.body.error, 'key_mismatch');
    const b = await post(DB, { dry_run: 1 });
    assert.equal(b.status, 409);
    assert.equal(db.prepare('SELECT count(*) AS n FROM mr_red_actions').get().n, 1);
    // another approach is another key, so another row
    const c = await post(DB, { approach: 'rerun' });
    assert.equal(c.status, 200);
    assert.equal(c.body.existing, false);
  });

  await t.test('post-validation: each bad field is a 400 that names it', async () => {
    const { DB, db } = await openDb();
    for (const [over, field] of [
      [{ lever: 'Bad Lever' }, 'lever'], [{ lever: undefined }, 'lever'],
      [{ fingerprint: 'abc' }, 'fingerprint'], [{ fingerprint: 'A'.repeat(64) }, 'fingerprint'],
      [{ repo: 'no-slash' }, 'repo'], [{ repo: 'a/b/c' }, 'repo'],
      [{ target: '' }, 'target'], [{ target: 'x'.repeat(201) }, 'target'],
      [{ state: 'done' }, 'state'], [{ dry_run: 2 }, 'dry_run'],
      [{ evidence_json: [1] }, 'evidence_json'], [{ evidence_json: { big: 'x'.repeat(17000) } }, 'evidence_json'],
    ]) {
      const r = await post(DB, over);
      assert.equal(r.status, 400, `${JSON.stringify(over).slice(0, 60)} -> ${r.status}`);
      assert.equal(r.body.error, field);
    }
    assert.equal(db.prepare('SELECT count(*) AS n FROM mr_red_actions').get().n, 0);
  });

  await t.test('patch-unverified: cleared without both verification times is 400', async () => {
    const { DB, db } = await openDb();
    const k = (await post(DB, { state: 'started', lever: 'fxa' })).body.action.action_key;
    for (const body of [{ state: 'cleared' }, { state: 'cleared', verified_red_at: '2026-11-11T10:00:00Z' },
      { state: 'cleared', verified_green_at: '2026-11-11T10:00:00Z' }]) {
      const r = await patch(DB, k, body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.equal(r.body.error, 'unverified');
    }
    assert.equal(db.prepare('SELECT state FROM mr_red_actions WHERE action_key=?').get(k).state, 'started');
    const bad = await patch(DB, k, { state: 'done', verified_red_at: '2026-11-11 10:00' });
    assert.equal(bad.status, 400);
    assert.equal(bad.body.error, 'verified_red_at');
    assert.equal((await patch(DB, k, { state: 'nope' })).status, 400);
  });

  await t.test('patch-verified: both times in the body, or one on the row and one in the body', async () => {
    const { DB, db } = await openDb();
    const k = (await post(DB, { state: 'started', lever: 'fxa' })).body.action.action_key;
    const r = await patch(DB, k, { state: 'cleared', verified_red_at: '2026-11-11T10:00:00Z', verified_green_at: '2026-11-11T10:05:00Z', evidence_json: { why: 'fixture' } });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.action.state, 'cleared');
    assert.deepEqual(r.body.action.evidence, { head: 'a'.repeat(40), why: 'fixture' }, 'evidence merges');
    const k2 = (await post(DB, { state: 'started', lever: 'fxb' })).body.action.action_key;
    assert.equal((await patch(DB, k2, { state: 'done', verified_red_at: '2026-11-11T10:00:00Z' })).status, 200);
    const r2 = await patch(DB, k2, { state: 'cleared', verified_green_at: '2026-11-11T10:06:00Z', charged_minutes: 6 });
    assert.equal(r2.status, 200, JSON.stringify(r2.body));
    const row = db.prepare('SELECT state, verified_red_at, verified_green_at, charged_minutes FROM mr_red_actions WHERE action_key=?').get(k2);
    assert.deepEqual({ ...row }, { state: 'cleared', verified_red_at: '2026-11-11T10:00:00Z', verified_green_at: '2026-11-11T10:06:00Z', charged_minutes: 6 });
  });

  await t.test('patch-404: an unknown key', async () => {
    const { DB } = await openDb();
    const r = await patch(DB, 'f'.repeat(64), { state: 'done' });
    assert.equal(r.status, 404);
    assert.equal((await patch(DB, 'not-a-key', { state: 'done' })).status, 400);
  });

  await t.test('get-paging: 250 rows in 3 pages, no duplicate, no gap; the cap is 100', async () => {
    const { DB, db } = await openDb();
    db.exec('BEGIN');
    const ins = db.prepare(`INSERT INTO mr_red_actions (action_key, fingerprint, repo, target, lever, state, created_at, updated_at)
      VALUES (?, ?, ?, ?, 'observe', 'observed', ?, ?)`);
    // 7 rows share each second, so a 100-row page edge falls inside a second: the id breaks the tie
    for (let i = 0; i < 250; i++) {
      const ts = `2026-11-11T10:${String(Math.floor(i / 7 / 60)).padStart(2, '0')}:${String(Math.floor(i / 7) % 60).padStart(2, '0')}Z`;
      ins.run(fp(`k${i}`), fp(`f${i}`), REPO, `#${i}`, ts, ts);
    }
    db.exec('COMMIT');
    const seen = [];
    let cursor = null; let pages = 0;
    do {
      const r = await get(DB, `?repo=${encodeURIComponent(REPO)}&limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`);
      assert.equal(r.status, 200, JSON.stringify(r.body));
      seen.push(...r.body.actions.map((a) => a.target));
      cursor = r.body.next_cursor; pages++;
    } while (cursor && pages < 10);
    assert.equal(pages, 3);
    assert.equal(seen.length, 250);
    assert.equal(new Set(seen).size, 250);
    assert.equal(seen[0], '#249', 'newest first');
    const big = await get(DB, '?limit=500');
    assert.equal(big.status, 200);
    assert.equal(big.body.actions.length, 100);
    assert.equal((await get(DB, '?limit=0')).status, 400);
    assert.equal((await get(DB, '?cursor=garbage')).status, 400);
    const dflt = await get(DB);
    assert.equal(dflt.body.actions.length, 50);
  });

  await t.test('get-filters and get-wrong-repo', async () => {
    const { DB } = await openDb();
    const f1 = fp('filter-1');
    await post(DB, { fingerprint: f1, target: '#1' });
    await post(DB, { fingerprint: f1, target: '#2', lever: 'fxa', state: 'started' });
    await post(DB, { fingerprint: fp('filter-2'), target: '#1', repo: 'example-org/project-2' });
    const n = async (q) => { const r = await get(DB, q); assert.equal(r.status, 200, `${q} ${JSON.stringify(r.body)}`); return r.body.actions.length; };
    assert.equal(await n(`?repo=${REPO}`), 2);
    assert.equal(await n('?repo=example-org/project-2'), 1);
    assert.equal(await n('?repo=example-org/nowhere'), 0, 'wrong repo gives 0 rows');
    assert.equal(await n('?lever=fxa'), 1);
    assert.equal(await n('?state=observed'), 2);
    assert.equal(await n(`?fingerprint=${f1}`), 2);
    assert.equal(await n(`?fingerprint=${f1}&target=%231`), 1);
    assert.equal(await n(`?repo=${REPO}&lever=observe&state=observed`), 1);
    for (const q of ['?repo=bad', '?fingerprint=xyz', '?state=weird', '?lever=Bad%20Lever']) {
      assert.equal((await get(DB, q)).status, 400, q);
    }
    const r = await get(DB, `?repo=${REPO}&lever=fxa`);
    assert.equal(r.body.actions[0].evidence.head, 'a'.repeat(40));
    assert.equal(r.body.next_cursor, null);
  });

  await t.test('explain: the hot reads use their indexes at 50k rows', async () => {
    const { db } = await openDb();
    db.exec('BEGIN');
    const ins = db.prepare(`INSERT INTO mr_red_actions (action_key, fingerprint, repo, target, lever, state, green_since, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`);
    const states = ['observed', 'started', 'done', 'failed', 'cleared'];
    for (let i = 0; i < 50000; i++) {
      const ts = new Date(Date.UTC(2026, 9, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
      ins.run(String(i).padStart(64, '0'), String(i % 9000).padStart(64, 'f'), `o/r${i % 40}`, `#${i % 3000}`,
        i % 3 ? 'observe' : 'fxa', states[i % 5], i % 5 === 2 ? ts : null, ts, ts);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const { SQL, listQuery } = await import('../src/routes/mr-red.js');
    const plan = (sql, b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const check = (name, sql, b, idx) => {
      const lines = plan(sql, b);
      assert.ok(lines.some((l) => l.includes(idx)), `${name}: ${idx} not used: ${lines.join(' | ')}`);
      assert.deepEqual(lines.filter((l) => /^SCAN mr_red_actions\b/.test(l) && !/USING/.test(l)), [], `${name}: ${lines.join(' | ')}`);
    };
    const C = ['2026-11-01T00:00:00Z', 999999];
    let q = listQuery({}, null, 51); check('list', q.sql, q.binds, 'ix_mr_red_actions_created');
    q = listQuery({}, C, 51); check('list+cursor', q.sql, q.binds, 'ix_mr_red_actions_created');
    q = listQuery({ repo: 'o/r7' }, null, 51); check('repo', q.sql, q.binds, 'ix_mr_red_actions_repo');
    q = listQuery({ repo: 'o/nowhere' }, C, 51); check('wrong repo', q.sql, q.binds, 'ix_mr_red_actions_repo');
    q = listQuery({ fingerprint: '7'.padStart(64, 'f'), target: '#7' }, null, 51); check('fp+target', q.sql, q.binds, 'ix_mr_red_actions_fp');
    q = listQuery({ state: 'done' }, null, 51); check('state', q.sql, q.binds, 'ix_mr_red_actions_state');
    check('by key', SQL.byKey, ['0'.repeat(64)], 'sqlite_autoindex_mr_red_actions');
  });
});
