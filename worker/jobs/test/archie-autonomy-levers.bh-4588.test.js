// BH-4588 (BH-4574.6): manager authority. The guardrail levers are their own
// decision classes, seeded delegated, so a decision on one is mode auto (Archie
// acts and reports after). Driven through the REAL worker.fetch against the
// REAL composed schema (the node:sqlite D1 shim), as archie-autonomy.bh-4067
// does. Pinned here: the 11 lever seeds (L1), auto vs ask on a lever (L2), the
// protected classes still refuse delegation and the CHECK still holds (L3), an
// overrule still reverts a lever class (L4), and no lever slug is protected by
// name (W-AUTH).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { isProtectedSlug } from '../src/routes/archie-autonomy.js';

const SECRET = 'test-secret';
const call = (DB, path, body) => {
  const req = new Request(`https://jobs.test${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const LEVERS = ['lever-alert-ack', 'lever-dequeue', 'lever-enqueue', 'lever-fix-round', 'lever-hold-label',
  'lever-iron-law-ack', 'lever-pause-row', 'lever-rebase', 'lever-rebuild', 'lever-re-review', 'lever-ticket'];
const due = (n) => `2026-10-${String(10 + n).padStart(2, '0')}T07:00:00Z`;
const esc = (n, over = {}) => ({
  escalation_key: `check:1:${due(n)}`, initiative_id: 1, class: 'lever-enqueue', sensitive: false,
  recommendation: 'Enqueue #88 on project-4 into the merge queue.', ...over,
});

test('BH-4588 manager authority: lever classes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('L1 11 lever classes, seeded delegated and delegable', async () => {
    const { db } = await openDb();
    const rows = db.prepare("SELECT * FROM archie_classes WHERE class LIKE 'lever-%' ORDER BY class").all();
    assert.deepEqual(rows.map((r) => r.class).sort(), [...LEVERS].sort());
    for (const r of rows) {
      assert.equal(r.state, 'delegated', r.class);
      assert.equal(r.never_delegable, 0, r.class);
      assert.equal(r.streak, 0, r.class);
    }
  });

  await t.test('L2 a lever decision is auto when not sensitive, ask when sensitive', async () => {
    const { DB, db } = await openDb();
    const a = await call(DB, '/api/archie/decisions', esc(1));
    assert.equal(a.status, 201, JSON.stringify(a.body));
    assert.equal(a.body.decision.class, 'lever-enqueue');
    assert.equal(a.body.decision.mode, 'auto');
    assert.equal(a.body.class_state.protected, false);
    const s = await call(DB, '/api/archie/decisions', esc(2, { sensitive: true, recommendation: 'Merge #88 now, it is green.' }));
    assert.equal(s.status, 201);
    assert.equal(s.body.decision.mode, 'ask', 'a hard limit is never auto, even on a lever class');
    const ev = db.prepare("SELECT * FROM initiative_events WHERE kind='reply' AND actor='archie'").all();
    assert.equal(ev.length, 1, 'only the auto decision acted');
  });

  await t.test('L3 merge, production and deploy stay never delegable', async () => {
    const { DB, db } = await openDb();
    for (const c of ['merge', 'production', 'deploy']) {
      db.prepare('UPDATE archie_classes SET streak=99 WHERE class=?').run(c);
      const r = await call(DB, '/api/archie/classes/delegation', { class: c, decision: 'delegate', min_streak: 5, actor: 'chat' });
      assert.equal(r.status, 409, c);
      assert.equal(r.body.error, 'never_delegable', c);
      assert.equal(db.prepare('SELECT state FROM archie_classes WHERE class=?').get(c).state, 'ask_first', c);
    }
    assert.throws(() => db.prepare("UPDATE archie_classes SET never_delegable=0 WHERE class='merge'").run(), /CHECK/);
  });

  await t.test('L4 an overrule on a lever decision reverts the class to ask_first', async () => {
    const { DB, db } = await openDb();
    const a = await call(DB, '/api/archie/decisions', esc(3));
    assert.equal(a.body.decision.mode, 'auto');
    const c = await call(DB, '/api/archie/decisions/choice', { initiative_id: 1, choice: 'change', choice_key: 'reply:1:m1' });
    assert.equal(c.status, 200, JSON.stringify(c.body));
    assert.equal(c.body.reverted, true);
    const row = db.prepare("SELECT * FROM archie_classes WHERE class='lever-enqueue'").get();
    assert.equal(row.state, 'ask_first');
    assert.equal(row.streak, 0);
    assert.ok(row.reverted_at);
    const next = await call(DB, '/api/archie/decisions', esc(4));
    assert.equal(next.body.decision.mode, 'ask', 'after the overrule Archie asks first again');
  });

  await t.test('W-AUTH no lever slug is protected by name; the hard-limit slugs are', () => {
    for (const c of LEVERS) assert.equal(isProtectedSlug(c), false, c);
    for (const c of ['merge', 'deploy', 'production', 'spend', 'client-board', 'unclassified']) {
      assert.equal(isProtectedSlug(c), true, c);
    }
  });
});
