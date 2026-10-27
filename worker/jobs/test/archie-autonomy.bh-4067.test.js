// BH-4067 (BH-3966.6): Archie's earned autonomy, driven through the REAL
// worker.fetch against the REAL schema.sql (the node:sqlite D1 shim), the way
// initiatives.bh-4062.test.js does it. Pinned here: the class seeds and the
// CHECK that keeps a protected class protected, the decision ledger's
// payload-bound idempotency, the auto mode (only for a delegated, unprotected,
// non-sensitive class) and the act it writes once, the choice that counts once,
// and the delegation command's refusals.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const call = (DB, path, { method = 'POST', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const decide = (DB, body) => call(DB, '/api/archie/decisions', { body });
const choose = (DB, body) => call(DB, '/api/archie/decisions/choice', { body });
const delegation = (DB, body) => call(DB, '/api/archie/classes/delegation', { body });

const cls = (db, c) => db.prepare('SELECT * FROM archie_classes WHERE class=?').get(c);
const setClass = (db, c, state, streak) =>
  db.prepare('UPDATE archie_classes SET state=?, streak=? WHERE class=?').run(state, streak, c);
const ini = (db) => db.prepare('SELECT * FROM initiatives WHERE id=1').get();
const events = (db) => db.prepare("SELECT * FROM initiative_events WHERE kind='reply' ORDER BY id").all();
const due = (n) => `2026-10-${String(5 + n).padStart(2, '0')}T07:00:00Z`;
const esc = (n, over = {}) => ({
  escalation_key: `check:1:${due(n)}`, initiative_id: 1, class: 'watch-cadence', sensitive: false,
  recommendation: 'Check weekly instead of daily.', ...over,
});
const agree = (DB, n) => choose(DB, { initiative_id: 1, choice: 'approve', choice_key: `reply:1:m${n}` });

test('BH-4067 earned autonomy', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('A1 seeds: 11 classes, six protected, all ask_first; the settings row reads 5', async () => {
    const { db } = await openDb();
    // BH-4588 adds the lever-* classes, seeded delegated; its own suite pins them.
    const rows = db.prepare("SELECT * FROM archie_classes WHERE class NOT LIKE 'lever-%' ORDER BY class").all();
    assert.equal(rows.length, 11);
    assert.deepEqual(rows.filter((r) => r.never_delegable === 1).map((r) => r.class).sort(),
      ['client-board', 'deploy', 'merge', 'production', 'spend', 'unclassified']);
    assert.deepEqual(rows.filter((r) => r.never_delegable === 0).map((r) => r.class).sort(),
      ['hold-resume', 'ticket-file', 'watch-cadence', 'watch-continue', 'watch-stop']);
    assert.ok(rows.every((r) => r.state === 'ask_first' && r.streak === 0));
    const s = db.prepare("SELECT value FROM settings WHERE key='lane.archie.archie_delegate_after'").get();
    assert.equal(s.value, '5');
    assert.throws(() => db.prepare("UPDATE archie_classes SET never_delegable=0 WHERE class='merge'").run(), /CHECK/);
    assert.throws(() => db.prepare("UPDATE archie_classes SET state='delegated' WHERE class='deploy'").run(), /CHECK/);
    assert.throws(() => db.prepare("UPDATE archie_classes SET state='yes' WHERE class='watch-cadence'").run(), /CHECK/);
    db.prepare('SELECT count(*) AS n FROM archie_decisions').get();
  });

  await t.test('A2 every route is bearer-gated', async () => {
    const { DB } = await openDb();
    for (const p of ['/api/archie/decisions', '/api/archie/decisions/choice', '/api/archie/classes/delegation']) {
      assert.equal((await call(DB, p, { body: {}, secret: null })).status, 401, p);
    }
  });

  await t.test('A3 decisions: junk is a 400 naming the field, and writes nothing', async () => {
    const { DB, db } = await openDb();
    for (const [over, field] of [
      [{ escalation_key: 'check:2:2026-10-06T07:00:00Z' }, 'escalation_key'],
      [{ escalation_key: 'check:1:tomorrow' }, 'escalation_key'],
      [{ escalation_key: 'reply:1:x' }, 'escalation_key'],
      [{ initiative_id: 0 }, 'initiative_id'],
      [{ class: '../x' }, 'class'], [{ class: 7 }, 'class'],
      [{ sensitive: 'no' }, 'sensitive'], [{ sensitive: undefined }, 'sensitive'],
      [{ recommendation: '' }, 'recommendation'], [{ recommendation: 'x'.repeat(4001) }, 'recommendation'],
    ]) {
      const r = await decide(DB, esc(1, over));
      assert.equal(r.status, 400, JSON.stringify(over));
      assert.equal(r.body.error, field);
    }
    assert.equal(db.prepare('SELECT count(*) AS n FROM archie_decisions').get().n, 0);
    const missing = await decide(DB, esc(1, { escalation_key: 'check:99:2026-10-06T07:00:00Z', initiative_id: 99 }));
    assert.equal(missing.status, 404);
  });

  await t.test('A4 decisions records class, recommendation, mode ask; replay 200, different payload 409', async () => {
    const { DB, db } = await openDb();
    const r = await decide(DB, esc(1, { class: '  Watch-Cadence ' }));
    assert.equal(r.status, 201, JSON.stringify(r.body));
    assert.equal(r.body.decision.class, 'watch-cadence');
    assert.equal(r.body.decision.mode, 'ask');
    assert.equal(r.body.decision.recommendation, 'Check weekly instead of daily.');
    assert.equal(r.body.decision.choice, null);
    assert.equal(r.body.class_state.state, 'ask_first');
    const again = await decide(DB, esc(1));
    assert.equal(again.status, 200);
    assert.equal(again.body.existing, true);
    const diff = await decide(DB, esc(1, { recommendation: 'Something else.' }));
    assert.equal(diff.status, 409);
    assert.equal(diff.body.decision.recommendation, 'Check weekly instead of daily.', 'the 409 carries the stored row');
    assert.equal(db.prepare('SELECT count(*) AS n FROM archie_decisions').get().n, 1);
    const unknown = await decide(DB, esc(2, { class: 'deploy-checks' }));
    assert.equal(unknown.body.decision.class, 'unclassified', 'an unknown class is stored unclassified');
  });

  await t.test('A5 auto only when delegated AND unprotected AND not sensitive; the act is written once', async () => {
    const { DB, db } = await openDb();
    setClass(db, 'watch-cadence', 'delegated', 5);
    const s = await decide(DB, esc(1, { sensitive: true, recommendation: 'Merge #4120 now.' }));
    assert.equal(s.body.decision.mode, 'ask', 'sensitive is never auto');
    assert.equal(events(db).length, 0);
    const a = await decide(DB, esc(2));
    assert.equal(a.status, 201);
    assert.equal(a.body.decision.mode, 'auto');
    assert.equal(a.body.decision.auto_choice, 'approve');
    let ev = events(db);
    assert.equal(ev.length, 1);
    assert.match(ev[0].dedupe_key, /^reply:1:auto-[0-9a-f]{16}$/);
    assert.equal(ev[0].status, 'approve');
    assert.equal(ev[0].actor, 'archie');
    assert.equal(ini(db).last_decision, 'approve');
    const replay = await decide(DB, esc(2));
    assert.equal(replay.status, 200);
    assert.equal(replay.body.decision.mode, 'auto');
    ev = events(db);
    assert.equal(ev.length, 1, 'a replay never acts twice');
    // A delegated class whose name the protected regex catches is never auto,
    // whatever its column says.
    db.prepare("INSERT INTO archie_classes (class, never_delegable, state, streak, updated_at) VALUES ('deploy-checks',0,'delegated',9,'t')").run();
    const p = await decide(DB, esc(3, { class: 'deploy-checks' }));
    assert.equal(p.body.decision.class, 'deploy-checks');
    assert.equal(p.body.decision.mode, 'ask');
    assert.equal(p.body.class_state.protected, true);
    // Not delegated: ask.
    setClass(db, 'watch-cadence', 'ask_first', 5);
    assert.equal((await decide(DB, esc(4))).body.decision.mode, 'ask');
    assert.equal(events(db).length, 1);
  });

  await t.test('A6 choice: agreement increments, set once, a second key does not count', async () => {
    const { DB, db } = await openDb();
    const none = await agree(DB, 0);
    assert.equal(none.status, 200);
    assert.equal(none.body.counted, false, 'no escalation, nothing counted');
    for (let n = 1; n <= 3; n += 1) {
      await decide(DB, esc(n));
      const c = await agree(DB, n);
      assert.equal(c.status, 200, JSON.stringify(c.body));
      assert.equal(c.body.counted, true);
      assert.equal(c.body.streak, n);
      assert.equal(c.body.class, 'watch-cadence');
    }
    const replay = await agree(DB, 3);
    assert.equal(replay.body.streak, 3, 'the same key replays, no second count');
    const other = await agree(DB, 33);
    assert.equal(other.body.counted, false, 'the newest row is already answered');
    assert.equal(cls(db, 'watch-cadence').streak, 3);
    const row = db.prepare('SELECT * FROM archie_decisions ORDER BY id DESC LIMIT 1').get();
    assert.equal(row.choice, 'approve');
    assert.equal(row.choice_key, 'reply:1:m3');
    assert.equal(row.counted, 1);
    for (const [over, field] of [[{ choice: 'yes' }, 'choice'], [{ choice_key: 'reply:2:x' }, 'choice_key'], [{ initiative_id: -1 }, 'initiative_id']]) {
      const r = await choose(DB, { initiative_id: 1, choice: 'approve', choice_key: 'reply:1:z', ...over });
      assert.equal(r.status, 400);
      assert.equal(r.body.error, field);
    }
  });

  await t.test('A7 one overrule resets the streak and reverts a delegated class', async () => {
    const { DB, db } = await openDb();
    setClass(db, 'watch-cadence', 'delegated', 6);
    await decide(DB, esc(1));
    const c = await choose(DB, { initiative_id: 1, choice: 'change', choice_key: 'reply:1:c1' });
    assert.equal(c.body.reverted, true);
    assert.equal(c.body.state, 'ask_first');
    assert.equal(c.body.streak, 0);
    assert.equal(cls(db, 'watch-cadence').state, 'ask_first');
    assert.ok(cls(db, 'watch-cadence').reverted_at);
    // The other overrule word does the same.
    setClass(db, 'watch-cadence', 'delegated', 6);
    await decide(DB, esc(2));
    const d = await choose(DB, { initiative_id: 1, choice: 'drop', choice_key: 'reply:1:d1' });
    assert.equal(d.body.reverted, true);
    assert.equal(cls(db, 'watch-cadence').state, 'ask_first');
  });

  await t.test('A8 a protected or sensitive escalation never counts, and never sets delegated', async () => {
    const { DB, db } = await openDb();
    setClass(db, 'merge', 'ask_first', 9);
    await decide(DB, esc(1, { class: 'merge' }));
    const m = await agree(DB, 1);
    assert.equal(m.body.counted, false);
    assert.equal(m.body.protected, true);
    assert.equal(cls(db, 'merge').streak, 9);
    await decide(DB, esc(2, { sensitive: true }));
    const s = await agree(DB, 2);
    assert.equal(s.body.counted, false);
    assert.equal(cls(db, 'watch-cadence').streak, 0);
    // R6: nothing but the delegation route ever writes delegated.
    setClass(db, 'watch-cadence', 'ask_first', 99);
    await decide(DB, esc(3));
    await agree(DB, 3);
    assert.equal(cls(db, 'watch-cadence').state, 'ask_first');
  });

  await t.test('A9 delegation: never_delegable 409, not_earned 409, unknown 404, ask_first resets', async () => {
    const { DB, db } = await openDb();
    const base = { decision: 'delegate', min_streak: 5, actor: 'chat' };
    const m = await delegation(DB, { ...base, class: 'Merge' });
    assert.equal(m.status, 409);
    assert.equal(m.body.error, 'never_delegable');
    assert.equal(cls(db, 'merge').state, 'ask_first');
    db.prepare("INSERT INTO archie_classes (class, never_delegable, state, streak, updated_at) VALUES ('release-notes',0,'ask_first',9,'t')").run();
    assert.equal((await delegation(DB, { ...base, class: 'release-notes' })).body.error, 'never_delegable');
    setClass(db, 'watch-cadence', 'ask_first', 4);
    const ne = await delegation(DB, { ...base, class: 'watch-cadence' });
    assert.equal(ne.status, 409);
    assert.equal(ne.body.error, 'not_earned');
    assert.equal(ne.body.streak, 4);
    assert.equal((await delegation(DB, { ...base, class: 'no-such' })).status, 404);
    assert.equal((await delegation(DB, { ...base, class: 'watch-cadence', actor: 'archie' })).status, 403);
    setClass(db, 'watch-cadence', 'ask_first', 5);
    const ok = await delegation(DB, { ...base, class: 'watch-cadence' });
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(ok.body.class_state.state, 'delegated');
    assert.ok(cls(db, 'watch-cadence').delegated_at);
    const again = await delegation(DB, { ...base, class: 'watch-cadence' });
    assert.equal(again.status, 200);
    assert.equal(again.body.existing, true);
    const af = await delegation(DB, { decision: 'ask_first', class: 'watch-cadence', actor: 'chat' });
    assert.equal(af.status, 200);
    assert.equal(cls(db, 'watch-cadence').state, 'ask_first');
    assert.equal(cls(db, 'watch-cadence').streak, 0);
    for (const [over, field] of [[{ class: '../x' }, 'class'], [{ decision: 'maybe' }, 'decision'],
      [{ min_streak: 0 }, 'min_streak'], [{ actor: '' }, 'actor']]) {
      const r = await delegation(DB, { ...base, class: 'watch-cadence', ...over });
      assert.equal(r.status, 400, JSON.stringify(over));
      assert.equal(r.body.error, field);
    }
  });
});
