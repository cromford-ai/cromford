// BH-5559 (BH-5556.2): the staff charter and autonomy tables, driven through
// the REAL worker.fetch against the REAL schema.sql (the node:sqlite D1 shim),
// the way archie-autonomy.bh-4067.test.js does it. Pinned here: the 7 seeded
// roles in observe mode, the roster validated with agent-core's charter schema,
// 404 for an unknown agent, 409 for a level above the cap, 403 for an agent
// that tries to raise itself, the class delegation gated by agent-core
// decide() on the lower of the two caps, and Archie's own rows unchanged.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { validate } from '../../../agent-core/src/index.js';

const CHARTER = JSON.parse(readFileSync(new URL('../../../agent-core/schema/charter.schema.json', import.meta.url), 'utf8'));
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
const roster = (DB) => call(DB, '/api/staff/agents', { method: 'GET' });
const one = (DB, name) => call(DB, `/api/staff/agent?name=${encodeURIComponent(name)}`, { method: 'GET' });
const setLevel = (DB, body) => call(DB, '/api/staff/agents/autonomy', { body });
const delegation = (DB, body) => call(DB, '/api/staff/classes/delegation', { body });

const agentRow = (db, n) => db.prepare('SELECT * FROM staff_agents WHERE name=?').get(n);
const classRow = (db, a, c) => db.prepare('SELECT * FROM staff_classes WHERE agent=? AND class=?').get(a, c);
const addClass = (db, a, c, cap, streak) => db.prepare(
  "INSERT INTO staff_classes (agent, class, cap, streak, updated_at) VALUES (?,?,?,?,'2026-10-09T00:00:00Z')"
).run(a, c, cap, streak);
const setAgentCap = (db, n, cap) => db.prepare('UPDATE staff_agents SET cap=? WHERE name=?').run(cap, n);
const setSetting = (db, v) => db.prepare("UPDATE settings SET value=? WHERE key='staff.delegate_after'").run(v);

const NAMES = ['archivist', 'clerk', 'dispatcher', 'inspector', 'millwright', 'quartermaster', 'watchman'];

test('BH-5559 staff charter and autonomy', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('S1 seeds: 7 roles in observe mode, capped at augmentation; the settings row reads 5', async () => {
    const { db } = await openDb();
    const rows = db.prepare('SELECT * FROM staff_agents ORDER BY name').all();
    assert.deepEqual(rows.map((r) => r.name), NAMES);
    for (const r of rows) {
      assert.equal(r.autonomy, 'automation', r.name);
      assert.equal(r.cap, 'augmentation', r.name);
      assert.equal(r.status, 'active', r.name);
      assert.equal(r.accountable, 'operator@example.com', r.name);
      assert.equal(r.soul_path, `prompts/staff/${r.name}-soul.md`, r.name);
      assert.ok(r.role.length > 0, r.name);
    }
    // BH-5564: quartermaster owns the 7 cost lanes; BH-5566: dispatcher owns the
    // 11 health lanes; no other agent has a lane yet.
    assert.equal(db.prepare("SELECT count(*) AS n FROM staff_lanes WHERE agent NOT IN ('quartermaster', 'dispatcher')").get().n, 0);
    assert.deepEqual(db.prepare("SELECT lane FROM staff_lanes WHERE agent = 'quartermaster' ORDER BY lane").all().map((r) => r.lane),
      ['cap-loss-detector', 'ci-minutes-watch', 'cost-local-brake', 'cost-reconcile', 'extra-usage-track', 'orchestrator-burn', 'vendor-spend-pull']);
    assert.deepEqual(db.prepare("SELECT lane FROM staff_lanes WHERE agent = 'dispatcher' ORDER BY lane").all().map((r) => r.lane),
      ['fleet-slo', 'healthcheck', 'heartbeat-reaper', 'hub-probe', 'jobs-watchdog', 'lane-run-wait-alert', 'pipeline-health',
        'served-sha-watch', 'watchdog-ping', 'watchdog-poll', 'watchdog-responder']);
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_classes').get().n, 0);
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_decisions').get().n, 0);
    assert.equal(db.prepare("SELECT value FROM settings WHERE key='staff.delegate_after'").get().value, '5');
    assert.throws(() => db.prepare("UPDATE staff_agents SET autonomy='autonomy' WHERE name='watchman'").run(), /CHECK/);
    assert.throws(() => db.prepare("UPDATE staff_agents SET autonomy='full' WHERE name='watchman'").run(), /CHECK/);
    assert.throws(() => db.prepare(
      "INSERT INTO staff_classes (agent, class, never_delegable, updated_at) VALUES ('watchman','merge',0,'t')"
    ).run(), /CHECK/);
  });

  await t.test('S1b every route is bearer-gated', async () => {
    const { DB } = await openDb();
    for (const [m, p] of [['GET', '/api/staff/agents'], ['GET', '/api/staff/agent?name=clerk'],
      ['POST', '/api/staff/agents/autonomy'], ['POST', '/api/staff/classes/delegation']]) {
      assert.equal((await call(DB, p, { method: m, body: m === 'POST' ? {} : undefined, secret: null })).status, 401, p);
    }
  });

  await t.test('S2 roster: 7 charters in name order, each valid against charter.schema.json; lanes join in', async () => {
    const { DB, db } = await openDb();
    const r = await roster(DB);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.complete, true);
    assert.deepEqual(r.body.invalid, []);
    assert.deepEqual(r.body.agents.map((a) => a.name), NAMES);
    for (const a of r.body.agents) assert.deepEqual(validate(CHARTER, a), { ok: true, errors: [] }, a.name);
    const w = r.body.agents.find((a) => a.name === 'watchman');
    assert.deepEqual(w, {
      name: 'watchman', role: 'security', accountable: 'operator@example.com', autonomy: 'automation',
      cap: 'augmentation', status: 'active', soul: 'prompts/staff/watchman-soul.md', lanes: [],
    });
    db.prepare("INSERT INTO staff_lanes (agent, lane, created_at) VALUES ('watchman','secret-scan','t')").run();
    db.prepare("INSERT INTO staff_lanes (agent, lane, created_at) VALUES ('watchman','dep-audit','t')").run();
    const r2 = await roster(DB);
    assert.deepEqual(r2.body.agents.find((a) => a.name === 'watchman').lanes, ['dep-audit', 'secret-scan']);
    assert.deepEqual(r2.body.agents.find((a) => a.name === 'clerk').lanes, []);
  });

  await t.test('S2b a row the charter schema refuses is named in invalid, not served, and complete is false', async () => {
    const { DB, db } = await openDb();
    db.prepare(
      "INSERT INTO staff_agents (name, role, accountable, soul_path, updated_at) VALUES ('blank-role','','operator@example.com','prompts/staff/x.md','t')"
    ).run();
    const r = await roster(DB);
    assert.equal(r.status, 200);
    assert.equal(r.body.complete, false);
    assert.deepEqual(r.body.agents.map((a) => a.name), NAMES);
    assert.equal(r.body.invalid.length, 1);
    assert.equal(r.body.invalid[0].name, 'blank-role');
    assert.ok(r.body.invalid[0].errors.some((e) => /role/.test(e)), JSON.stringify(r.body.invalid));
    const single = await one(DB, 'blank-role');
    assert.equal(single.status, 503);
    assert.equal(single.body.error, 'agent row invalid');
  });

  await t.test('S3 unknown agent is a 404 on every route; a cased name resolves; a bad name is a 400', async () => {
    const { DB } = await openDb();
    const want = { error: 'agent not found' };
    const g = await one(DB, 'ghost');
    assert.equal(g.status, 404);
    assert.deepEqual(g.body, want);
    const s = await setLevel(DB, { agent: 'ghost', autonomy: 'augmentation', actor: 'operator' });
    assert.equal(s.status, 404);
    assert.deepEqual(s.body, want);
    const d = await delegation(DB, { agent: 'ghost', class: 'secret-ticket', decision: 'delegate', actor: 'operator' });
    assert.equal(d.status, 404);
    assert.deepEqual(d.body, want);
    const q = await one(DB, 'Quartermaster');
    assert.equal(q.status, 200, JSON.stringify(q.body));
    assert.equal(q.body.agent.name, 'quartermaster');
    assert.equal(q.body.agent.role, 'cost');
    assert.equal((await one(DB, 'quarter_master')).status, 400);
    assert.equal((await one(DB, 'quarter master')).body.error, 'name');
  });

  await t.test('S4 a level above the cap is a 409 and writes nothing; within the cap it sets, replays, lowers', async () => {
    const { DB, db } = await openDb();
    const r = await setLevel(DB, { agent: 'watchman', autonomy: 'autonomy', actor: 'operator' });
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.deepEqual(r.body, { error: 'above_cap', autonomy: 'autonomy', cap: 'augmentation' });
    assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
    const up = await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor: 'operator' });
    assert.equal(up.status, 200, JSON.stringify(up.body));
    assert.equal(up.body.agent.autonomy, 'augmentation');
    assert.equal(agentRow(db, 'watchman').autonomy, 'augmentation');
    assert.equal(agentRow(db, 'watchman').note, 'autonomy augmentation by operator');
    const replay = await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor: 'operator' });
    assert.equal(replay.status, 200);
    assert.equal(replay.body.existing, true);
    const down = await setLevel(DB, { agent: 'watchman', autonomy: 'automation', actor: 'operator' });
    assert.equal(down.status, 200);
    assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
    for (const [b, field] of [
      [{ agent: 'watchman', autonomy: 'Autonomy', actor: 'operator' }, 'autonomy'],
      [{ agent: 'watchman', autonomy: 'full', actor: 'operator' }, 'autonomy'],
      [{ agent: 'watchman', autonomy: 'augmentation', actor: ' ' }, 'actor'],
      [{ agent: 'watchman', autonomy: 'augmentation' }, 'actor'],
      [{ agent: 'water_man', autonomy: 'augmentation', actor: 'operator' }, 'agent'],
    ]) {
      const bad = await setLevel(DB, b);
      assert.equal(bad.status, 400, JSON.stringify(b));
      assert.equal(bad.body.error, field);
    }
    assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
  });

  await t.test('S5 an agent cannot raise itself or a peer; any actor may lower', async () => {
    const { DB, db } = await openDb();
    for (const actor of ['archie', 'Watchman ', 'clerk']) {
      const r = await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor });
      assert.equal(r.status, 403, actor);
      assert.deepEqual(r.body, { error: 'self_promotion' });
      assert.equal(agentRow(db, 'watchman').autonomy, 'automation', actor);
    }
    await setLevel(DB, { agent: 'watchman', autonomy: 'augmentation', actor: 'operator' });
    const down = await setLevel(DB, { agent: 'watchman', autonomy: 'automation', actor: 'archie' });
    assert.equal(down.status, 200, JSON.stringify(down.body));
    assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
  });

  await t.test('S5b the agent name is normalised once: " WATCHMAN " is watchman', async () => {
    const { DB, db } = await openDb();
    const r = await setLevel(DB, { agent: ' WATCHMAN ', autonomy: 'augmentation', actor: 'operator' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.agent.name, 'watchman');
    assert.equal(agentRow(db, 'watchman').autonomy, 'augmentation');
  });

  await t.test('S6 a capped agent or a capped class cannot be delegated; a protected class never', async () => {
    const { DB, db } = await openDb();
    const del = (c, actor = 'operator') => delegation(DB, { agent: 'watchman', class: c, decision: 'delegate', actor });
    addClass(db, 'watchman', 'secret-ticket', 'autonomy', 9);
    // (a) agent cap augmentation, class cap autonomy.
    const a = await del('secret-ticket');
    assert.equal(a.status, 409, JSON.stringify(a.body));
    assert.equal(a.body.error, 'capped');
    assert.equal(a.body.agent_cap, 'augmentation');
    assert.equal(a.body.class_cap, 'autonomy');
    assert.equal(classRow(db, 'watchman', 'secret-ticket').state, 'ask_first');
    // (b) agent cap autonomy, class cap augmentation.
    setAgentCap(db, 'watchman', 'autonomy');
    db.prepare("UPDATE staff_classes SET cap='augmentation' WHERE class='secret-ticket'").run();
    const b = await del('secret-ticket');
    assert.equal(b.status, 409, JSON.stringify(b.body));
    assert.equal(b.body.error, 'capped');
    assert.equal(classRow(db, 'watchman', 'secret-ticket').state, 'ask_first');
    // An agent may not delegate a class to itself or a peer.
    db.prepare("UPDATE staff_classes SET cap='autonomy' WHERE class='secret-ticket'").run();
    for (const actor of ['archie', 'Watchman', 'clerk']) {
      const s = await del('secret-ticket', actor);
      assert.equal(s.status, 403, actor);
      assert.deepEqual(s.body, { error: 'self_delegation' });
    }
    assert.equal(classRow(db, 'watchman', 'secret-ticket').state, 'ask_first');
    // (c) both caps autonomy, streak 9.
    const c = await del('Secret-Ticket');
    assert.equal(c.status, 200, JSON.stringify(c.body));
    assert.equal(c.body.class_state.state, 'delegated');
    assert.equal(classRow(db, 'watchman', 'secret-ticket').state, 'delegated');
    const again = await del('secret-ticket');
    assert.equal(again.status, 200);
    assert.equal(again.body.existing, true);
    // ask_first puts it back and zeroes the streak.
    const back = await delegation(DB, { agent: 'watchman', class: 'secret-ticket', decision: 'ask_first', actor: 'archie' });
    assert.equal(back.status, 200, JSON.stringify(back.body));
    const row = classRow(db, 'watchman', 'secret-ticket');
    assert.equal(row.state, 'ask_first');
    assert.equal(row.streak, 0);
    assert.ok(row.reverted_at);
    // (d) a class whose NAME is protected, though its column says 0.
    addClass(db, 'watchman', 'cost-report', 'autonomy', 99);
    const d = await del('cost-report');
    assert.equal(d.status, 409, JSON.stringify(d.body));
    assert.equal(d.body.error, 'never_delegable');
    assert.equal(classRow(db, 'watchman', 'cost-report').state, 'ask_first');
    // Unknown class for a known agent; a paused agent.
    const nf = await del('nothing-here');
    assert.equal(nf.status, 404);
    assert.equal(nf.body.error, 'class nothing-here not found');
    addClass(db, 'watchman', 'rotate-key', 'autonomy', 9);
    db.prepare("UPDATE staff_agents SET status='paused' WHERE name='watchman'").run();
    const p = await del('rotate-key');
    assert.equal(p.status, 409);
    assert.equal(p.body.error, 'agent_not_active');
    assert.equal(classRow(db, 'watchman', 'rotate-key').state, 'ask_first');
    for (const [b, field] of [
      [{ agent: 'watchman', class: '../x', decision: 'delegate', actor: 'operator' }, 'class'],
      [{ agent: 'watchman', class: 'rotate-key', decision: 'yes', actor: 'operator' }, 'decision'],
      [{ agent: 'watchman', class: 'rotate-key', decision: 'delegate', actor: '' }, 'actor'],
      [{ agent: 7, class: 'rotate-key', decision: 'delegate', actor: 'operator' }, 'agent'],
    ]) {
      const r = await delegation(DB, b);
      assert.equal(r.status, 400, JSON.stringify(b));
      assert.equal(r.body.error, field);
    }
  });

  await t.test('S7 the streak threshold is the settings row; junk reads the default 5 and says so', async () => {
    const { DB, db } = await openDb();
    setAgentCap(db, 'clerk', 'autonomy');
    addClass(db, 'clerk', 'file-note', 'autonomy', 4);
    const del = () => delegation(DB, { agent: 'clerk', class: 'file-note', decision: 'delegate', actor: 'operator' });
    const r = await del();
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.error, 'not_earned');
    assert.equal(r.body.streak, 4);
    assert.equal(r.body.min_streak, 5);
    assert.equal(r.body.min_streak_source, 'settings');
    assert.equal(classRow(db, 'clerk', 'file-note').state, 'ask_first');
    for (const junk of ['x', '0', '1001', '3.5', '']) {
      setSetting(db, junk);
      const j = await del();
      assert.equal(j.status, 409, junk);
      assert.equal(j.body.min_streak, 5, junk);
      assert.equal(j.body.min_streak_source, 'default', junk);
    }
    db.prepare("DELETE FROM settings WHERE key='staff.delegate_after'").run();
    assert.equal((await del()).body.min_streak_source, 'default');
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('staff.delegate_after','3','t','t','t')").run();
    const ok = await del();
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(ok.body.class_state.state, 'delegated');
    assert.equal(ok.body.min_streak, 3);
  });

  await t.test('S8 Archie rows read unchanged; the agent views name them archie', async () => {
    const { DB, db } = await openDb();
    assert.equal(db.prepare('SELECT count(*) AS n FROM archie_classes').get().n, 11);
    const row = db.prepare("SELECT * FROM archie_classes WHERE class='watch-cadence'").get();
    assert.deepEqual({ ...row }, {
      class: 'watch-cadence', never_delegable: 0, state: 'ask_first', streak: 0, delegated_at: null,
      reverted_at: null, updated_at: '2026-10-04T00:00:00Z', note: 'check more or less often',
    });
    assert.equal(db.prepare("SELECT agent FROM agent_classes WHERE class='watch-cadence'").get().agent, 'archie');
    assert.equal(db.prepare("SELECT count(*) AS n FROM agent_classes WHERE agent='archie'").get().n, 11);
    addClass(db, 'watchman', 'secret-ticket', 'augmentation', 0);
    const s = db.prepare("SELECT * FROM agent_classes WHERE class='secret-ticket'").get();
    assert.equal(s.agent, 'watchman');
    assert.equal(s.cap, 'augmentation');
    const rec = await call(DB, '/api/archie/decisions', {
      body: {
        escalation_key: 'check:1:2026-10-09T07:00:00Z', initiative_id: 1, class: 'watch-cadence',
        sensitive: false, recommendation: 'Check weekly instead of daily.',
      },
    });
    assert.equal(rec.status, 201, JSON.stringify(rec.body));
    const v = db.prepare("SELECT * FROM agent_decisions WHERE escalation_key='check:1:2026-10-09T07:00:00Z'").get();
    assert.equal(v.agent, 'archie');
    assert.equal(v.class, 'watch-cadence');
    assert.equal(v.mode, 'ask');
  });

  await t.test('S9 Archie\'s delegation route cannot see a staff class', async () => {
    const { DB, db } = await openDb();
    addClass(db, 'watchman', 'secret-ticket', 'autonomy', 9);
    const r = await call(DB, '/api/archie/classes/delegation', {
      body: { class: 'secret-ticket', decision: 'delegate', min_streak: 1, actor: 'operator' },
    });
    assert.equal(r.status, 404, JSON.stringify(r.body));
    assert.equal(r.body.error, 'class secret-ticket not found');
    assert.equal(classRow(db, 'watchman', 'secret-ticket').state, 'ask_first');
  });

  await t.test('S10 schema not applied is a 503 naming the table, never a 404', async () => {
    const { DB, db } = await openDb();
    db.exec('DROP VIEW agent_classes; DROP TABLE staff_lanes; DROP TABLE staff_agents');
    const r = await roster(DB);
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'staff_agents schema not applied');
  });
});
