// BH-6824 (Staff in Mission Control 3/4): the autonomy and delegation audit,
// driven through the REAL worker.fetch over the REAL composed schema (the
// node:sqlite D1 shim), the way the BH-5559 charter suite does it.
//
//   A1 round-trip: a level change through POST is the row GET /api/staff/autonomy reads
//   A2 the cap is a hard limit; a no-op, a self-raise and a bad reason write no row
//   A3 delegation writes one row per real change; a protected class is 409 both ways
//   A4 every refused path leaves the audit count unchanged
//   A5 EXPLAIN QUERY PLAN of the reads, on 20 000 seeded audit rows
//   A6 the class list: display_state, protected, effective_cap; 404, 400, 503
//   A7 the list cap is the settings row, newest first, truncated named
//   A8 the retention rule removes an old row and keeps a fresh one; 0 is off
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const call = (DB, path, { method = 'POST', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const setLevel = (DB, body) => call(DB, '/api/staff/agents/autonomy', { body });
const delegation = (DB, body) => call(DB, '/api/staff/classes/delegation', { body });
const autonomy = (DB, agent) => call(DB, `/api/staff/autonomy?agent=${encodeURIComponent(agent)}`, { method: 'GET' });

const audits = (db) => db.prepare('SELECT * FROM staff_autonomy_changes ORDER BY id').all();
const count = (db) => db.prepare('SELECT count(*) AS n FROM staff_autonomy_changes').get().n;
const agentRow = (db, n) => db.prepare('SELECT * FROM staff_agents WHERE name=?').get(n);
const classRow = (db, a, c) => db.prepare('SELECT * FROM staff_classes WHERE agent=? AND class=?').get(a, c);
const addClass = (db, a, c, cap, streak, never = 0) => db.prepare(
  "INSERT INTO staff_classes (agent, class, cap, streak, never_delegable, updated_at) VALUES (?,?,?,?,?,'2026-10-09T00:00:00Z')"
).run(a, c, cap, streak, never);
const setAgentCap = (db, n, cap) => db.prepare('UPDATE staff_agents SET cap=? WHERE name=?').run(cap, n);
const setSetting = (db, k, v) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','t','t') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(k, v);
const audit = (db, agent, id, created = '2026-10-01T00:00:00Z') => db.prepare(
  `INSERT INTO staff_autonomy_changes (agent, kind, class, from_value, to_value, actor, reason, created_at)
   VALUES (?, 'autonomy', NULL, 'automation', 'augmentation', 'operator', ?, ?)`
).run(agent, `r${id}`, created);

// Records each SQL text and its binds at prepare/bind, so A5 explains what the
// route really ran.
function capturing(DB, log) {
  return {
    ...DB,
    prepare(sql) {
      const s = DB.prepare(sql);
      const entry = { sql, binds: [] };
      log.push(entry);
      const wrap = {
        bind(...v) { entry.binds = v; s.bind(...v); return wrap; },
        first: (c) => s.first(c), all: () => s.all(), run: () => s.run(),
      };
      return wrap;
    },
    batch: (stmts) => DB.batch(stmts),
  };
}

test('BH-6824 staff autonomy audit', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('A1 round-trip: POST a level change, GET reads the same row back', async () => {
    const { DB, db } = await openDb();
    setAgentCap(db, 'quartermaster', 'augmentation');
    const w = await setLevel(DB, { agent: 'quartermaster', autonomy: 'augmentation', actor: 'operator@example.com', reason: 'trial' });
    assert.equal(w.status, 200, JSON.stringify(w.body));
    assert.equal(typeof w.body.change_id, 'number');
    const rows = audits(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].id, w.body.change_id);
    const r = await autonomy(DB, 'Quartermaster');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.agent.name, 'quartermaster');
    assert.equal(r.body.agent.autonomy, 'augmentation');
    assert.equal(r.body.agent.cap, 'augmentation');
    assert.equal(r.body.agent.status, 'active');
    const c = r.body.changes[0];
    assert.equal(c.id, w.body.change_id);
    assert.equal(c.kind, 'autonomy');
    assert.equal(c.class, null);
    assert.equal(c.from_value, 'automation');
    assert.equal(c.to_value, 'augmentation');
    assert.equal(c.actor, 'operator@example.com');
    assert.equal(c.reason, 'trial');
    assert.match(c.created_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.equal(c.created_at, rows[0].created_at);
    assert.deepEqual(r.body.levels, ['automation', 'augmentation', 'autonomy']);
  });

  await t.test('A2 the cap is a hard limit; same level, a self-raise and a bad reason write no row', async () => {
    const { DB, db } = await openDb();
    const up = await setLevel(DB, { agent: 'watchman', autonomy: 'autonomy', actor: 'operator', reason: 'too far' });
    assert.equal(up.status, 409, JSON.stringify(up.body));
    assert.equal(up.body.error, 'above_cap');
    assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
    assert.equal(count(db), 0);
    const raise = await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor: 'operator', reason: 'earned' });
    assert.equal(raise.status, 200, JSON.stringify(raise.body));
    assert.equal(count(db), 1);
    const lower = await setLevel(DB, { agent: 'watchman', autonomy: 'automation', actor: 'operator', reason: 'noisy' });
    assert.equal(lower.status, 200, JSON.stringify(lower.body));
    assert.equal(count(db), 2);
    assert.deepEqual(audits(db).map((a) => [a.from_value, a.to_value, a.reason]),
      [['automation', 'augmentation', 'earned'], ['augmentation', 'automation', 'noisy']]);
    const same = await setLevel(DB, { agent: 'watchman', autonomy: 'automation', actor: 'operator', reason: 'again' });
    assert.equal(same.status, 200);
    assert.equal(same.body.existing, true);
    assert.equal(same.body.change_id, undefined);
    assert.equal(count(db), 2);
    for (const actor of ['archie', 'Watchman', 'clerk']) {
      const s = await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor, reason: 'self' });
      assert.equal(s.status, 403, actor);
      assert.equal(count(db), 2, actor);
    }
    for (const reason of ['   ', 'x'.repeat(501), 7, ['a']]) {
      const b = await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor: 'operator', reason });
      assert.equal(b.status, 400, JSON.stringify(reason));
      assert.equal(b.body.error, 'reason');
    }
    assert.equal(count(db), 2);
    assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
    // No reason at all (a direct API caller): the change lands, reason NULL.
    const plain = await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor: 'operator' });
    assert.equal(plain.status, 200, JSON.stringify(plain.body));
    assert.equal(audits(db)[2].reason, null);
    // A 500-char reason is the upper bound and is kept trimmed.
    const long = await setLevel(DB, { agent: 'watchman', autonomy: 'automation', actor: 'operator', reason: ` ${'y'.repeat(500)} ` });
    assert.equal(long.status, 200, JSON.stringify(long.body));
    assert.equal(audits(db)[3].reason, 'y'.repeat(500));
  });

  await t.test('A2b a racing level write between the read and the UPDATE is 409 changed_underneath, no row', async () => {
    const { DB, db } = await openDb();
    // The route reads automation; a racer moves it to augmentation before the UPDATE.
    let raced = false;
    const racy = {
      ...DB,
      prepare(sql) {
        if (!raced && /^\s*UPDATE staff_agents SET autonomy/.test(sql)) {
          raced = true;
          db.prepare("UPDATE staff_agents SET autonomy='augmentation' WHERE name='watchman'").run();
        }
        return DB.prepare(sql);
      },
      batch: (s) => DB.batch(s),
    };
    setAgentCap(db, 'watchman', 'autonomy');
    const r = await setLevel(racy, { agent: 'watchman', autonomy: 'autonomy', actor: 'operator', reason: 'race' });
    assert.ok(raced, 'the racer ran');
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.error, 'changed_underneath');
    assert.equal(r.body.agent.autonomy, 'augmentation');
    assert.equal(agentRow(db, 'watchman').autonomy, 'augmentation');
    assert.equal(count(db), 0);
  });

  await t.test('A3 delegation: one row per real change; a protected class is 409 for both decisions', async () => {
    const { DB, db } = await openDb();
    setAgentCap(db, 'watchman', 'autonomy');
    addClass(db, 'watchman', 'secret-ticket', 'autonomy', 9);
    const del = await delegation(DB, { agent: 'watchman', class: 'secret-ticket', decision: 'delegate', actor: 'operator', reason: 'nine in a row' });
    assert.equal(del.status, 200, JSON.stringify(del.body));
    assert.equal(typeof del.body.change_id, 'number');
    assert.equal(count(db), 1);
    let a = audits(db)[0];
    assert.deepEqual([a.kind, a.class, a.from_value, a.to_value, a.actor, a.reason],
      ['delegation', 'secret-ticket', 'ask_first', 'delegated', 'operator', 'nine in a row']);
    assert.equal(a.id, del.body.change_id);
    const again = await delegation(DB, { agent: 'watchman', class: 'secret-ticket', decision: 'delegate', actor: 'operator', reason: 'x' });
    assert.equal(again.body.existing, true);
    assert.equal(count(db), 1);
    const back = await delegation(DB, { agent: 'watchman', class: 'secret-ticket', decision: 'ask_first', actor: 'operator', reason: 'one miss' });
    assert.equal(back.status, 200, JSON.stringify(back.body));
    assert.equal(count(db), 2);
    a = audits(db)[1];
    assert.deepEqual([a.from_value, a.to_value, a.reason], ['delegated', 'ask_first', 'one miss']);
    assert.equal(classRow(db, 'watchman', 'secret-ticket').state, 'ask_first');
    // ask_first on an ask_first class: nothing changed, nothing audited, streak kept.
    db.prepare("UPDATE staff_classes SET streak=4 WHERE class='secret-ticket'").run();
    const noop = await delegation(DB, { agent: 'watchman', class: 'secret-ticket', decision: 'ask_first', actor: 'operator', reason: 'again' });
    assert.equal(noop.status, 200, JSON.stringify(noop.body));
    assert.equal(noop.body.existing, true);
    assert.equal(classRow(db, 'watchman', 'secret-ticket').streak, 4);
    assert.equal(count(db), 2);
    // Protected by the column, and protected by the name with the column 0.
    addClass(db, 'watchman', 'deploy', 'autonomy', 9, 1);
    addClass(db, 'watchman', 'cost-report', 'autonomy', 9, 0);
    for (const c of ['deploy', 'cost-report']) {
      for (const decision of ['delegate', 'ask_first']) {
        const r = await delegation(DB, { agent: 'watchman', class: c, decision, actor: 'operator', reason: 'try' });
        assert.equal(r.status, 409, `${c} ${decision}: ${JSON.stringify(r.body)}`);
        assert.equal(r.body.error, 'never_delegable', `${c} ${decision}`);
        assert.equal(classRow(db, 'watchman', c).state, 'ask_first');
        assert.equal(classRow(db, 'watchman', c).streak, 9, `${c} ${decision} keeps its streak`);
        assert.equal(count(db), 2, `${c} ${decision}`);
      }
    }
  });

  await t.test('A4 every refused path leaves the audit count unchanged', async () => {
    const { DB, db } = await openDb();
    setAgentCap(db, 'clerk', 'autonomy');
    addClass(db, 'clerk', 'file-note', 'autonomy', 2);        // not earned (min 5)
    addClass(db, 'clerk', 'capped-note', 'augmentation', 9);  // class cap below autonomy
    addClass(db, 'clerk', 'merge', 'autonomy', 9, 1);         // protected
    const before = count(db);
    const cases = [
      [() => delegation(DB, { agent: 'clerk', class: 'file-note', decision: 'delegate', actor: 'operator', reason: 'r' }), 409, 'not_earned'],
      [() => delegation(DB, { agent: 'clerk', class: 'capped-note', decision: 'delegate', actor: 'operator', reason: 'r' }), 409, 'capped'],
      [() => delegation(DB, { agent: 'clerk', class: 'merge', decision: 'delegate', actor: 'operator', reason: 'r' }), 409, 'never_delegable'],
      [() => delegation(DB, { agent: 'clerk', class: 'merge', decision: 'ask_first', actor: 'operator', reason: 'r' }), 409, 'never_delegable'],
      [() => delegation(DB, { agent: 'clerk', class: 'file-note', decision: 'delegate', actor: 'archie', reason: 'r' }), 403, 'self_delegation'],
      [() => delegation(DB, { agent: 'clerk', class: '../x', decision: 'delegate', actor: 'operator', reason: 'r' }), 400, 'class'],
      [() => delegation(DB, { agent: 'clerk', class: 'file-note', decision: 'delegate', actor: 'operator', reason: '  ' }), 400, 'reason'],
      [() => delegation(DB, { agent: 'ghost', class: 'file-note', decision: 'delegate', actor: 'operator', reason: 'r' }), 404, 'agent not found'],
      [() => delegation(DB, { agent: 7, class: 'file-note', decision: 'delegate', actor: 'operator', reason: 'r' }), 400, 'agent'],
      [() => setLevel(DB, { agent: 'ghost', autonomy: 'augmentation', actor: 'operator', reason: 'r' }), 404, 'agent not found'],
      [() => setLevel(DB, { agent: 'clerk', autonomy: 'augmentation', actor: 'clerk', reason: 'r' }), 403, 'self_promotion'],
    ];
    for (const [fn, status, error] of cases) {
      const r = await fn();
      assert.equal(r.status, status, `${error}: ${JSON.stringify(r.body)}`);
      assert.equal(r.body.error, error);
      assert.equal(count(db), before, error);
    }
    // A paused agent cannot be delegated to.
    addClass(db, 'clerk', 'rotate-key', 'autonomy', 9);
    db.prepare("UPDATE staff_agents SET status='paused' WHERE name='clerk'").run();
    const p = await delegation(DB, { agent: 'clerk', class: 'rotate-key', decision: 'delegate', actor: 'operator', reason: 'r' });
    assert.equal(p.status, 409);
    assert.equal(p.body.error, 'agent_not_active');
    assert.equal(count(db), before);
    assert.equal(classRow(db, 'clerk', 'rotate-key').state, 'ask_first');
  });

  await t.test('A5 EXPLAIN on 20 000 audit rows: every read uses an index, no bare scan', async () => {
    const { DB, db } = await openDb();
    const agents = ['archivist', 'clerk', 'dispatcher', 'inspector', 'millwright', 'quartermaster', 'watchman'];
    const ins = db.prepare(`INSERT INTO staff_autonomy_changes (agent, kind, class, from_value, to_value, actor, reason, created_at)
                            VALUES (?, 'delegation', ?, 'ask_first', 'delegated', 'operator', 'seed', ?)`);
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      ins.run(agents[i % 7], `c${i % 13}`, `2026-01-01T00:00:${String(i % 60).padStart(2, '0')}Z`);
    }
    db.exec('COMMIT');
    addClass(db, 'watchman', 'secret-ticket', 'autonomy', 0);
    const log = [];
    const r = await autonomy(capturing(DB, log), 'watchman');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const planOf = (re) => {
      const hit = log.find((e) => re.test(e.sql));
      assert.ok(hit, `no statement matched ${re}`);
      return db.prepare(`EXPLAIN QUERY PLAN ${hit.sql}`).all(...hit.binds).map((x) => x.detail);
    };
    const list = planOf(/FROM staff_autonomy_changes/);
    assert.ok(list.some((l) => /idx_staff_autonomy_changes_agent_id/.test(l)), list.join(' | '));
    const cls = planOf(/FROM staff_classes/);
    assert.ok(cls.some((l) => /SEARCH staff_classes USING (INDEX sqlite_autoindex_staff_classes_1|PRIMARY KEY)/.test(l)), cls.join(' | '));
    const { RULES } = await import('../src/routes/retention.js');
    const rule = RULES.find((x) => x.rule === 'staff_autonomy_changes.age');
    assert.ok(rule, 'the retention rule exists');
    const ids = db.prepare(`EXPLAIN QUERY PLAN ${rule.ids}`).all('2026-01-01T00:00:30Z', 10).map((x) => x.detail);
    assert.ok(ids.some((l) => /idx_staff_autonomy_changes_created/.test(l)), ids.join(' | '));
    const delPlan = db.prepare(`EXPLAIN QUERY PLAN ${rule.del}`).all('[1]').map((x) => x.detail);
    for (const lines of [list, cls, ids, delPlan]) {
      const bad = lines.filter((l) => /^SCAN staff_(autonomy_changes|classes)\b/.test(l) && !/USING (INDEX|PRIMARY KEY|INTEGER PRIMARY KEY|COVERING INDEX)/.test(l));
      assert.deepEqual(bad, [], lines.join(' | '));
    }
  });

  await t.test('A6 the class list: display_state, protected and effective_cap; 404, 400 and 503', async () => {
    const { DB, db } = await openDb();
    setAgentCap(db, 'watchman', 'autonomy');
    addClass(db, 'watchman', 'secret-ticket', 'augmentation', 3);
    addClass(db, 'watchman', 'rotate-key', 'autonomy', 7);
    db.prepare("UPDATE staff_classes SET state='delegated' WHERE class='rotate-key'").run();
    addClass(db, 'watchman', 'deploy', 'autonomy', 0, 1);
    addClass(db, 'clerk', 'not-mine', 'autonomy', 0);
    const r = await autonomy(DB, ' WATCHMAN ');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const byClass = Object.fromEntries(r.body.classes.map((c) => [c.class, c]));
    assert.deepEqual(r.body.classes.map((c) => c.class), ['deploy', 'rotate-key', 'secret-ticket']);
    assert.equal(byClass['secret-ticket'].display_state, 'ask_first');
    assert.equal(byClass['rotate-key'].display_state, 'delegated');
    assert.equal(byClass.deploy.display_state, 'never_delegable');
    assert.deepEqual(r.body.classes.map((c) => c.protected), [true, false, false]);
    assert.equal(byClass['secret-ticket'].effective_cap, 'augmentation');
    assert.equal(byClass['rotate-key'].effective_cap, 'autonomy');
    assert.equal(byClass['rotate-key'].streak, 7);
    assert.equal(byClass['secret-ticket'].cap, 'augmentation');
    assert.equal(r.body.delegate_after.min, 5);
    assert.equal(r.body.delegate_after.source, 'settings');
    // A protected NAME with the column 0 is protected too.
    addClass(db, 'watchman', 'cost-report', 'autonomy', 0, 0);
    const r2 = await autonomy(DB, 'watchman');
    const cr = r2.body.classes.find((c) => c.class === 'cost-report');
    assert.equal(cr.protected, true);
    assert.equal(cr.display_state, 'never_delegable');
    // No classes: an empty list, not an error.
    const e = await autonomy(DB, 'inspector');
    assert.equal(e.status, 200);
    assert.deepEqual(e.body.classes, []);
    assert.deepEqual(e.body.changes, []);
    assert.equal(e.body.changes_truncated, false);
    const g = await autonomy(DB, 'ghost');
    assert.equal(g.status, 404);
    assert.equal(g.body.error, 'agent not found');
    assert.equal((await autonomy(DB, 'archie')).status, 404);
    const b = await autonomy(DB, 'a/b');
    assert.equal(b.status, 400);
    assert.equal(b.body.error, 'agent');
    db.exec('DROP TABLE staff_autonomy_changes');
    const m = await autonomy(DB, 'watchman');
    assert.equal(m.status, 503);
    assert.equal(m.body.error, 'staff_autonomy_changes schema not applied');
  });

  await t.test('A6b with the audit table missing a write changes no state', async () => {
    const { DB, db } = await openDb();
    db.exec('DROP TABLE staff_autonomy_changes');
    const r = await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor: 'operator', reason: 'r' });
    assert.equal(r.status, 503, JSON.stringify(r.body));
    assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
  });

  await t.test('A7 the list cap is the settings row; newest first; truncated is named; junk is the default 20', async () => {
    const { DB, db } = await openDb();
    for (let i = 1; i <= 5; i++) audit(db, 'clerk', i);
    audit(db, 'watchman', 99);
    setSetting(db, 'staff.autonomy_changes_shown', '3');
    const r = await autonomy(DB, 'clerk');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.changes.map((c) => c.reason), ['r5', 'r4', 'r3']);
    assert.equal(r.body.changes_truncated, true);
    assert.equal(r.body.changes_limit, 3);
    assert.equal(r.body.changes_limit_source, 'settings');
    setSetting(db, 'staff.autonomy_changes_shown', '5');
    const exact = await autonomy(DB, 'clerk');
    assert.equal(exact.body.changes.length, 5);
    assert.equal(exact.body.changes_truncated, false);
    for (const junk of ['x', '0', '501', '2.5', '']) {
      setSetting(db, 'staff.autonomy_changes_shown', junk);
      const j = await autonomy(DB, 'clerk');
      assert.equal(j.body.changes_limit, 20, junk);
      assert.equal(j.body.changes_limit_source, 'default', junk);
      assert.equal(j.body.changes.length, 5, junk);
    }
    const seeded = await openDb();
    assert.equal(seeded.db.prepare("SELECT value FROM settings WHERE key='staff.autonomy_changes_shown'").get().value, '20');
  });

  await t.test('A8 retention: the rule removes an old row, keeps a fresh one; window 0 turns it off', async () => {
    const { DB, db } = await openDb();
    const { RULES } = await import('../src/routes/retention.js');
    const rule = RULES.find((x) => x.rule === 'staff_autonomy_changes.age');
    assert.ok(rule, 'staff_autonomy_changes.age is a rule');
    assert.equal(rule.table, 'staff_autonomy_changes');
    assert.equal(rule.key, 'retention.staff_autonomy_changes.days');
    assert.equal(db.prepare("SELECT value FROM settings WHERE key='retention.staff_autonomy_changes.days'").get().value, '1095');
    audit(db, 'clerk', 1, '2000-01-01T00:00:00Z');
    audit(db, 'clerk', 2, '2999-01-01T00:00:00Z');
    setSetting(db, 'retention.dry_run', '0');
    setSetting(db, 'retention.staff_autonomy_changes.days', '0');
    const off = await call(DB, '/api/retention/run', { body: {} });
    assert.equal(off.status, 200, JSON.stringify(off.body));
    assert.equal(off.body.rules.find((x) => x.rule === 'staff_autonomy_changes.age').off, true);
    assert.equal(count(db), 2);
    setSetting(db, 'retention.staff_autonomy_changes.days', '1');
    const run = await call(DB, '/api/retention/run', { body: {} });
    assert.equal(run.status, 200, JSON.stringify(run.body));
    assert.equal(run.body.rules.find((x) => x.rule === 'staff_autonomy_changes.age').removed, 1);
    assert.deepEqual(audits(db).map((a) => a.reason), ['r2']);
  });
});
