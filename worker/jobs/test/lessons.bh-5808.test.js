// BH-5808 (BH-5794.3): measure and retire lessons. The worker half, driven
// through the REAL worker.fetch against the REAL jobs schema (the node:sqlite
// D1 shim), the way lesson-propose.bh-5807.test.js does it.
// Pinned here: POST /api/lessons records one row per (repo, kind, number);
// POST /api/lessons/measure compares the category BLOCK rate per 100 reviewed
// PRs before and after the merge and judges working / not-working /
// inconclusive; GET /api/lessons/pending lists the escalations and the
// removals; GET /api/lessons/digest renders the weekly numbers; and every hot
// read uses its index at seeded volume.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import {
  RECORD_LOOKUP_SQL, MEASURING_SQL, windowBlocksSql, WINDOW_REVIEWED_SQL, PENDING_ESCALATE_SQL, PENDING_TYPE_SQL,
  PENDING_ESCALATED_SQL, DIGEST_CATEGORY_SQL, DIGEST_OVERALL_SQL, DIGEST_STATUS_SQL, DIGEST_LIST_SQL, RETENTION_COUNT_SQL,
} from '../src/routes/lessons.js';

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
const record = (DB, body) => call(DB, '/api/lessons', { method: 'POST', body });
const measure = (DB) => call(DB, '/api/lessons/measure', { method: 'POST', body: {} });
const pending = (DB) => call(DB, '/api/lessons/pending');
const mark = (DB, body) => call(DB, '/api/lessons/mark', { method: 'POST', body });
const digest = (DB, q = '') => call(DB, `/api/lessons/digest${q}`);

// One captured anchor: the routes window on the worker's own clock, so every
// fixture is whole days (plus a fixed offset) off the same real now.
const NOW_MS = Date.now(); // determinism: ok one captured anchor; every fixture is whole days off it
const DAY = 86400000;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days) => iso(NOW_MS - days * DAY);
const R = 'example-org/cromford';
const SHA = 'c'.repeat(40);

let nextPr = 10000;
// population: <prs> PRs with one verdict each, spread evenly over <days> days
// from <startMs>; the first <blocks> are BLOCK verdicts with one finding in
// <category> (the rows POST /api/verdicts and POST /api/block-classify/settle write).
const population = (db, { startMs, days, prs, blocks = 0, category }) => {
  const v = db.prepare(
    "INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer, created_at) VALUES (?, ?, ?, ?, 'lead', 'mac-lead', ?)");
  const f = db.prepare(
    `INSERT INTO block_findings (verdict_id, n, repo, pr, ticket, head_sha, source, category, cause, files, infra_false, text, verdict_at, created_at)
     VALUES (?, 1, ?, ?, 'BH-9001', ?, 'lead', ?, 'a cause', '[]', 0, '- [BLOCK] bin/x.sh:1: a finding', ?, ?)`);
  const step = (days * DAY) / prs;
  db.exec('BEGIN');
  for (let i = 0; i < prs; i++) {
    const pr = nextPr++;
    const at = iso(startMs + Math.floor(i * step) + 60000);
    const isBlock = i < blocks;
    const r = v.run(R, pr, SHA, isBlock ? 'BLOCK' : 'MERGE', at);
    if (isBlock) f.run(Number(r.lastInsertRowid), R, pr, SHA, category, at, at);
  }
  db.exec('COMMIT');
};
// A lesson merged <mergedDaysAgo> days ago with a before and an after population.
const scenario = (db, { category, mergedDaysAgo, before, after, afterDays = 14 }) => {
  const m = NOW_MS - mergedDaysAgo * DAY;
  if (before) population(db, { startMs: m - 14 * DAY, days: 14, category, ...before });
  if (after) population(db, { startMs: m, days: afterDays, category, ...after });
  return iso(m);
};
const insLesson = (db, l) => {
  const r = db.prepare(
    `INSERT INTO lessons (category, change_type, kind, repo, number, url, title, source, merged_at, status,
       escalation_stage, escalation_number, removal_number, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, 't', 'proposal', ?, ?, ?, ?, ?, ?, ?)`
  ).run(l.category, l.change_type || 'plan-lesson', l.kind || 'pr', R, l.number, `https://github.com/${R}/pull/${l.number}`,
    l.merged_at, l.status || 'measuring', l.escalation_stage || null, l.escalation_number || null, l.removal_number || null, ago(0), ago(0));
  return Number(r.lastInsertRowid);
};
const row = (db, id) => db.prepare('SELECT * FROM lessons WHERE id = ?').get(id);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, 't', 't', 'x') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);
let nextNum = 7000;
const lessonBody = (over = {}) => ({
  category: 'test-cannot-fail', change_type: 'plan-lesson', kind: 'pr', repo: R, number: nextNum++,
  url: `https://github.com/${R}/pull/1`, title: 'Lesson: x [lesson:test-cannot-fail]', merged_at: ago(20), source: 'proposal', ...over,
});

test('BH-5808 lessons routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('S1 the composed schema applies twice (the fragment is idempotent)', async () => {
    const { db } = await openDb();
    const sql = jobsSchemaSql();
    db.exec(sql);
    const idx = db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name IN ('lessons','verdicts')").all().map((r) => r.name);
    for (const n of ['idx_lessons_status', 'idx_lessons_cat', 'idx_lessons_type', 'idx_lessons_merged', 'idx_lessons_esc', 'idx_verdicts_created']) {
      assert.ok(idx.includes(n), n);
    }
  });

  await t.test('S2 the seed settings rows exist with the ticket numbers', async () => {
    const { db } = await openDb();
    const v = (k) => db.prepare('SELECT value FROM settings WHERE key = ?').get(k)?.value;
    assert.equal(v('lessons.window_days'), '14');
    assert.equal(v('lessons.min_reviewed'), '30');
    assert.equal(v('lessons.min_cut_pct'), '30');
    assert.equal(v('lessons.max_window_days'), '42');
    assert.equal(v('lessons.stage_order'), 'plan-lesson,builder-rule,check,harness-bug');
    assert.equal(v('lessons.retention_dry_run'), undefined, 'no delete switch: lessons rows are kept');
    assert.equal(v('lessons.retention_days'), '730');
    assert.equal(v('lessons.list_limit'), '100');
  });

  await t.test('R1 a new lesson is 201 with an id, category, merged_at and change type', async () => {
    const { db, DB } = await openDb();
    const b = lessonBody();
    const r = await record(DB, b);
    assert.equal(r.status, 201, JSON.stringify(r.body));
    assert.equal(r.body.created, true);
    const l = row(db, r.body.id);
    assert.equal(l.category, 'test-cannot-fail');
    assert.equal(l.change_type, 'plan-lesson');
    assert.equal(l.merged_at, b.merged_at);
    assert.equal(l.status, 'measuring');
    assert.equal(l.source, 'proposal');
  });

  await t.test('R2 the same number again is 200 and still one row', async () => {
    const { db, DB } = await openDb();
    const b = lessonBody();
    const a = await record(DB, b);
    const again = await record(DB, b);
    assert.equal(again.status, 200);
    assert.equal(again.body.created, false);
    assert.equal(again.body.id, a.body.id);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lessons').get().n, 1);
  });

  await t.test('R3 an escalation issue number takes the escalation stage and source', async () => {
    const { db, DB } = await openDb();
    insLesson(db, { category: 'test-cannot-fail', number: 501, merged_at: ago(30), status: 'not-working', escalation_stage: 'builder-rule', escalation_number: 7777 });
    const r = await record(DB, lessonBody({ kind: 'issue', number: 7777, change_type: 'plan-lesson' }));
    assert.equal(r.status, 201, JSON.stringify(r.body));
    const l = row(db, r.body.id);
    assert.equal(l.change_type, 'builder-rule');
    assert.equal(l.source, 'escalation');
    // A PR with that number is not the escalation issue.
    const p = await record(DB, lessonBody({ kind: 'pr', number: 7777 }));
    assert.equal(row(db, p.body.id).change_type, 'plan-lesson');
  });

  await t.test('R4 a bad enum or field is 400 and writes nothing', async () => {
    const { db, DB } = await openDb();
    for (const over of [{ change_type: 'lint' }, { kind: 'commit' }, { source: 'x' }, { merged_at: '2026-10-01' },
      { category: 'Bad Cat' }, { number: 0 }, { repo: 'nope' }, { url: 'http://x' }]) {
      const r = await record(DB, lessonBody(over));
      assert.equal(r.status, 400, JSON.stringify(over));
    }
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lessons').get().n, 0);
  });

  await t.test('R5 no bearer is 401 on every lessons route', async () => {
    const { DB } = await openDb();
    for (const [m, p] of [['POST', '/api/lessons'], ['POST', '/api/lessons/measure'], ['GET', '/api/lessons/pending'],
      ['POST', '/api/lessons/mark'], ['POST', '/api/lessons/retention'], ['GET', '/api/lessons/digest']]) {
      const r = await call(DB, p, { method: m, body: m === 'POST' ? {} : undefined, secret: null });
      assert.equal(r.status, 401, `${m} ${p}`);
    }
  });

  // ── M: the judgement ───────────────────────────────────────────────────
  const judgeOne = async (sc, extra = {}) => {
    const { db, DB } = await openDb();
    const merged_at = scenario(db, { category: 'test-cannot-fail', ...sc });
    const id = insLesson(db, { category: 'test-cannot-fail', number: 900, merged_at, ...extra });
    const r = await measure(DB);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    return { db, DB, id, r, l: row(db, id) };
  };

  await t.test('M1 10/100 before, 2/100 after is working', async () => {
    const { l, r } = await judgeOne({ mergedDaysAgo: 20, before: { prs: 100, blocks: 10 }, after: { prs: 100, blocks: 2 } });
    assert.equal(l.status, 'working');
    assert.equal(l.before_blocks, 10);
    assert.equal(l.before_reviewed, 100);
    assert.equal(l.after_blocks, 2);
    assert.equal(l.after_reviewed, 100);
    assert.equal(l.cut_pct, 80);
    assert.ok(l.measured_at);
    const j = r.body.judged.find((x) => x.id === l.id);
    assert.equal(j.before_rate, 10);
    assert.equal(j.after_rate, 2);
  });

  await t.test('M2 10/100 then 9/100 is not-working', async () => {
    const { l } = await judgeOne({ mergedDaysAgo: 20, before: { prs: 100, blocks: 10 }, after: { prs: 100, blocks: 9 } });
    assert.equal(l.status, 'not-working');
    assert.equal(l.cut_pct, 10);
  });

  await t.test('M3 10 then 7 per 100 is working (exactly a 30% cut)', async () => {
    const { l } = await judgeOne({ mergedDaysAgo: 20, before: { prs: 100, blocks: 10 }, after: { prs: 100, blocks: 7 } });
    assert.equal(l.status, 'working');
    assert.equal(l.cut_pct, 30);
  });

  await t.test('M4 10/100 then 71/1000 is not-working (just over the edge)', async () => {
    const { l } = await judgeOne({ mergedDaysAgo: 20, before: { prs: 100, blocks: 10 }, after: { prs: 1000, blocks: 71 } });
    assert.equal(l.after_reviewed, 1000);
    assert.equal(l.after_blocks, 71);
    assert.equal(l.status, 'not-working');
  });

  await t.test('M5 0 BLOCKs before is inconclusive, never working', async () => {
    const { l } = await judgeOne({ mergedDaysAgo: 20, before: { prs: 100, blocks: 0 }, after: { prs: 100, blocks: 0 } });
    assert.equal(l.status, 'inconclusive');
    const { l: l2 } = await judgeOne({ mergedDaysAgo: 20, after: { prs: 100, blocks: 0 } });
    assert.equal(l2.before_reviewed, 0);
    assert.equal(l2.status, 'inconclusive');
  });

  await t.test('M6 a window not yet complete stays measuring, with its counts so far', async () => {
    const { l, r } = await judgeOne({ mergedDaysAgo: 10, before: { prs: 100, blocks: 10 }, after: { prs: 50, blocks: 1 }, afterDays: 9 });
    assert.equal(l.status, 'measuring');
    assert.equal(l.before_blocks, 10);
    assert.equal(l.after_reviewed, 50);
    assert.equal(r.body.still_measuring, 1);
    assert.equal(r.body.judged.length, 0);
  });

  await t.test('M7 complete with 29 reviewed stays measuring; at max_window_days it is inconclusive; 30 judges', async () => {
    const a = await judgeOne({ mergedDaysAgo: 15, before: { prs: 100, blocks: 10 }, after: { prs: 29, blocks: 0 } });
    assert.equal(a.l.status, 'measuring');
    const b = await judgeOne({ mergedDaysAgo: 43, before: { prs: 100, blocks: 10 }, after: { prs: 29, blocks: 0 } });
    assert.equal(b.l.status, 'inconclusive');
    const c = await judgeOne({ mergedDaysAgo: 15, before: { prs: 100, blocks: 10 }, after: { prs: 30, blocks: 0 } });
    assert.equal(c.l.status, 'working');
    assert.equal(c.l.after_reviewed, 30);
    // The window grows: 20 PRs in 14 days and 10 more on day 16 judge at day 17.
    const { db, DB } = await openDb();
    const merged_at = scenario(db, { category: 'test-cannot-fail', mergedDaysAgo: 20, before: { prs: 100, blocks: 10 }, after: { prs: 20, blocks: 0 } });
    population(db, { startMs: Date.parse(merged_at) + 16 * DAY, days: 0.5, prs: 10, blocks: 0, category: 'test-cannot-fail' });
    const id = insLesson(db, { category: 'test-cannot-fail', number: 901, merged_at });
    await measure(DB);
    const l = row(db, id);
    assert.equal(l.status, 'working');
    assert.equal(l.after_reviewed, 30);
    assert.equal(l.after_end, iso(Date.parse(merged_at) + 17 * DAY));
  });

  await t.test('M8 a truncated read writes nothing', async () => {
    const { db, DB } = await openDb();
    const merged_at = scenario(db, { category: 'test-cannot-fail', mergedDaysAgo: 20, before: { prs: 100, blocks: 10 }, after: { prs: 100, blocks: 2 } });
    population(db, { startMs: NOW_MS - 30 * DAY, days: 30, prs: 50001, blocks: 0, category: 'x' });
    const id = insLesson(db, { category: 'test-cannot-fail', number: 902, merged_at });
    const r = await measure(DB);
    assert.equal(r.body.truncated, true);
    const l = row(db, id);
    assert.equal(l.status, 'measuring');
    assert.equal(l.before_blocks, null);
    assert.equal(l.measured_at, null);
  });

  await t.test('M9 a judged row is never judged again; only measuring rows are read', async () => {
    const { db, DB } = await openDb();
    const merged_at = scenario(db, { category: 'test-cannot-fail', mergedDaysAgo: 20, before: { prs: 100, blocks: 10 }, after: { prs: 100, blocks: 9 } });
    const id = insLesson(db, { category: 'test-cannot-fail', number: 903, merged_at, status: 'working' });
    const r = await measure(DB);
    assert.equal(r.body.judged.length, 0);
    assert.equal(row(db, id).status, 'working');
  });

  // ── P: pending and mark ────────────────────────────────────────────────
  await t.test('P1 a not-working plan-lesson is in escalate with next_stage builder-rule', async () => {
    const { db, DB } = await openDb();
    const id = insLesson(db, { category: 'test-cannot-fail', number: 910, merged_at: ago(30), status: 'not-working' });
    insLesson(db, { category: 'iron-law', number: 911, merged_at: ago(30), status: 'working' });
    const r = await pending(DB);
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.escalate.map((x) => [x.id, x.next_stage]), [[id, 'builder-rule']]);
    assert.equal(r.body.settings.min_cut_pct, 30);
    // Once escalated, it leaves the list.
    await mark(DB, { id, escalation_stage: 'builder-rule', escalation_number: 8001, escalation_url: `https://github.com/${R}/issues/8001` });
    assert.equal((await pending(DB)).body.escalate.length, 0);
    assert.deepEqual((await pending(DB)).body.escalated_open.map((x) => x.escalation_number), [8001]);
  });

  await t.test('P2 next_stage follows the stage order; harness-bug has none', async () => {
    const { db, DB } = await openDb();
    const ids = {};
    for (const [i, ct] of ['builder-rule', 'check', 'harness-bug'].entries()) {
      ids[ct] = insLesson(db, { category: `c-${i}`, change_type: ct, kind: ct === 'builder-rule' ? 'pr' : 'issue', number: 920 + i, merged_at: ago(30), status: 'not-working' });
    }
    const got = Object.fromEntries((await pending(DB)).body.escalate.map((x) => [x.change_type, x.next_stage]));
    assert.deepEqual(got, { 'builder-rule': 'check', check: 'harness-bug', 'harness-bug': null });
  });

  await t.test('P3 a plan-lesson with a LATER check in the same category is in retire; other categories, earlier checks and builder rules are not', async () => {
    const { db, DB } = await openDb();
    const a = insLesson(db, { category: 'test-cannot-fail', number: 930, merged_at: ago(40), status: 'working' });
    const chk = insLesson(db, { category: 'test-cannot-fail', change_type: 'check', kind: 'issue', number: 931, merged_at: ago(20) });
    insLesson(db, { category: 'iron-law', number: 932, merged_at: ago(40) });
    insLesson(db, { category: 'scope-creep', change_type: 'check', kind: 'issue', number: 933, merged_at: ago(20) });
    insLesson(db, { category: 'iron-law', change_type: 'check', kind: 'issue', number: 934, merged_at: ago(50) }); // EARLIER
    insLesson(db, { category: 'no-test', number: 935, merged_at: ago(40) });
    insLesson(db, { category: 'no-test', change_type: 'builder-rule', number: 936, merged_at: ago(20) });
    const r = await pending(DB);
    assert.deepEqual(r.body.retire.map((x) => [x.id, x.superseded_by, x.superseded_by_type]), [[a, chk, 'check']]);
    assert.deepEqual(r.body.removing, []);
    // An OPEN removal PR does not supersede the row: it moves to `removing`.
    await mark(DB, { id: a, removal_number: 9100, removal_url: `https://github.com/${R}/pull/9100`, superseded_by: chk });
    let p = (await pending(DB)).body;
    assert.equal(p.retire.length, 0);
    assert.deepEqual(p.removing.map((x) => [x.id, x.removal_number]), [[a, 9100]]);
    assert.equal(row(db, a).status, 'working', 'still working while the removal PR is open');
    // Closed without a merge: clear_removal puts the row back in retire.
    await mark(DB, { id: a, clear_removal: true });
    p = (await pending(DB)).body;
    assert.deepEqual(p.retire.map((x) => x.id), [a]);
    assert.deepEqual(p.removing, []);
    assert.equal(row(db, a).removal_number, null);
    assert.equal(row(db, a).removal_url, null);
    // A new PR, then the merge: superseded, in neither list.
    await mark(DB, { id: a, removal_number: 9101, superseded_by: chk });
    await mark(DB, { id: a, status: 'superseded' });
    p = (await pending(DB)).body;
    assert.equal(p.retire.length, 0);
    assert.equal(p.removing.length, 0);
    assert.equal(row(db, a).status, 'superseded');
  });

  await t.test('P4 mark refuses an unknown column, a bad status and an unknown id', async () => {
    const { db, DB } = await openDb();
    const id = insLesson(db, { category: 'test-cannot-fail', number: 940, merged_at: ago(30) });
    assert.equal((await mark(DB, { id, category: 'x' })).status, 400);
    assert.equal((await mark(DB, { id, status: 'working' })).status, 400);
    assert.equal((await mark(DB, { id, escalation_url: 'http://x' })).status, 400);
    assert.equal((await mark(DB, { id: 99999, removal_note: 'absent' })).status, 404);
    assert.equal((await mark(DB, { id, clear_removal: false })).status, 400);
    assert.equal((await mark(DB, { id, clear_removal: true, removal_number: 5 })).status, 400);
    assert.equal((await mark(DB, { id, clear_removal: true, status: 'superseded' })).status, 400);
    const ok = await mark(DB, { id, status: 'removed', removal_note: 'absent' });
    assert.equal(ok.status, 200);
    assert.equal(row(db, id).status, 'removed');
    assert.equal(row(db, id).removal_note, 'absent');
  });

  // ── D: the digest ──────────────────────────────────────────────────────
  // A real-shaped week: 40 reviewed PRs, 6 BLOCKs in test-cannot-fail, 3 in
  // iron-law, 1 in other; a measuring lesson on test-cannot-fail.
  const digestFixture = (db) => {
    population(db, { startMs: NOW_MS - 6 * DAY, days: 5, prs: 20, blocks: 6, category: 'test-cannot-fail' });
    population(db, { startMs: NOW_MS - 6 * DAY, days: 5, prs: 15, blocks: 3, category: 'iron-law' });
    population(db, { startMs: NOW_MS - 6 * DAY, days: 5, prs: 5, blocks: 1, category: 'other' });
    population(db, { startMs: NOW_MS - 30 * DAY, days: 5, prs: 10, blocks: 10, category: 'scope-creep' }); // outside
    insLesson(db, { category: 'test-cannot-fail', number: 950, merged_at: ago(3) });
    insLesson(db, { category: 'iron-law', number: 951, merged_at: ago(60), status: 'not-working' });
    insLesson(db, { category: 'no-test', number: 952, merged_at: ago(60), status: 'superseded' });
  };

  await t.test('D1 the digest renders the overall and per-category rates of a real-shaped week', async () => {
    const { db, DB } = await openDb();
    digestFixture(db);
    const r = await digest(DB);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.window.days, 7);
    assert.equal(r.body.overall.reviewed, 40);
    assert.equal(r.body.overall.blocks, 10);
    assert.equal(r.body.overall.rate, 25);
    const by = Object.fromEntries(r.body.categories.map((c) => [c.id, c]));
    assert.equal(by['test-cannot-fail'].blocks, 6);
    assert.equal(by['test-cannot-fail'].rate, 15);
    assert.equal(by['test-cannot-fail'].lesson_status, 'measuring');
    assert.equal(by['iron-law'].rate, 7.5);
    assert.equal(by['iron-law'].lesson_status, 'not-working');
    assert.ok(by['iron-law'].name && by['iron-law'].name !== 'iron-law', 'the category name comes from block_categories');
    assert.equal(by['scope-creep'], undefined, 'outside the window');
    assert.equal(r.body.other_blocks, 1);
    assert.equal(r.body.lessons.added, 1);
    assert.equal(r.body.lessons.measuring, 1);
    assert.equal(r.body.lessons.not_working, 1);
    assert.equal(r.body.lessons.retired, 1);
    assert.equal(r.body.lessons.removing, 0);
  });

  await t.test('D1b a row with an open removal PR counts in `removing`, never in `retired`', async () => {
    const { db, DB } = await openDb();
    insLesson(db, { category: 'no-test', number: 953, merged_at: ago(60), status: 'working', removal_number: 9200 });
    insLesson(db, { category: 'no-test', number: 954, merged_at: ago(60), status: 'superseded', removal_number: 9201 });
    const r = await digest(DB);
    assert.equal(r.body.lessons.removing, 1);
    assert.equal(r.body.lessons.retired, 1);
  });

  await t.test('D2 uncovered excludes a category with a measuring lesson and `other`', async () => {
    const { db, DB } = await openDb();
    digestFixture(db);
    const r = await digest(DB);
    assert.deepEqual(r.body.uncovered.map((x) => x.id), ['iron-law']);
  });

  await t.test('D3 the list is at most lessons.list_limit rows, newest first, and says when it was cut', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lessons.list_limit', '3');
    for (let i = 0; i < 5; i++) insLesson(db, { category: 'test-cannot-fail', number: 960 + i, merged_at: ago(10 - i) });
    const r = await digest(DB);
    assert.equal(r.body.lessons.list.length, 3);
    assert.equal(r.body.lessons.list_truncated, true);
    assert.deepEqual(r.body.lessons.list.map((l) => l.number), [964, 963, 962]);
    assert.equal((await digest(DB, '?days=0')).status, 400);
  });

  await t.test('RT1 retention only counts the old judged rows; it never deletes a lessons row', async () => {
    const { db, DB } = await openDb();
    insLesson(db, { category: 'test-cannot-fail', number: 970, merged_at: ago(800), status: 'working' });
    insLesson(db, { category: 'test-cannot-fail', number: 971, merged_at: ago(800), status: 'measuring' });
    insLesson(db, { category: 'test-cannot-fail', number: 972, merged_at: ago(800), status: 'not-working' });
    insLesson(db, { category: 'test-cannot-fail', number: 973, merged_at: ago(10), status: 'working' });
    const r = await call(DB, '/api/lessons/retention', { method: 'POST', body: {} });
    assert.equal(r.status, 200);
    assert.equal(r.body.eligible, 1);
    assert.equal(r.body.removed, undefined);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lessons').get().n, 4);
    // The old delete switch, and a body that asks for a live run, delete nothing.
    setting(db, 'lessons.retention_dry_run', '0');
    const live = await call(DB, '/api/lessons/retention', { method: 'POST', body: { dry_run: false } });
    assert.equal(live.status, 200);
    assert.equal(live.body.eligible, 1);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lessons').get().n, 4);
  });

  // ── X: EXPLAIN QUERY PLAN at seeded volume (BH-6730) ───────────────────
  // 20 000 findings and 20 000 verdicts over 60 days, 500 lessons, then
  // ANALYZE. The SQL is the exact text the routes run (exported constants).
  const seedVolume = (db) => {
    const v = db.prepare("INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at) VALUES (?, ?, ?, ?, 'lead', ?)");
    const f = db.prepare(
      `INSERT INTO block_findings (verdict_id, n, repo, pr, head_sha, category, text, verdict_at, created_at, files)
       VALUES (?, 1, ?, ?, ?, ?, 'x', ?, ?, '[]')`);
    const cats = ['other', 'iron-law', 'test-cannot-fail', 'scope-creep'];
    const types = ['plan-lesson', 'builder-rule', 'check', 'harness-bug'];
    const sts = ['measuring', 'working', 'not-working', 'inconclusive', 'superseded'];
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const at = iso(NOW_MS - (i % 60) * DAY - i * 1000);
      const r = v.run(R, 100000 + (i % 5000), SHA, i % 3 ? 'MERGE' : 'BLOCK', at);
      f.run(Number(r.lastInsertRowid), R, 100000 + (i % 5000), SHA, cats[i % 4], at, at);
    }
    const l = db.prepare(
      `INSERT INTO lessons (category, change_type, kind, repo, number, source, merged_at, status, escalation_number, created_at, updated_at)
       VALUES (?, ?, 'pr', ?, ?, 'proposal', ?, ?, ?, ?, ?)`);
    for (let i = 0; i < 500; i++) {
      l.run(`cat-${i % 30}`, types[i % 4], R, 20000 + i, ago(i), sts[i % 5], i % 7 === 0 ? 30000 + i : null, ago(0), ago(0));
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
  };
  const plan = (db, sql, ...binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join('\n');
  // A bare `SCAN <table>` (no index) of a large table; `SCAN x USING [COVERING] INDEX` is an index walk.
  const bareScan = (p, ...tables) => p.split('\n').some((line) =>
    tables.some((tb) => new RegExp(`^SCAN ${tb}( |$)`).test(line.trim())) && !/ USING /.test(line));

  await t.test('X1 measure reads use idx_lessons_status, idx_block_findings_cat and idx_verdicts_created', async () => {
    const { db } = await openDb();
    seedVolume(db);
    const p1 = plan(db, MEASURING_SQL, 201);
    assert.match(p1, /idx_lessons_status/, p1);
    const p2 = plan(db, windowBlocksSql(2), ago(56), 'iron-law', 'test-cannot-fail', 50001);
    assert.match(p2, /idx_block_findings_cat/, p2);
    assert.ok(!bareScan(p2, 'block_findings'), p2);
    const p3 = plan(db, WINDOW_REVIEWED_SQL, ago(56), 50001);
    assert.match(p3, /idx_verdicts_created/, p3);
    assert.ok(!bareScan(p3, 'verdicts'), p3);
  });

  await t.test('X2 record and pending reads use their lessons indexes', async () => {
    const { db } = await openDb();
    seedVolume(db);
    const p0 = plan(db, RECORD_LOOKUP_SQL, 30007, R, 'pr');
    assert.match(p0, /idx_lessons_esc/, p0);
    assert.match(p0, /sqlite_autoindex_lessons_1/, p0);
    const p1 = plan(db, PENDING_ESCALATE_SQL);
    assert.match(p1, /idx_lessons_(status|esc)/, p1);
    const p2 = plan(db, PENDING_TYPE_SQL);
    assert.match(p2, /idx_lessons_type/, p2);
    const p3 = plan(db, PENDING_ESCALATED_SQL);
    assert.match(p3, /idx_lessons_esc/, p3);
    assert.ok(!bareScan(p0 + '\n' + p1 + '\n' + p2 + '\n' + p3, 'lessons', 'l', 'x'), [p0, p1, p2, p3].join('\n--\n'));
  });

  await t.test('X3 digest reads use idx_block_findings_*, idx_verdicts_created, idx_lessons_cat and idx_lessons_merged', async () => {
    const { db } = await openDb();
    seedVolume(db);
    const p1 = plan(db, DIGEST_CATEGORY_SQL, ago(7));
    assert.match(p1, /idx_block_findings_(at|cat)/, p1);
    assert.ok(!bareScan(p1, 'block_findings'), p1);
    const p2 = plan(db, DIGEST_OVERALL_SQL, ago(7));
    assert.match(p2, /idx_verdicts_created/, p2);
    const p3 = plan(db, DIGEST_STATUS_SQL, ago(7));
    assert.match(p3, /idx_lessons_cat/, p3);
    const p4 = plan(db, DIGEST_LIST_SQL, 101);
    assert.match(p4, /idx_lessons_merged/, p4);
    assert.ok(!bareScan(p2 + '\n' + p3 + '\n' + p4, 'verdicts', 'lessons'), [p2, p3, p4].join('\n--\n'));
  });

  await t.test('X4 the retention count uses idx_lessons_merged', async () => {
    const { db } = await openDb();
    seedVolume(db);
    const p = plan(db, RETENTION_COUNT_SQL, ago(730));
    assert.match(p, /idx_lessons_merged/, p);
    assert.ok(!bareScan(p, 'lessons'), p);
  });
});
