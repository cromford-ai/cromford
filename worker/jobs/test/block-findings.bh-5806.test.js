// BH-5806 (BH-5794.1): classify every BLOCK. The worker half, driven through
// the REAL worker.fetch against the REAL jobs schema (the node:sqlite D1 shim),
// the way staff-charter.test.js does it. Pinned here: every new route answers
// only the bearer (D1 has no RLS; the bearer is the admin-only gate), the schema
// replays twice with the same rows, the classify ledger is claimed BEFORE the
// paid call and refuses a terminal or capped verdict, a settle writes the
// findings exactly once, and the weekly view counts what the settle wrote.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
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
const claim = (DB, verdict_id) => call(DB, '/api/block-classify/claim', { method: 'POST', body: { verdict_id } });
const settle = (DB, body) => call(DB, '/api/block-classify/settle', { method: 'POST', body });

// A verdict row the way bin/lead-verdict.sh writes one. created_at is relative
// to now so the pending window (lesson_classify.since_days) always holds it.
// One anchor, captured once: the routes window on the worker's own clock
// (nowIso), so the fixtures are placed relative to the same real now.
const NOW_MS = Date.now(); // determinism: ok one captured anchor; every fixture is whole days off it and the window is 14 days wide
const ago = (days) => new Date(NOW_MS - days * 86400000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const addVerdict = (db, { pr = 100, verdict = 'BLOCK', source = 'lead', days = 1, note = 'lead-review:r1 lead-job:j1' } = {}) =>
  Number(db.prepare(
    `INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer, report_url, note, created_at)
     VALUES ('example-org/cromford', ?, ?, ?, ?, 'mac-lead', ?, ?, ?)`
  ).run(pr, 'a'.repeat(40), verdict, source, `https://github.com/example-org/cromford/pull/${pr}`, note, ago(days)).lastInsertRowid);
const F = (n, category, extra = {}) => ({
  n, text: `- [BLOCK] bin/x.sh:${n}: finding ${n}`, category, confidence: 0.8, cause: `cause ${n}`,
  files: [`bin/x.sh`], infra_false: false, ...extra,
});

test('BH-5806 block findings', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 every new route refuses a missing or a wrong bearer (admin-only)', async () => {
    const { DB } = await openDb();
    const routes = [
      ['GET', '/api/block-categories'],
      ['GET', '/api/block-classify/pending'],
      ['POST', '/api/block-classify/claim'],
      ['POST', '/api/block-classify/settle'],
      ['GET', '/api/block-findings/weekly'],
      ['GET', '/api/block-findings'],
    ];
    for (const [method, path] of routes) {
      for (const secret of [null, 'wrong']) {
        const r = await call(DB, path, { method, secret, body: method === 'POST' ? { verdict_id: 1 } : undefined });
        assert.equal(r.status, 401, `${method} ${path} with bearer ${secret}`);
      }
      const ok = await call(DB, path, { method, body: method === 'POST' ? {} : undefined });
      assert.notEqual(ok.status, 401, `${method} ${path} with the secret`);
      assert.notEqual(ok.status, 404, `${method} ${path} is routed`);
    }
  });

  await t.test('W2 the schema replays twice: same 31 categories, the route and the settings rows, no error', async () => {
    const { db, DB } = await openDb();
    const snap = () => JSON.stringify([
      db.prepare('SELECT * FROM block_categories ORDER BY id').all(),
      db.prepare("SELECT role, position, model FROM model_routes WHERE role='lesson.classify'").all(),
      db.prepare("SELECT key, value FROM settings WHERE key LIKE 'lesson_classify.%' ORDER BY key").all(),
    ]);
    const before = snap();
    db.exec(SCHEMA);
    db.exec(SCHEMA);
    assert.equal(snap(), before);
    assert.equal(db.prepare('SELECT count(*) AS n FROM block_categories').get().n, 31);
    assert.ok(db.prepare("SELECT 1 FROM block_categories WHERE id='other'").get(), 'other is seeded');
    const route = db.prepare("SELECT model FROM model_routes WHERE role='lesson.classify' AND position=0").get();
    assert.match(route.model, /haiku/, 'lesson.classify starts on the cheap route');
    const cats = await call(DB, '/api/block-categories');
    assert.equal(cats.status, 200);
    assert.equal(cats.body.categories.length, 31);
    const one = cats.body.categories.find((c) => c.id === 'rp-suite-missing-at-head');
    assert.ok(one, 'a seeded category from the 2026-10 analysis');
    assert.ok(Array.isArray(one.example_prs) && one.example_prs.length > 0, 'example PRs ride along');
    // An operator's edit survives a replay (INSERT OR IGNORE, never an UPDATE).
    db.prepare("UPDATE block_categories SET name='edited' WHERE id='other'").run();
    db.exec(SCHEMA);
    assert.equal(db.prepare("SELECT name FROM block_categories WHERE id='other'").get().name, 'edited');
  });

  await t.test('W2b the seed covers every bucket the ticket names (BH-5806 "include at least")', async () => {
    const { db } = await openDb();
    const ids = new Set(db.prepare('SELECT id FROM block_categories').all().map((r) => r.id));
    const groups = new Set(db.prepare('SELECT grp FROM block_categories').all().map((r) => r.grp));
    // Each ticket bucket maps to one seeded id, or to a group of ids that split it.
    const buckets = [
      ['shared-append conflict', ids.has('shared-append-conflict')],
      ['fixture/leak hygiene', ids.has('fixture-leak-hygiene')],
      ['PR-body evidence', ids.has('evidence-not-bound-to-head')],
      ['design collision / caller not ported', ids.has('callers-not-ported')],
      ['brittle whole-output test', ids.has('brittle-whole-output-test')],
      ['infra false BLOCK', groups.has('Review infra')],
      ['real logic bug', groups.has('Logic bugs')],
      ['iron-law', ids.has('iron-law')],
      ['scope miss', groups.has('Scope')],
    ];
    for (const [bucket, has] of buckets) assert.ok(has, `the seed has no category for the ticket bucket "${bucket}"`);
  });

  await t.test('W3 claim before the call: terminal and capped verdicts are refused, a settle replays', async () => {
    const { db, DB } = await openDb();
    const v = addVerdict(db);
    const c1 = await claim(DB, v);
    assert.equal(c1.status, 201);
    assert.equal(c1.body.claimed, true);
    assert.equal(c1.body.attempts, 1);
    const s1 = await settle(DB, { verdict_id: v, status: 'ok', model: 'm', ticket: 'BH-1', findings: [F(1, 'other'), F(2, 'other'), F(3, 'other')] });
    assert.equal(s1.status, 200, JSON.stringify(s1.body));
    assert.equal(db.prepare('SELECT count(*) AS n FROM block_findings WHERE verdict_id=?').get(v).n, 3);
    const s2 = await settle(DB, { verdict_id: v, status: 'ok', model: 'm', findings: [F(1, 'other')] });
    assert.equal(s2.status, 200, 'the same status onto a settled row is a replay');
    assert.equal(db.prepare('SELECT count(*) AS n FROM block_findings WHERE verdict_id=?').get(v).n, 3, 'a replay writes nothing');
    const c2 = await claim(DB, v);
    assert.equal(c2.status, 409);
    assert.equal(c2.body.error, 'terminal');
    const s3 = await settle(DB, { verdict_id: v, status: 'failed', error: 'x' });
    assert.equal(s3.status, 409, 'ok never moves to failed');

    // empty is terminal: never claimed again.
    const e = addVerdict(db, { pr: 101 });
    assert.equal((await claim(DB, e)).status, 201);
    assert.equal((await settle(DB, { verdict_id: e, status: 'empty', model: 'm' })).status, 200);
    assert.equal((await claim(DB, e)).status, 409);

    // failed retries up to lesson_classify.max_attempts (3), then the cap refuses.
    const f = addVerdict(db, { pr: 102 });
    for (let i = 1; i <= 3; i++) {
      const c = await claim(DB, f);
      assert.ok(c.status === 201 || c.status === 200, `attempt ${i}: ${c.status}`);
      assert.equal(c.body.attempts, i);
      assert.equal((await settle(DB, { verdict_id: f, status: 'failed', error: 'rc 1' })).status, 200);
    }
    const capped = await claim(DB, f);
    assert.equal(capped.status, 409);
    assert.equal(capped.body.error, 'at_cap');

    // refund: a call the gate refused (nothing billed) gives its attempt back.
    const r = addVerdict(db, { pr: 103 });
    await claim(DB, r);
    assert.equal((await settle(DB, { verdict_id: r, status: 'failed', error: 'rc 74', refund: true })).status, 200);
    assert.equal(db.prepare('SELECT attempts FROM block_classify_runs WHERE verdict_id=?').get(r).attempts, 0);

    // Only a BLOCK verdict is classified; an unknown id is 404.
    const m = addVerdict(db, { pr: 104, verdict: 'MERGE' });
    assert.equal((await claim(DB, m)).status, 409);
    assert.equal((await claim(DB, 999999)).status, 404);
    // ok needs findings, empty/failed carry none.
    const b = addVerdict(db, { pr: 105 });
    await claim(DB, b);
    assert.equal((await settle(DB, { verdict_id: b, status: 'ok', findings: [] })).status, 400);
    assert.equal((await settle(DB, { verdict_id: b, status: 'bogus' })).status, 400);
  });

  await t.test('W4 pending lists BLOCKs in the window with no ok/empty run and attempts under the cap', async () => {
    const { db, DB } = await openDb();
    const fresh = addVerdict(db, { pr: 200 });
    const done = addVerdict(db, { pr: 201 });
    const old = addVerdict(db, { pr: 202, days: 40 });
    addVerdict(db, { pr: 203, verdict: 'MERGE' });
    const failing = addVerdict(db, { pr: 204 });
    await claim(DB, done);
    await settle(DB, { verdict_id: done, status: 'empty' });
    await claim(DB, failing);
    await settle(DB, { verdict_id: failing, status: 'failed', error: 'x' });
    const p = await call(DB, '/api/block-classify/pending?limit=10');
    assert.equal(p.status, 200);
    const ids = p.body.verdicts.map((r) => r.verdict_id).sort((a, b) => a - b);
    assert.deepEqual(ids, [fresh, failing].sort((a, b) => a - b));
    assert.ok(!ids.includes(old), 'older than lesson_classify.since_days (14) is out of the window');
    const row = p.body.verdicts.find((r) => r.verdict_id === failing);
    assert.equal(row.attempts, 1);
    assert.equal(row.note, 'lead-review:r1 lead-job:j1');
    // The window is a settings row.
    db.prepare("UPDATE settings SET value='60' WHERE key='lesson_classify.since_days'").run();
    const wide = await call(DB, '/api/block-classify/pending?limit=10');
    assert.ok(wide.body.verdicts.some((r) => r.verdict_id === old));
    const one = await call(DB, '/api/block-classify/pending?limit=1');
    assert.equal(one.body.verdicts.length, 1);
    assert.equal(one.body.truncated, true);
  });

  await t.test('W5 weekly counts per category, and the drill rows link the PR and the verdict', async () => {
    const { db, DB } = await openDb();
    const v1 = addVerdict(db, { pr: 300 });
    const v2 = addVerdict(db, { pr: 301 });
    for (const [v, fs] of [[v1, [F(1, 'ci-tests-skipped'), F(2, 'ci-tests-skipped')]], [v2, [F(1, 'ci-tests-skipped'), F(2, 'other')]]]) {
      await claim(DB, v);
      assert.equal((await settle(DB, { verdict_id: v, status: 'ok', findings: fs })).status, 200);
    }
    const w = await call(DB, '/api/block-findings/weekly?weeks=4');
    assert.equal(w.status, 200);
    const row = w.body.rows.find((r) => r.category === 'ci-tests-skipped');
    assert.ok(row, JSON.stringify(w.body));
    assert.equal(row.findings, 3);
    assert.equal(row.verdicts, 2);
    assert.equal(row.prs, 2);
    assert.match(row.week, /^\d{4}-\d{2}-\d{2}$/);
    assert.equal(new Date(row.week + 'T00:00:00Z').getUTCDay(), 1, 'a week starts on Monday');
    assert.ok(row.name, 'the category name rides along');
    const d = await call(DB, `/api/block-findings?category=ci-tests-skipped&week=${row.week}`);
    assert.equal(d.status, 200);
    assert.equal(d.body.rows.length, 3);
    const r0 = d.body.rows[0];
    assert.equal(r0.repo, 'example-org/cromford');
    assert.ok([300, 301].includes(r0.pr));
    assert.ok([v1, v2].includes(r0.verdict_id));
    assert.match(r0.report_url, /^https:\/\/github\.com\//);
    assert.deepEqual(r0.files, ['bin/x.sh']);
    assert.equal(r0.infra_false, false);
    assert.equal((await call(DB, '/api/block-findings?week=not-a-date')).status, 400);
  });

  await t.test('W6 an unknown category is stored as other, with the model\'s label kept', async () => {
    const { db, DB } = await openDb();
    const v = addVerdict(db, { pr: 400 });
    await claim(DB, v);
    assert.equal((await settle(DB, { verdict_id: v, status: 'ok', findings: [F(1, 'made-up-bucket', { infra_false: true })] })).status, 200);
    const r = db.prepare('SELECT category, raw_category, infra_false FROM block_findings WHERE verdict_id=?').get(v);
    assert.equal(r.category, 'other');
    assert.equal(r.raw_category, 'made-up-bucket');
    assert.equal(r.infra_false, 1);
  });
});
