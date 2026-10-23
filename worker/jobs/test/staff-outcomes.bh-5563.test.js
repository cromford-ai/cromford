// BH-5563 (BH-5556.6): the staff learning loop, driven through the REAL
// worker.fetch against the composed schema (the node:sqlite D1 shim), the way
// staff-record.bh-5561.test.js does it. Every case claims a finding through
// POST /api/staff/findings/claim, records it filed through
// POST /api/staff/findings/record, and then posts outcomes to
// POST /api/staff/outcomes. Pinned here:
//   S0       the fragment: staff_outcomes and staff_promotions, the 2 settings seeds
//   F1       classSlug / familyFingerprint: one class identity, one family key
//   O1-O3    an outcome moves a filed finding and its staff decision exactly once;
//            refusals write nothing
//   P1-P2    precision per agent and per class with agent-core precision();
//            no outcome is null, never 0
//   D1-D5    one overrule drops autonomy one level (floor automation); a replay
//            never demotes twice; an overrule voids a pending promotion; a lost
//            race leaves the level as it is
//   PR1-PR4  N agreements in a row make ONE pending promotion proposal; a human
//            applies it; the outcome route never raises a level
//   N1-N8    K same-family noise closures make ONE pending suppression; pending
//            never blocks a claim; a human approve does; an agent approver is 403;
//            a decline needs K new closures before the next proposal
//   C1       a protected class gets never_delegable = 1
//   Q1-Q2    the pending list and its cursor (E1 empty ledger, L1 limit 0 and 201 are 400)
//   RT1      is N4-N5 (claim class "Cost Row", approve, claim "cost row " is 409); S1 is N8
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { classSlug, familyFingerprint } from '../src/lib/staff-family.js';

const SECRET = 'test-secret';
const call = (DB, method, path, body) => {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const post = (DB, path, body) => call(DB, 'POST', path, body);
const get = (DB, path) => call(DB, 'GET', path);

const issue = (n) => `https://github.com/example-org/cromford/issues/${n}`;
let seq = 0;
// Claim one item and record it filed through the real routes.
const fileOne = async (DB, { agent = 'watchman', cls = 'leak', kind = 'alert' } = {}) => {
  seq += 1;
  const c = await post(DB, '/api/staff/findings/claim', {
    agent, item: { id: `fixture-item-${seq}` }, title: `Fixture finding ${seq}`, class: cls,
    source: { kind, url: `https://example.com/alerts/fixture-${seq}`, labels: ['ops'] },
    observedAt: '2026-10-14T02:00:00Z',
  });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  const fp = c.body.fingerprint;
  const url = issue(1000 + seq);
  const r = await post(DB, '/api/staff/findings/record', {
    agent, fingerprint: fp, outcome: 'filed', mode: 'ask', ticket_url: url, class: cls,
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { fp, url, agent };
};
const outcome = (DB, f, word) => post(DB, '/api/staff/outcomes', { agent: f.agent, fingerprint: f.fp, outcome: word, ticket_url: f.url });
const resolve = async (DB, word, opts) => {
  const f = await fileOne(DB, opts);
  const r = await outcome(DB, f, word);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { ...f, res: r.body };
};
const claimNew = (DB, cls, agent = 'watchman') => {
  seq += 1;
  return post(DB, '/api/staff/findings/claim', {
    agent, item: { id: `fixture-item-${seq}` }, title: `Fixture finding ${seq}`, class: cls,
    source: { kind: 'alert', url: `https://example.com/alerts/fixture-${seq}`, labels: [] },
    observedAt: '2026-10-14T02:00:00Z',
  });
};
const level = (db, a = 'watchman') => db.prepare('SELECT autonomy FROM staff_agents WHERE name=?').get(a).autonomy;
const setAgent = (db, a, autonomy, cap = 'augmentation') =>
  db.prepare('UPDATE staff_agents SET cap=?, autonomy=? WHERE name=?').run(cap, autonomy, a);
const setSetting = (db, key, value) =>
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','test','2026-10-14T00:00:00Z')
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, value);
const promotions = (db, a = 'watchman') => db.prepare('SELECT * FROM staff_promotions WHERE agent=? ORDER BY id').all(a);
const sups = (db, fam) => db.prepare('SELECT * FROM staff_suppressions WHERE fingerprint=? ORDER BY id').all(fam);
const fam = (cls, a = 'watchman') => familyFingerprint(a, classSlug(cls));

test('BH-5563 staff learning loop', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('S0 the fragment: empty staff_outcomes, staff_promotions, the 2 settings seeds', async () => {
    const { db } = await openDb();
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_outcomes').get().n, 0);
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_promotions').get().n, 0);
    const s = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
    assert.equal(s('staff.noise_suppress_after'), '3');
    assert.equal(s('staff.noise_suppress_days'), '30');
  });

  await t.test('F1 classSlug and familyFingerprint', () => {
    assert.equal(classSlug(' Cost Row '), 'cost-row');
    assert.equal(classSlug('cost row '), 'cost-row');
    assert.equal(classSlug('cost_row'), 'cost-row');
    assert.equal(classSlug('!!'), 'unclassified');
    assert.equal(classSlug(''), 'unclassified');
    assert.equal(classSlug(null), 'unclassified');
    assert.equal(classSlug('9lives'), 'unclassified');
    assert.match(fam('leak'), /^[0-9a-f]{64}$/);
    assert.equal(fam('Leak '), fam('leak'));
    assert.notEqual(fam('leak', 'watchman'), fam('leak', 'inspector'));
    assert.notEqual(fam('leak'), fam('cost-row'));
  });

  await t.test('O1 merged: the finding is merged, the decision approve and counted; a replay writes nothing', async () => {
    const { DB, db } = await openDb();
    const f = await fileOne(DB);
    const r = await outcome(DB, f, 'merged');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.outcome, 'merged');
    assert.equal(r.body.verdict, 'agree');
    assert.equal(db.prepare('SELECT status FROM staff_findings WHERE fingerprint=?').get(f.fp).status, 'merged');
    const d = db.prepare('SELECT choice, counted FROM staff_decisions WHERE escalation_key=?').get(`staff:${f.fp}`);
    assert.equal(d.choice, 'approve');
    assert.equal(d.counted, 1);
    const o = db.prepare('SELECT * FROM staff_outcomes WHERE fingerprint=?').get(f.fp);
    assert.equal(o.applied, 1);
    assert.equal(o.class, 'leak');
    const again = await outcome(DB, f, 'merged');
    assert.equal(again.status, 200);
    assert.equal(again.body.existing, true);
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_outcomes').get().n, 1);
    const other = await outcome(DB, f, 'rejected');
    assert.equal(other.status, 409);
    assert.equal(other.body.error, 'outcome_conflict');
    assert.equal(db.prepare('SELECT status FROM staff_findings WHERE fingerprint=?').get(f.fp).status, 'merged');
  });

  await t.test('O2 rejected and noise: the decision is change; the finding leaves the open list', async () => {
    const { DB, db } = await openDb();
    const a = await resolve(DB, 'rejected');
    const b = await resolve(DB, 'noise');
    assert.equal(a.res.verdict, 'overrule');
    assert.equal(b.res.verdict, 'overrule');
    for (const f of [a, b]) {
      assert.equal(db.prepare('SELECT choice FROM staff_decisions WHERE escalation_key=?').get(`staff:${f.fp}`).choice, 'change');
    }
    assert.equal(db.prepare('SELECT status FROM staff_findings WHERE fingerprint=?').get(b.fp).status, 'noise');
  });

  await t.test('O3 refusals write nothing: bad body, unknown, wrong agent, not filed, ticket mismatch', async () => {
    const { DB, db } = await openDb();
    const f = await fileOne(DB);
    const bodyOf = (x) => ({ agent: f.agent, fingerprint: f.fp, outcome: 'merged', ticket_url: f.url, ...x });
    for (const [x, field] of [[{ outcome: 'closed' }, 'outcome'], [{ fingerprint: 'abc' }, 'fingerprint'],
      [{ agent: 'Bad Name' }, 'agent'], [{ ticket_url: 'https://github.com/a/b/pull/7' }, 'ticket_url']]) {
      const r = await post(DB, '/api/staff/outcomes', bodyOf(x));
      assert.equal(r.status, 400, JSON.stringify(x));
      assert.equal(r.body.error, field);
    }
    const unknown = await post(DB, '/api/staff/outcomes', bodyOf({ fingerprint: 'a'.repeat(64) }));
    assert.equal(unknown.status, 404);
    const wrong = await post(DB, '/api/staff/outcomes', bodyOf({ agent: 'inspector' }));
    assert.equal(wrong.status, 409);
    assert.equal(wrong.body.error, 'wrong_agent');
    const mismatch = await post(DB, '/api/staff/outcomes', bodyOf({ ticket_url: issue(1) }));
    assert.equal(mismatch.status, 409);
    assert.equal(mismatch.body.error, 'ticket_mismatch');
    const c = await claimNew(DB, 'leak');
    const notFiled = await post(DB, '/api/staff/outcomes', bodyOf({ fingerprint: c.body.fingerprint }));
    assert.equal(notFiled.status, 409);
    assert.equal(notFiled.body.error, 'not_filed');
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_outcomes').get().n, 0);
    assert.equal(db.prepare('SELECT status FROM staff_findings WHERE fingerprint=?').get(f.fp).status, 'filed');
  });

  await t.test('P1-P2 precision per agent and per class; no outcome is null; unknown agent 404', async () => {
    const { DB } = await openDb();
    for (const w of ['merged', 'merged', 'merged', 'rejected']) await resolve(DB, w, { cls: 'Cost Row' });
    await resolve(DB, 'noise', { cls: 'leak' });
    const r = await get(DB, '/api/staff/precision?agent=watchman');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const w = r.body.agents.find((a) => a.agent === 'watchman');
    assert.equal(w.precision, 0.6);
    assert.equal(w.agree, 3);
    assert.equal(w.overrule, 2);
    assert.equal(w.by_class.find((c) => c.class === 'cost-row').precision, 0.75);
    assert.equal(w.by_class.find((c) => c.class === 'leak').precision, 0);
    const all = await get(DB, '/api/staff/precision');
    assert.equal(all.status, 200);
    const i = all.body.agents.find((a) => a.agent === 'inspector');
    assert.equal(i.precision, null);
    assert.deepEqual(i.by_class, []);
    assert.equal((await get(DB, '/api/staff/precision?agent=nobody-here')).status, 404);
    assert.equal((await get(DB, '/api/staff/precision?agent=Bad%20Name')).status, 400);
  });

  await t.test('D1 an overrule at augmentation demotes one level to automation', async () => {
    const { DB, db } = await openDb();
    setAgent(db, 'watchman', 'augmentation');
    const f = await resolve(DB, 'rejected');
    assert.equal(level(db), 'automation');
    assert.equal(f.res.autonomy.from, 'augmentation');
    assert.equal(f.res.autonomy.to, 'automation');
    assert.equal(f.res.autonomy.demoted, true);
    assert.match(db.prepare('SELECT note FROM staff_agents WHERE name=?').get('watchman').note, /^demoted by outcome [0-9a-f]{12} \(rejected\)$/);
  });

  await t.test('D2 an overrule at automation stays at automation (floor); merged never demotes', async () => {
    const { DB, db } = await openDb();
    const f = await resolve(DB, 'noise');
    assert.equal(level(db), 'automation');
    assert.equal(f.res.autonomy.demoted, false);
    setAgent(db, 'watchman', 'augmentation');
    await resolve(DB, 'merged');
    assert.equal(level(db), 'augmentation');
  });

  await t.test('D3 one overrule drops ONE level, and its replay does not demote again', async () => {
    const { DB, db } = await openDb();
    setAgent(db, 'watchman', 'autonomy', 'autonomy');
    const f = await resolve(DB, 'rejected');
    assert.equal(level(db), 'augmentation');
    const again = await outcome(DB, f, 'rejected');
    assert.equal(again.body.existing, true);
    assert.equal(level(db), 'augmentation');
  });

  await t.test('D4 an overrule voids a pending promotion', async () => {
    const { DB, db } = await openDb();
    setSetting(db, 'staff.delegate_after', '2');
    await resolve(DB, 'merged');
    await resolve(DB, 'merged');
    assert.equal(promotions(db)[0].status, 'pending');
    await resolve(DB, 'rejected');
    assert.equal(promotions(db)[0].status, 'void');
  });

  await t.test('D5 a human change between the read and the CAS wins: demoted false, reason raced', async () => {
    let fired = false;
    const opened = await openDb({
      beforeRun(sql) {
        if (!fired && /UPDATE staff_agents SET autonomy/.test(sql)) {
          fired = true;
          opened.db.prepare(`UPDATE staff_agents SET autonomy='automation' WHERE name='watchman'`).run();
        }
      },
    });
    const { DB, db } = opened;
    setAgent(db, 'watchman', 'augmentation');
    const f = await resolve(DB, 'rejected');
    assert.ok(fired, 'the race hook never ran');
    assert.equal(f.res.autonomy.demoted, false);
    assert.equal(f.res.autonomy.reason, 'raced');
    assert.equal(db.prepare('SELECT status FROM staff_findings WHERE fingerprint=?').get(f.fp).status, 'rejected');
  });

  await t.test('D6 a concurrent outcome that lands first: the batch writes nothing (every effect is guarded)', async () => {
    let target = null;
    const opened = await openDb({
      beforeRun(sql, binds) {
        if (target && /INSERT OR IGNORE INTO staff_outcomes/.test(sql) && binds[0] === target) {
          const fp = target;
          target = null;
          opened.db.prepare(`INSERT INTO staff_outcomes (fingerprint, agent, class, family, outcome, verdict, ticket_url, resolved_at, applied)
                             SELECT fingerprint, agent, 'leak', ?, 'rejected', 'overrule', ticket_url, '2026-10-14T00:00:00Z', 1
                               FROM staff_findings WHERE fingerprint=?`).run(fam('leak'), fp);
          opened.db.prepare(`UPDATE staff_findings SET status='rejected' WHERE fingerprint=?`).run(fp);
        }
      },
    });
    const { DB, db } = opened;
    setAgent(db, 'watchman', 'augmentation');
    const f = await fileOne(DB);
    target = f.fp;
    const r = await outcome(DB, f, 'rejected');
    assert.equal(target, null, 'the race hook never ran');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.existing, true);
    assert.equal(level(db), 'augmentation', 'the losing batch demoted the agent');
    assert.equal(db.prepare('SELECT choice FROM staff_decisions WHERE escalation_key=?').get(`staff:${f.fp}`).choice, null);
    // BH-7722 seeds tackler's classes; the batch must write none of its own.
    assert.equal(db.prepare("SELECT count(*) AS n FROM staff_classes WHERE agent <> 'tackler'").get().n, 0);
  });

  await t.test('PR1 delegate_after=2: 1 agree makes no proposal, 2 make ONE pending row to the next level', async () => {
    const { DB, db } = await openDb();
    setSetting(db, 'staff.delegate_after', '2');
    const a = await resolve(DB, 'merged');
    assert.equal(promotions(db).length, 0);
    assert.equal(a.res.proposals.promotion_id, null);
    const b = await resolve(DB, 'merged');
    const p = promotions(db);
    assert.equal(p.length, 1);
    assert.equal(p[0].status, 'pending');
    assert.equal(p[0].from_level, 'automation');
    assert.equal(p[0].to_level, 'augmentation');
    assert.equal(p[0].agreements, 2);
    assert.equal(b.res.proposals.promotion_id, p[0].id);
    const c = await resolve(DB, 'merged');
    assert.equal(promotions(db).length, 1, 'one pending row per agent');
    assert.equal(c.res.proposals.promotion_id, null);
  });

  await t.test('PR2 at the cap: no proposal', async () => {
    const { DB, db } = await openDb();
    setSetting(db, 'staff.delegate_after', '2');
    setAgent(db, 'watchman', 'augmentation');
    await resolve(DB, 'merged');
    await resolve(DB, 'merged');
    assert.equal(promotions(db).length, 0);
  });

  await t.test('PR3 agree, overrule, agree: no proposal (the agreements are not in a row)', async () => {
    const { DB, db } = await openDb();
    setSetting(db, 'staff.delegate_after', '2');
    await resolve(DB, 'merged');
    await resolve(DB, 'rejected');
    await resolve(DB, 'merged');
    assert.equal(promotions(db).length, 0);
  });

  await t.test('PR4 a proposal never raises the level; the human autonomy POST does; the next agree marks it applied', async () => {
    const { DB, db } = await openDb();
    setSetting(db, 'staff.delegate_after', '2');
    await resolve(DB, 'merged');
    await resolve(DB, 'merged');
    assert.equal(level(db), 'automation');
    const h = await post(DB, '/api/staff/agents/autonomy', { agent: 'watchman', autonomy: 'augmentation', actor: 'operator' });
    assert.equal(h.status, 200, JSON.stringify(h.body));
    await resolve(DB, 'merged');
    assert.equal(promotions(db)[0].status, 'applied');
    assert.equal(level(db), 'augmentation');
  });

  await t.test('N1-N2 K=3: 2 noise make no row, the 3rd ONE pending row with no approver, the 4th no second row', async () => {
    const { DB, db } = await openDb();
    const F = fam('Cost Row');
    await resolve(DB, 'noise', { cls: 'Cost Row' });
    await resolve(DB, 'noise', { cls: 'cost row' });
    assert.equal(sups(db, F).length, 0);
    const third = await resolve(DB, 'noise', { cls: 'cost_row' });
    let s = sups(db, F);
    assert.equal(s.length, 1);
    assert.equal(s[0].status, 'pending');
    assert.equal(s[0].approver, null);
    assert.match(s[0].reason, /3 noise closures/);
    assert.match(s[0].reason, /cost-row/);
    assert.equal(third.res.proposals.suppression_id, s[0].id);
    const fourth = await resolve(DB, 'noise', { cls: 'cost-row' });
    s = sups(db, F);
    assert.equal(s.length, 1);
    assert.equal(fourth.res.proposals.suppression_id, null);
  });

  await t.test('N3 adversarial negatives: other classes, other agents, merged/rejected, replays make no row', async () => {
    const { DB, db } = await openDb();
    for (const c of ['alpha', 'beta', 'gamma']) await resolve(DB, 'noise', { cls: c });
    for (const a of ['watchman', 'inspector', 'clerk']) await resolve(DB, 'noise', { agent: a, cls: 'shared' });
    for (const w of ['rejected', 'rejected', 'merged']) await resolve(DB, w, { cls: 'delta' });
    const r = await resolve(DB, 'noise', { cls: 'epsilon' });
    await outcome(DB, r, 'noise');
    await outcome(DB, r, 'noise');
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_suppressions').get().n, 0);
    for (const w of ['noise', 'noise', 'noise']) await resolve(DB, w, { cls: 'zeta' });
    await resolve(DB, 'noise', { cls: 'eta' });
    assert.equal(sups(db, fam('eta')).length, 0, '3 of class zeta plus 1 of eta: eta has no row');
    assert.equal(sups(db, fam('zeta')).length, 1);
  });

  await t.test('N4-N5 RT1 pending never blocks a claim; after a human approve the same family (class case and spaces normalized) is 409 suppressed', async () => {
    const { DB, db } = await openDb();
    for (let i = 0; i < 3; i++) await resolve(DB, 'noise', { cls: 'Cost Row' });
    const s = sups(db, fam('cost-row'))[0];
    const pend = await claimNew(DB, 'cost row ');
    assert.equal(pend.status, 200, 'a pending suppression must not block');
    assert.equal(pend.body.claimed, true);
    const d = await post(DB, '/api/staff/suppressions/decide', { id: s.id, decision: 'approve', approver: 'the operator' });
    assert.equal(d.status, 200, JSON.stringify(d.body));
    const row = db.prepare('SELECT * FROM staff_suppressions WHERE id=?').get(s.id);
    assert.equal(row.status, 'active');
    assert.equal(row.approver, 'the operator');
    const blocked = await claimNew(DB, 'cost row ');
    assert.equal(blocked.status, 409);
    assert.equal(blocked.body.error, 'suppressed');
    assert.equal(blocked.body.suppression.id, s.id);
    const otherClass = await claimNew(DB, 'leak');
    assert.equal(otherClass.status, 200);
    const otherAgent = await claimNew(DB, 'cost row', 'inspector');
    assert.equal(otherAgent.status, 200);
    const replay = await post(DB, '/api/staff/suppressions/decide', { id: s.id, decision: 'approve', approver: 'the operator' });
    assert.equal(replay.status, 200);
    assert.equal(replay.body.existing, true);
    const flip = await post(DB, '/api/staff/suppressions/decide', { id: s.id, decision: 'decline', approver: 'the operator' });
    assert.equal(flip.status, 409);
    assert.equal(flip.body.error, 'not_pending');
  });

  await t.test('N6 an agent approver is 403 and the row stays pending', async () => {
    const { DB, db } = await openDb();
    for (let i = 0; i < 3; i++) await resolve(DB, 'noise', { cls: 'leak' });
    const s = sups(db, fam('leak'))[0];
    for (const who of ['archie', 'Watchman ', 'clerk']) {
      const r = await post(DB, '/api/staff/suppressions/decide', { id: s.id, decision: 'approve', approver: who });
      assert.equal(r.status, 403, who);
      assert.equal(r.body.error, 'agent_approver');
    }
    assert.equal(sups(db, fam('leak'))[0].status, 'pending');
    assert.equal((await post(DB, '/api/staff/suppressions/decide', { id: 999999, decision: 'approve', approver: 'operator' })).status, 404);
    assert.equal((await post(DB, '/api/staff/suppressions/decide', { id: s.id, decision: 'maybe', approver: 'operator' })).status, 400);
  });

  await t.test('N7 a decline revokes; the claim passes; the next proposal needs K NEW noise closures', async () => {
    const { DB, db } = await openDb();
    for (let i = 0; i < 3; i++) await resolve(DB, 'noise', { cls: 'leak' });
    const s = sups(db, fam('leak'))[0];
    const d = await post(DB, '/api/staff/suppressions/decide', { id: s.id, decision: 'decline', approver: 'operator' });
    assert.equal(d.status, 200, JSON.stringify(d.body));
    assert.equal(sups(db, fam('leak'))[0].status, 'revoked');
    assert.equal((await claimNew(DB, 'leak')).status, 200);
    await resolve(DB, 'noise', { cls: 'leak' });
    await resolve(DB, 'noise', { cls: 'leak' });
    assert.equal(sups(db, fam('leak')).length, 1, '2 new closures after a decline: no row');
    await resolve(DB, 'noise', { cls: 'leak' });
    const all = sups(db, fam('leak'));
    assert.equal(all.length, 2);
    assert.equal(all[1].status, 'pending');
  });

  await t.test('N7b noise closed while a proposal is pending does not count after a decline', async () => {
    const { DB, db } = await openDb();
    for (let i = 0; i < 3; i++) await resolve(DB, 'noise', { cls: 'leak' });
    const s = sups(db, fam('leak'))[0];
    assert.equal(s.status, 'pending');
    for (let i = 0; i < 3; i++) await resolve(DB, 'noise', { cls: 'leak' });
    assert.equal(sups(db, fam('leak')).length, 1, 'no second row while one is pending');
    const d = await post(DB, '/api/staff/suppressions/decide', { id: s.id, decision: 'decline', approver: 'operator' });
    assert.equal(d.status, 200, JSON.stringify(d.body));
    await resolve(DB, 'noise', { cls: 'leak' });
    await resolve(DB, 'noise', { cls: 'leak' });
    assert.equal(sups(db, fam('leak')).length, 1, '2 closures after the decline: no row');
    await resolve(DB, 'noise', { cls: 'leak' });
    const all = sups(db, fam('leak'));
    assert.equal(all.length, 2, '3rd closure after the decline: a new row');
    assert.deepEqual(all.map((r) => r.status), ['revoked', 'pending']);
  });

  await t.test('N8 S1 defaults: with the settings rows deleted K is 3 and an approve lasts 30 days', async (st) => {
    // The route stamps expires_at from the real clock, so pin Date to one anchor.
    const NOW_MS = Date.parse('2026-10-14T03:00:00Z');
    st.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
    const { DB, db } = await openDb();
    db.prepare(`DELETE FROM settings WHERE key IN ('staff.noise_suppress_after','staff.noise_suppress_days')`).run();
    await resolve(DB, 'noise');
    const two = await resolve(DB, 'noise');
    assert.equal(two.res.noise_rule.after, 3);
    assert.equal(two.res.noise_rule.source, 'default');
    assert.equal(sups(db, fam('leak')).length, 0);
    await resolve(DB, 'noise');
    const s = sups(db, fam('leak'))[0];
    assert.equal(s.status, 'pending');
    const d = await post(DB, '/api/staff/suppressions/decide', { id: s.id, decision: 'approve', approver: 'operator' });
    assert.equal(d.status, 200);
    assert.equal(d.body.days.value, 30);
    assert.equal(d.body.days.source, 'default');
    assert.equal(d.body.suppression.expires_at, '2026-11-13T03:00:00Z');
  });

  await t.test('N9 settings rows drive K: staff.noise_suppress_after=2 proposes at 2', async () => {
    const { DB, db } = await openDb();
    setSetting(db, 'staff.noise_suppress_after', '2');
    await resolve(DB, 'noise');
    const r = await resolve(DB, 'noise');
    assert.equal(r.res.noise_rule.source, 'settings');
    assert.equal(sups(db, fam('leak')).length, 1);
  });

  await t.test('C1 a protected class slug gets never_delegable = 1 and counts its streak', async () => {
    const { DB, db } = await openDb();
    await resolve(DB, 'merged', { cls: 'deploy' });
    await resolve(DB, 'merged', { cls: 'leak' });
    const c = (k) => db.prepare('SELECT * FROM staff_classes WHERE agent=? AND class=?').get('watchman', k);
    assert.equal(c('deploy').never_delegable, 1);
    assert.equal(c('deploy').streak, 1);
    assert.equal(c('leak').never_delegable, 0);
    await resolve(DB, 'rejected', { cls: 'leak' });
    assert.equal(c('leak').streak, 0);
  });

  await t.test('Q1-Q2 E1 L1 the pending list: filed rows only, by id, paged with after_id; empty is []; limit out of range is 400', async () => {
    const { DB } = await openDb();
    const empty = await get(DB, '/api/staff/outcomes/pending');
    assert.equal(empty.status, 200);
    assert.deepEqual(empty.body.findings, []);
    assert.equal(empty.body.truncated, false);
    const a = await fileOne(DB);
    const b = await fileOne(DB);
    const c = await fileOne(DB);
    await outcome(DB, b, 'merged');
    await claimNew(DB, 'leak');
    const p1 = await get(DB, '/api/staff/outcomes/pending?limit=1');
    assert.equal(p1.status, 200);
    assert.deepEqual(p1.body.findings.map((f) => f.fingerprint), [a.fp]);
    assert.equal(p1.body.findings[0].ticket_url, a.url);
    assert.equal(p1.body.findings[0].agent, 'watchman');
    assert.equal(p1.body.truncated, true);
    const p2 = await get(DB, `/api/staff/outcomes/pending?limit=5&after_id=${p1.body.next_after_id}`);
    assert.deepEqual(p2.body.findings.map((f) => f.fingerprint), [c.fp]);
    assert.equal(p2.body.truncated, false);
    for (const q of ['limit=0', 'limit=201', 'limit=x', 'after_id=-1']) {
      assert.equal((await get(DB, `/api/staff/outcomes/pending?${q}`)).status, 400, q);
    }
  });
});
