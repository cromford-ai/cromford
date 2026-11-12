// BH-9559 part A (BH-9580 tracer): human gates, driven through the REAL
// worker.fetch against the composed jobs schema (the node:sqlite D1 shim).
//
//   C1  upsert is idempotent on (repo, key, lane, question_fp): a re-ask with
//       other whitespace and case is the same row, reasked true, same deadline
//   C2  400 on no / blank default_answer, no recommended, 0 or 4 reasons; no
//       row written; no bearer is 401
//   C3  gate class: plan_blocked is defaultable; the irreversible reasons, a
//       wrong case, a near miss, empty and a row valued Defaultable are not
//   C4  a re-ask of an answered gate keeps status and answer
//   C5  EXPLAIN QUERY PLAN on 5,000 seeded rows uses each of the 4 indexes; the
//       retention id read is an index SEARCH on status, never a full SCAN
//   C6  retention: dry run moves nothing; live run archives an old resolved
//       row and keeps an old open row and a fresh resolved row
//   C7  deadline_at: +24h by default, +48h from the row, a body value is kept
//   C8  the seed rows: 4 kill flags 1, the knobs, 12 class rows
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const DAY = 86400e3;
const isoSec = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const call = (DB, body, { bearer = true } = {}) => worker.fetch(new Request('https://jobs.test/api/human-gates', {
  method: 'POST',
  headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
  body: JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
// Each case passes its own key, so no two cases share a row.
const ask = (key, over = {}) => ({
  repo: 'cromford', key, lane: 'plan', reason: 'plan_blocked',
  question: 'Ship the fixture option A?', recommended: 'yes', reasons: ['smaller diff', 'no migration'],
  default_answer: 'yes', ...over,
});
const rows = (db, key) => db.prepare('SELECT * FROM human_gates WHERE key=? ORDER BY id').all(key);

test('BH-9559 human gates', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('C1 a re-ask is an upsert, never a second row', async () => {
    const { DB, db } = await openDb();
    const r1 = await call(DB, ask('BH-9001'));
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    assert.equal(r1.body.reasked, false);
    assert.equal(r1.body.gate.status, 'open');
    assert.equal(r1.body.gate.gate_class, 'defaultable');
    assert.equal(r1.body.gate.asked_again_at, null);
    db.prepare('UPDATE human_gates SET created_at=? WHERE id=?').run('2026-11-01T00:00:00Z', r1.body.gate.id);
    const r2 = await call(DB, ask('BH-9001', { question: '  ship THE fixture\n option a?  ' }));
    assert.equal(r2.status, 200, JSON.stringify(r2.body));
    assert.equal(r2.body.reasked, true);
    assert.equal(r2.body.gate.id, r1.body.gate.id);
    assert.equal(r2.body.gate.deadline_at, r1.body.gate.deadline_at);
    assert.equal(r2.body.gate.created_at, '2026-11-01T00:00:00Z');
    assert.ok(r2.body.gate.asked_again_at);
    const all = rows(db, 'BH-9001');
    assert.equal(all.length, 1);
    assert.equal(all[0].question, 'Ship the fixture option A?');
    assert.deepEqual(JSON.parse(all[0].reasons_json), ['smaller diff', 'no migration']);
    assert.equal(all[0].question_fp.length, 16);
    // Another lane or another question is another row.
    assert.equal((await call(DB, ask('BH-9001', { lane: 'conductor' }))).status, 200);
    assert.equal((await call(DB, ask('BH-9001', { question: 'A different question?' }))).status, 200);
    assert.equal(rows(db, 'BH-9001').length, 3);
  });

  await t.test('C2 a body with no default, no recommended or bad reasons is 400 and writes no row', async () => {
    const { DB, db } = await openDb();
    const noDefault = ask('BH-9002'); delete noDefault.default_answer;
    const noRec = ask('BH-9002'); delete noRec.recommended;
    for (const [body, field] of [
      [noDefault, 'default_answer'],
      [ask('BH-9002', { default_answer: '   ' }), 'default_answer'],
      [noRec, 'recommended'],
      [ask('BH-9002', { recommended: '' }), 'recommended'],
      [ask('BH-9002', { question: ' ' }), 'question'],
      [ask('BH-9002', { reasons: [] }), 'reasons'],
      [ask('BH-9002', { reasons: ['a', 'b', 'c', 'd'] }), 'reasons'],
      [ask('BH-9002', { reasons: ['a', ' '] }), 'reasons'],
      [ask('BH-9002', { reasons: 'a' }), 'reasons'],
      [ask('BH-9002', { key: 'bh-9002' }), 'key'],
      [ask('BH-9002', { repo: 'a b' }), 'repo'],
      [ask('BH-9002', { lane: 'Plan' }), 'lane'],
      [ask('BH-9002', { deadline_at: 'tomorrow' }), 'deadline_at'],
    ]) {
      const r = await call(DB, body);
      assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
      assert.equal(r.body.error, field);
    }
    assert.equal(rows(db, 'BH-9002').length, 0);
    assert.equal((await call(DB, ask('BH-9002'), { bearer: false })).status, 401);
    assert.equal(rows(db, 'BH-9002').length, 0);
    // The edges that must pass: 1 and 3 reasons, a decompose child key.
    assert.equal((await call(DB, ask('BH-9002', { reasons: ['one'] }))).status, 200);
    assert.equal((await call(DB, ask('BH-9002', { reasons: ['a', 'b', 'c'], question: 'q3?' }))).status, 200);
    assert.equal((await call(DB, ask('BH-9002.1'))).status, 200);
  });

  await t.test('C3 an unknown reason is irreversible (fail-closed)', async () => {
    const { DB, db } = await openDb();
    const classOfReason = async (reason, i) => {
      const r = await call(DB, ask(`BH-93${String(i).padStart(2, '0')}`, { reason }));
      assert.equal(r.status, 200, `${reason}: ${JSON.stringify(r.body)}`);
      return r.body.gate.gate_class;
    };
    const cases = [
      ['plan_blocked', 'defaultable'], ['tightened', 'defaultable'], ['needs-human', 'defaultable'], ['parked', 'defaultable'],
      ['migration-gated', 'irreversible'], ['hotfix-migration-hold', 'irreversible'], ['provenance', 'irreversible'],
      ['security-allowlist', 'irreversible'], ['Migration-Gated', 'irreversible'], ['migration-gated-v2', 'irreversible'],
      ['', 'irreversible'], ['plan_blocked ', 'irreversible'], ['plan/blocked', 'irreversible'], ['never-seeded', 'irreversible'],
    ];
    for (const [i, [reason, want]] of cases.entries()) assert.equal(await classOfReason(reason, i), want, `reason ${JSON.stringify(reason)}`);
    db.prepare("UPDATE settings SET value='Defaultable' WHERE key='human_gate.class.parked'").run();
    assert.equal(await classOfReason('parked', 50), 'irreversible');
  });

  await t.test('C4 a re-ask of an answered gate keeps its status and answer', async () => {
    const { DB, db } = await openDb();
    const r1 = await call(DB, ask('BH-9004'));
    db.prepare("UPDATE human_gates SET status='answered', answer='no', answered_by='reply', resolved_at=? WHERE id=?")
      .run('2026-11-02T00:00:00Z', r1.body.gate.id);
    const r2 = await call(DB, ask('BH-9004', { default_answer: 'something else', recommended: 'maybe' }));
    assert.equal(r2.status, 200);
    assert.equal(r2.body.reasked, true);
    assert.equal(r2.body.gate.status, 'answered');
    const [row] = rows(db, 'BH-9004');
    assert.deepEqual([row.status, row.answer, row.answered_by, row.default_answer], ['answered', 'no', 'reply', 'yes']);
  });

  await t.test('C5 the hot reads use their indexes on 5,000 seeded rows', async () => {
    const { db } = await openDb();
    const now = Date.parse('2026-11-12T00:00:00Z');
    const st = ['open', 'answered', 'defaulted', 'expired-irreversible'];
    const ins = db.prepare(`INSERT INTO human_gates (repo, key, lane, reason, gate_class, question, question_fp, recommended,
      reasons_json, default_answer, deadline_at, review_at, status, created_at, resolved_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
    db.exec('BEGIN');
    for (let i = 0; i < 5000; i++) {
      const s = st[i % 4];
      ins.run(`repo-${i % 7}`, `BH-${i}`, 'plan', 'plan_blocked', i % 3 ? 'defaultable' : 'irreversible', `q${i}`,
        String(i).padStart(16, '0'), 'yes', '["r"]', 'yes', isoSec(now - i * 3600e3 + DAY), i % 5 ? null : isoSec(now + i * 60e3),
        s, isoSec(now - i * 3600e3), s === 'open' ? null : isoSec(now - i * 3600e3 + 60e3));
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const uses = (lines, idx) => assert.ok(lines.some((l) => l.includes(idx)), `${idx} not used: ${lines.join(' | ')}`);
    const noScan = (lines) => assert.deepEqual(lines.filter((l) => /^SCAN human_gates\b/.test(l) && !/USING/.test(l)), [], lines.join(' | '));
    for (const [q, idx, b] of [
      ["SELECT id FROM human_gates WHERE status='open' AND deadline_at < ?", 'idx_human_gates_open_deadline', [isoSec(now)]],
      ['SELECT id FROM human_gates WHERE status=? AND gate_class=? ORDER BY created_at LIMIT 50', 'idx_human_gates_open_created', ['open', 'defaultable']],
      ['SELECT id FROM human_gates WHERE repo=? AND key=? AND status=?', 'idx_human_gates_key', ['repo-1', 'BH-8', 'open']],
      ['SELECT id FROM human_gates WHERE status=? AND review_at < ?', 'idx_human_gates_review', ['open', isoSec(now)]],
    ]) { const l = plan(q, ...b); uses(l, idx); noScan(l); }
    const { SQL } = await import('../src/routes/human-gates.js');
    noScan(plan(SQL.upsert, 'r', 'BH-1', 'plan', 'x', 'defaultable', 'q', 'fp', 'y', '[]', 'y', isoSec(now), isoSec(now)));
    const { default: RULES } = await import('../src/routes/retention.d/bh-9559-human-gates.js');
    for (const r of RULES) {
      const l = plan(r.ids, isoSec(now - 90 * DAY), 500);
      noScan(l);
      assert.ok(l.some((x) => /^SEARCH human_gates USING (COVERING )?INDEX idx_human_gates_\w+ \(status=\?\)/.test(x)), l.join(' | '));
      noScan(plan(r.del, '[1]'));
      noScan(plan(r.rollup, '[1]'));
    }
  });

  await t.test('C6 retention archives an old resolved row and keeps open and fresh rows', async () => {
    const { DB, db } = await openDb();
    const old = isoSec(Date.now() - 100 * DAY);  // determinism: ok the retention route cuts at its own clock, so the seed is relative to it
    const fresh = isoSec(Date.now() - 1 * DAY);  // determinism: ok same anchor as above
    const mk = async (key) => (await call(DB, ask(key))).body.gate.id;
    const gone = await mk('BH-9601'); const open = await mk('BH-9602'); const recent = await mk('BH-9603');
    db.prepare("UPDATE human_gates SET status='defaulted', answer='yes', answered_by='default', created_at=?, resolved_at=? WHERE id=?").run(old, old, gone);
    db.prepare('UPDATE human_gates SET created_at=? WHERE id=?').run(old, open);
    db.prepare("UPDATE human_gates SET status='answered', answer='no', answered_by='reply', created_at=?, resolved_at=? WHERE id=?").run(old, fresh, recent);
    const run = () => worker.fetch(new Request('https://jobs.test/api/retention/run', {
      method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: '{}',
    }), { DB, HARNESS_SECRET: SECRET }).then((r) => r.json());
    const dry = await run();
    assert.equal(dry.dry_run, true);
    assert.equal(dry.rules.find((r) => r.rule === 'human_gates.archive').counted, 1);
    assert.equal(db.prepare('SELECT count(*) AS n FROM human_gates').get().n, 3);
    assert.equal(db.prepare('SELECT count(*) AS n FROM human_gates_archive').get().n, 0);
    db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
    const live = await run();
    const rule = live.rules.find((r) => r.rule === 'human_gates.archive');
    assert.equal(rule.error, null);
    assert.equal(rule.removed, 1);
    assert.deepEqual(db.prepare('SELECT id FROM human_gates ORDER BY id').all().map((r) => r.id), [open, recent]);
    const arch = db.prepare('SELECT * FROM human_gates_archive').all();
    assert.equal(arch.length, 1);
    assert.deepEqual([arch[0].id, arch[0].key, arch[0].status, arch[0].answer], [gone, 'BH-9601', 'defaulted', 'yes']);
    assert.ok(arch[0].archived_at);
  });

  await t.test('C7 deadline_at is computed server side when absent', async () => {
    const { DB, db } = await openDb();
    const hoursOf = (g) => (Date.parse(g.deadline_at) - Date.parse(g.created_at)) / 3600e3;
    const r24 = await call(DB, ask('BH-9701'));
    assert.equal(hoursOf(r24.body.gate), 24);
    db.prepare("UPDATE settings SET value='48' WHERE key='human_gate.deadline_hours'").run();
    const r48 = await call(DB, ask('BH-9702'));
    assert.equal(hoursOf(r48.body.gate), 48);
    db.prepare("UPDATE settings SET value='nope' WHERE key='human_gate.deadline_hours'").run();
    assert.equal(hoursOf((await call(DB, ask('BH-9703'))).body.gate), 24);
    const given = await call(DB, ask('BH-9704', { deadline_at: '2027-01-02T03:04:05.678Z' }));
    assert.equal(given.body.gate.deadline_at, '2027-01-02T03:04:05Z');
    assert.equal(rows(db, 'BH-9704')[0].deadline_at, '2027-01-02T03:04:05Z');
  });

  await t.test('C8 the seed rows', async () => {
    const { db } = await openDb();
    const val = (k) => (db.prepare('SELECT value FROM settings WHERE key=?').get(k) || {}).value;
    for (const f of ['format', 'default', 'digest', 'reask']) assert.equal(val(`human_gate.${f}.enabled`), '1', f);
    assert.deepEqual(['deadline_hours', 'hold_review_days', 'digest_hour_utc', 'retention_days'].map((k) => val(`human_gate.${k}`)), ['24', '7', '7', '90']);
    const cls = db.prepare("SELECT key, value FROM settings WHERE key LIKE 'human_gate.class.%' ORDER BY key").all();
    assert.equal(cls.length, 12);
    assert.deepEqual(cls.filter((r) => r.value === 'irreversible').map((r) => r.key.slice(17)).sort(),
      ['hotfix-migration-hold', 'migration-gated', 'provenance', 'security-allowlist']);
    assert.ok(cls.every((r) => r.value === 'irreversible' || r.value === 'defaultable'));
  });
});
