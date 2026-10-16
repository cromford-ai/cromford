// BH-5807 (BH-5794.2): propose fixes for repeat causes. The worker half,
// driven through the REAL worker.fetch against the REAL jobs schema (the
// node:sqlite D1 shim), the way block-findings.bh-5806.test.js does it.
// Pinned here: GET /api/lesson-propose/triggers counts DISTINCT BLOCK verdicts
// per category inside the settings window, groups the `other` findings by the
// slug of their raw label, and POST /api/lesson-propose/categories adds one category row
// and moves only the window's matching `other` findings into it.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { TRIGGERS_WINDOW_SQL, CLUSTER_MOVE_SQL } from '../src/routes/lesson-propose.js';

const SECRET = 'test-secret';
const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const triggers = (DB) => call(DB, '/api/lesson-propose/triggers');
const addCat = (DB, body) => call(DB, '/api/lesson-propose/categories', { method: 'POST', body });

// One captured anchor: the route windows on the worker's own clock, so every
// fixture is whole days off the same real now.
const NOW_MS = Date.now(); // determinism: ok one captured anchor; every fixture is whole days off it and the window is 14 days wide
const ago = (days) => new Date(NOW_MS - days * 86400000).toISOString().replace(/\.\d{3}Z$/, 'Z');
let nextVerdict = 1000;
// One BLOCK finding row, the shape POST /api/block-classify/settle writes.
const addFinding = (db, { verdict, n = 1, pr = 100, category, raw = null, days = 1, infra = 0, cause = 'a cause' }) =>
  db.prepare(
    `INSERT INTO block_findings (verdict_id, n, repo, pr, ticket, head_sha, source, category, raw_category,
       confidence, cause, files, infra_false, text, model, verdict_at, created_at)
     VALUES (?, ?, 'example-org/cromford', ?, 'BH-9001', ?, 'lead', ?, ?, 0.8, ?, '["bin/x.sh"]', ?, ?, 'm', ?, ?)`
  ).run(verdict, n, pr, 'a'.repeat(40), category, raw, cause, infra, `- [BLOCK] bin/x.sh:${n}: finding ${verdict}/${n}`, ago(days), ago(days));
// <k> findings, one per new verdict, in one category.
const verdicts = (db, k, category, extra = {}) => {
  const ids = [];
  for (let i = 0; i < k; i++) {
    const v = nextVerdict++;
    ids.push(v);
    addFinding(db, { verdict: v, pr: v, category, ...extra });
  }
  return ids;
};
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, 't', 't', 'x') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);

test('BH-5807 lesson-propose routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 3 verdicts in one category trigger it, with blocks 3 and the verdict ids sorted', async () => {
    const { db, DB } = await openDb();
    const ids = verdicts(db, 3, 'test-cannot-fail');
    const r = await triggers(DB);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const c = r.body.categories.find((x) => x.id === 'test-cannot-fail');
    assert.ok(c, 'test-cannot-fail is a trigger');
    assert.equal(c.blocks, 3);
    assert.equal(c.findings, 3);
    assert.deepEqual(c.verdict_ids, [...ids].sort((a, b) => a - b));
    assert.equal(c.suggested_stage, 'builder');
    assert.equal(c.prs.length, 3);
    assert.ok(c.prs.every((p) => p.repo === 'example-org/cromford' && Number.isInteger(p.pr)));
    assert.equal(c.evidence.length, 3);
    assert.ok(c.evidence.every((e) => typeof e.text === 'string' && e.text.length <= 600 && Array.isArray(e.files)));
    assert.equal(r.body.settings.min_blocks, 3);
    assert.equal(r.body.settings.since_days, 14);
    assert.equal(r.body.settings.cooldown_days, 14);
    assert.equal(r.body.settings.max_attempts, 3);
  });

  await t.test('W1b evidence is capped at 20 findings and each text at 600', async () => {
    const { db, DB } = await openDb();
    for (let i = 0; i < 25; i++) {
      const v = nextVerdict++;
      db.prepare(
        `INSERT INTO block_findings (verdict_id, n, repo, pr, head_sha, category, text, verdict_at, created_at, files)
         VALUES (?, 1, 'example-org/cromford', ?, ?, 'iron-law', ?, ?, ?, '[]')`
      ).run(v, v, 'a'.repeat(40), 'x'.repeat(900), ago(1), ago(1));
    }
    const c = (await triggers(DB)).body.categories.find((x) => x.id === 'iron-law');
    assert.equal(c.blocks, 25);
    assert.equal(c.evidence.length, 20);
    assert.ok(c.evidence.every((e) => e.text.length === 600));
  });

  await t.test('W2 3 findings from ONE verdict do not trigger', async () => {
    const { db, DB } = await openDb();
    const v = nextVerdict++;
    for (let n = 1; n <= 3; n++) addFinding(db, { verdict: v, n, category: 'test-cannot-fail' });
    const r = await triggers(DB);
    assert.equal(r.body.categories.find((x) => x.id === 'test-cannot-fail'), undefined);
  });

  await t.test('W3 2 verdicts do not trigger', async () => {
    const { db, DB } = await openDb();
    verdicts(db, 2, 'test-cannot-fail');
    assert.equal((await triggers(DB)).body.categories.find((x) => x.id === 'test-cannot-fail'), undefined);
  });

  await t.test('W4 a verdict 15 days old is outside the 14-day window', async () => {
    const { db, DB } = await openDb();
    verdicts(db, 2, 'test-cannot-fail');
    verdicts(db, 1, 'test-cannot-fail', { days: 15 });
    assert.equal((await triggers(DB)).body.categories.find((x) => x.id === 'test-cannot-fail'), undefined);
  });

  await t.test('W5 `other` is never a category trigger', async () => {
    const { db, DB } = await openDb();
    verdicts(db, 4, 'other');
    assert.equal((await triggers(DB)).body.categories.find((x) => x.id === 'other'), undefined);
  });

  await t.test('W6 a retired category does not trigger', async () => {
    const { db, DB } = await openDb();
    db.prepare("UPDATE block_categories SET status='retired' WHERE id='test-cannot-fail'").run();
    verdicts(db, 3, 'test-cannot-fail');
    assert.equal((await triggers(DB)).body.categories.find((x) => x.id === 'test-cannot-fail'), undefined);
  });

  await t.test('W7 settings lesson_propose.min_blocks=4 turns the 3-verdict case off', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lesson_propose.min_blocks', '4');
    verdicts(db, 3, 'test-cannot-fail');
    const r = await triggers(DB);
    assert.equal(r.body.settings.min_blocks, 4);
    assert.equal(r.body.categories.find((x) => x.id === 'test-cannot-fail'), undefined);
    verdicts(db, 1, 'test-cannot-fail');
    assert.ok((await triggers(DB)).body.categories.find((x) => x.id === 'test-cannot-fail'));
  });

  await t.test('W8 a junk settings value falls back to the default 3', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lesson_propose.min_blocks', 'lots');
    verdicts(db, 3, 'test-cannot-fail');
    const r = await triggers(DB);
    assert.equal(r.body.settings.min_blocks, 3);
    assert.ok(r.body.categories.find((x) => x.id === 'test-cannot-fail'));
  });

  await t.test('R1 clusters group `other` raw labels by slug; exists is null for a new slug', async () => {
    const { db, DB } = await openDb();
    const a = nextVerdict++; const b = nextVerdict++; const c = nextVerdict++;
    addFinding(db, { verdict: a, pr: a, category: 'other', raw: 'Stale Lockfile', cause: 'lockfile was stale' });
    addFinding(db, { verdict: b, pr: b, category: 'other', raw: 'stale-lockfile', cause: 'old lockfile' });
    addFinding(db, { verdict: c, pr: c, category: 'other', raw: 'stale lockfile!', cause: 'lockfile drift' });
    // 3 different labels: no cluster.
    for (const raw of ['alpha thing', 'beta thing', 'gamma thing']) {
      const v = nextVerdict++; addFinding(db, { verdict: v, pr: v, category: 'other', raw });
    }
    // The label `other` itself is never a cluster.
    for (let i = 0; i < 3; i++) { const v = nextVerdict++; addFinding(db, { verdict: v, pr: v, category: 'other', raw: 'Other' }); }
    const r = await triggers(DB);
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.clusters.map((x) => x.id), ['stale-lockfile']);
    const cl = r.body.clusters[0];
    assert.equal(cl.blocks, 3);
    assert.equal(cl.exists, null);
    assert.deepEqual(cl.verdict_ids, [a, b, c]);
    assert.equal(cl.raw_labels.length, 3);
    assert.ok(cl.raw_labels.includes('Stale Lockfile'));
    assert.equal(cl.evidence.length, 3);
    assert.ok(typeof r.body.since === 'string' && r.body.since.endsWith('Z'));
  });

  await t.test('R1b a cluster whose slug is a retired row says exists: retired', async () => {
    const { db, DB } = await openDb();
    db.prepare("UPDATE block_categories SET status='retired' WHERE id='test-cannot-fail'").run();
    for (let i = 0; i < 3; i++) { const v = nextVerdict++; addFinding(db, { verdict: v, pr: v, category: 'other', raw: 'Test Cannot Fail' }); }
    const cl = (await triggers(DB)).body.clusters.find((x) => x.id === 'test-cannot-fail');
    assert.equal(cl.exists, 'retired');
  });

  await t.test('R2 both routes refuse a missing or wrong bearer', async () => {
    const { DB } = await openDb();
    for (const [method, path] of [['GET', '/api/lesson-propose/triggers'], ['POST', '/api/lesson-propose/categories']]) {
      for (const secret of [null, 'wrong']) {
        const r = await call(DB, path, { method, secret, body: method === 'POST' ? {} : undefined });
        assert.equal(r.status, 401, `${method} ${path} bearer ${secret}`);
      }
    }
  });

  const good = (over = {}) => ({
    id: 'stale-lockfile', name: 'Stale Lockfile', description: 'lockfile was stale; old lockfile',
    reason: '3 BLOCK verdicts in 14 days (1, 2, 3)', raw_labels: ['Stale Lockfile', 'stale-lockfile'],
    since: ago(14), ...over,
  });

  await t.test('R3 bad id, `other`, missing reason, bad labels and bad since are 400', async () => {
    const { DB } = await openDb();
    const cases = [
      [{ id: 'Bad Id' }, 'id'], [{ id: 'other' }, 'id'], [{ id: '' }, 'id'],
      [{ reason: '' }, 'reason'], [{ reason: undefined }, 'reason'], [{ reason: 'x'.repeat(501) }, 'reason'],
      [{ name: '' }, 'name'], [{ name: 'x'.repeat(121) }, 'name'],
      [{ raw_labels: [] }, 'raw_labels'], [{ raw_labels: 'x' }, 'raw_labels'], [{ raw_labels: [1] }, 'raw_labels'],
      [{ since: 'yesterday' }, 'since'],
    ];
    for (const [over, field] of cases) {
      const r = await addCat(DB, good(over));
      assert.equal(r.status, 400, JSON.stringify(over));
      assert.equal(r.body.error, field, JSON.stringify(over));
    }
  });

  await t.test('R4 a new category: 201, the row, and only the window\'s matching `other` rows moved', async () => {
    const { db, DB } = await openDb();
    const ids = [];
    for (const raw of ['Stale Lockfile', 'stale-lockfile', 'stale lockfile']) {
      const v = nextVerdict++; ids.push(v); addFinding(db, { verdict: v, pr: v, category: 'other', raw });
    }
    const old = nextVerdict++; addFinding(db, { verdict: old, pr: old, category: 'other', raw: 'Stale Lockfile', days: 20 });
    const other = nextVerdict++; addFinding(db, { verdict: other, pr: other, category: 'other', raw: 'unrelated' });
    const notOther = nextVerdict++; addFinding(db, { verdict: notOther, pr: notOther, category: 'iron-law', raw: 'stale lockfile' });
    const r = await addCat(DB, good());
    assert.equal(r.status, 201, JSON.stringify(r.body));
    assert.equal(r.body.created, true);
    assert.equal(r.body.moved, 3);
    const row = db.prepare("SELECT * FROM block_categories WHERE id='stale-lockfile'").get();
    assert.equal(row.added_by, 'lesson-propose');
    assert.equal(row.status, 'active');
    assert.equal(row.grp, 'Lesson-propose');
    assert.equal(row.suggested_stage, null);
    assert.equal(row.name, 'Stale Lockfile');
    assert.match(row.reason, /3 BLOCK verdicts/);
    const cat = (v) => db.prepare('SELECT category FROM block_findings WHERE verdict_id=?').get(v).category;
    for (const v of ids) assert.equal(cat(v), 'stale-lockfile');
    assert.equal(cat(old), 'other', 'outside since: not moved');
    assert.equal(cat(other), 'other', 'another label: not moved');
    assert.equal(cat(notOther), 'iron-law', 'not an other row: not moved');
  });

  await t.test('R5 a repeat is 200 created:false and writes no second row', async () => {
    const { db, DB } = await openDb();
    assert.equal((await addCat(DB, good())).status, 201);
    const r = await addCat(DB, good());
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.created, false);
    assert.equal(Number(db.prepare("SELECT count(*) n FROM block_categories WHERE id='stale-lockfile'").get().n), 1);
  });

  await t.test('R6 a retired id is 409 and nothing is written', async () => {
    const { db, DB } = await openDb();
    db.prepare("UPDATE block_categories SET status='retired' WHERE id='test-cannot-fail'").run();
    const v = nextVerdict++; addFinding(db, { verdict: v, pr: v, category: 'other', raw: 'test cannot fail' });
    const before = JSON.stringify(db.prepare("SELECT * FROM block_categories WHERE id='test-cannot-fail'").get());
    const r = await addCat(DB, good({ id: 'test-cannot-fail', raw_labels: ['test cannot fail'] }));
    assert.equal(r.status, 409);
    assert.equal(r.body.error, 'retired');
    assert.equal(JSON.stringify(db.prepare("SELECT * FROM block_categories WHERE id='test-cannot-fail'").get()), before);
    assert.equal(db.prepare('SELECT category FROM block_findings WHERE verdict_id=?').get(v).category, 'other');
  });

  await t.test('S1 the schema seeds the lesson_propose settings and the two model routes', async () => {
    const { db } = await openDb();
    const keys = db.prepare("SELECT key, value FROM settings WHERE key LIKE 'lesson_propose.%' ORDER BY key").all()
      .map((r) => `${r.key}=${r.value}`);
    assert.deepEqual(keys, ['lesson_propose.cooldown_days=14', 'lesson_propose.max_attempts=3',
      'lesson_propose.min_blocks=3', 'lesson_propose.since_days=14']);
    const rung = (role) => db.prepare("SELECT model, runner FROM model_routes WHERE project IS NULL AND role=? AND position=0").get(role);
    assert.deepEqual({ ...rung('lesson.propose') }, { ...db.prepare("SELECT model, runner FROM model_routes WHERE project IS NULL AND role='rule.miner' AND position=0 AND runner='claude'").get() });
    assert.deepEqual({ ...rung('stage.lesson-propose') }, { ...db.prepare("SELECT model, runner FROM model_routes WHERE project IS NULL AND role='stage.execute' AND position=0 AND runner='claude'").get() });
  });

  // BH-6730: the two hot reads use their index on realistic volume. 20 000
  // findings over 60 days, 4 categories, then ANALYZE so the planner sees the
  // spread. The SQL is the exact text the routes run (exported constants).
  const seedVolume = (db) => {
    const ins = db.prepare(
      `INSERT INTO block_findings (verdict_id, n, repo, pr, head_sha, category, raw_category, text, verdict_at, created_at, files)
       VALUES (?, ?, 'example-org/cromford', ?, ?, ?, ?, 'x', ?, ?, '[]')`);
    const cats = ['other', 'iron-law', 'test-cannot-fail', 'scope-creep'];
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const v = 500000 + Math.floor(i / 2);
      const at = new Date(NOW_MS - (i % 60) * 86400000 - i * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
      ins.run(v, (i % 2) + 1, v, 'a'.repeat(40), cats[i % 4], i % 4 === 0 ? `label ${i % 7}` : null, at, at);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
  };
  const plan = (db, sql, ...binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join('\n');
  const noBareScan = (p) => !/(^|\n)SCAN (f|block_findings)(\n|$)/.test(p) && !/SCAN (f|block_findings) (?!USING)/.test(p);

  await t.test('X1 the triggers window read uses idx_block_findings_at, no bare scan of block_findings', async () => {
    const { db } = await openDb();
    seedVolume(db);
    const p = plan(db, TRIGGERS_WINDOW_SQL, ago(14), 5001);
    assert.match(p, /idx_block_findings_at/, p);
    assert.ok(noBareScan(p), p);
  });

  await t.test('X2 the cluster-move read uses idx_block_findings_cat, no bare scan of block_findings', async () => {
    const { db } = await openDb();
    seedVolume(db);
    const p = plan(db, CLUSTER_MOVE_SQL, ago(14));
    assert.match(p, /idx_block_findings_cat/, p);
    assert.ok(noBareScan(p), p);
  });
});
