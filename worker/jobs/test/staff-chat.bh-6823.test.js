// BH-6823: one chat thread per staff agent, read on the agent's next tick.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema (jobsSchemaSql via openDb).
//
//   W1  POST then GET: role operator, state pending, the stamped actor; the GET
//       is newest first and `next` pages by id
//   W2  a stopped agent (staff-kill-<agent>, staff-kill-all, staff-off-<agent>,
//       status paused): 201, stopped true, stopped_by names it, the row is kept
//       with state held
//   W3  not held: no flag, a flag row with active=0, a flag for another agent,
//       a near name (staff-kill-allx)
//   W4  take claims held and pending notes in id order up to limit (taken,
//       tick_key, attempts 1); inside the lease a second take gets none; past
//       the lease the note is taken again; another agent's notes stay
//   W5  settle: a reply writes one role-agent row (reply_to, tick_key) and the
//       note becomes read; the GET shows the reply; a second settle is a no-op;
//       unanswered and release move only notes taken by that tick
//   W6  attempts cap: a note at staff.chat.attempts_max is failed by the next
//       take and is not returned
//   W7  404 for archie and unknown names; 400 for bad input (never clamped);
//       the GET's tick_id comes from the staff_ticks row with the same key
//   W8  EXPLAIN QUERY PLAN on 5,000 seeded rows: every staff_chat statement the
//       routes and the retention rule run reads through an index
//   W9  the settings rows are seeded; a bad value falls back to the code default
//   W10 retention staff_chat.age: an old read note and its reply go; old
//       pending, held and taken notes stay; one retention_runs row for the rule
//   W11 round trips per route (batch = one trip): GET 1, send 2, take 3
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'secret-fixture';
const call = (DB, path, { method = 'GET', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const ACTOR = 'operator-fixture@example.com';
const send = (DB, text, agent = 'quartermaster') => call(DB, '/api/staff/chat', { method: 'POST', body: { agent, text, actor: ACTOR } });
const thread = (DB, q) => call(DB, `/api/staff/chat?${q}`);
const take = (DB, tick_key, over = {}) => call(DB, '/api/staff/chat/take', { method: 'POST', body: { agent: 'quartermaster', tick_key, limit: 5, ...over } });
const settle = (DB, body) => call(DB, '/api/staff/chat/settle', { method: 'POST', body: { agent: 'quartermaster', ...body } });
const flag = (db, name, active = 1) => db.prepare(
  `INSERT OR REPLACE INTO pause_flags (name, active, actor, reason, updated_at) VALUES (?, ?, 'fixture', 'fixture', '2026-10-10T00:00:00Z')`
).run(name, active);
const row = (db, id) => db.prepare('SELECT * FROM staff_chat WHERE id=?').get(id);
const TK = 'quartermaster-20261010t000000z-101';
const TK2 = 'quartermaster-20261010t001500z-102';

test('W1 POST then GET: the note comes back pending with the actor; newest first; next pages by id', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const a = await send(DB, '  what did you check last run?  ');
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.message.role, 'operator');
  assert.equal(a.body.message.state, 'pending');
  assert.equal(a.body.message.actor, ACTOR);
  assert.equal(a.body.message.text, 'what did you check last run?');
  assert.equal(a.body.stopped, false);
  assert.equal(a.body.stopped_by, null);
  assert.equal(row(db, a.body.message.id).state, 'pending');
  const ids = [a.body.message.id];
  for (const s of ['note two', 'note three']) ids.push((await send(DB, s)).body.message.id);
  await send(DB, 'a note for another agent', 'watchman');
  const p1 = await thread(DB, 'agent=quartermaster&limit=2');
  assert.equal(p1.status, 200, JSON.stringify(p1.body));
  assert.equal(p1.body.agent, 'quartermaster');
  assert.deepEqual(p1.body.messages.map((m) => m.id), [ids[2], ids[1]]);
  assert.equal(p1.body.next, ids[1]);
  assert.equal(p1.body.stopped, false);
  const p2 = await thread(DB, `agent=quartermaster&limit=2&before=${p1.body.next}`);
  assert.deepEqual(p2.body.messages.map((m) => m.id), [ids[0]]);
  assert.equal(p2.body.next, null);
  assert.equal(p2.body.messages[0].actor, ACTOR);
  // Default limit (50) answers the whole thread, and the agent name normalizes.
  const all = await thread(DB, 'agent=%20Quartermaster%20');
  assert.equal(all.status, 200, JSON.stringify(all.body));
  assert.deepEqual(all.body.messages.map((m) => m.id), [ids[2], ids[1], ids[0]]);
});

test('W2 a stopped agent: the note is kept as held and the answer says stopped', async (t) => {
  for (const [label, setup, want] of [
    ['staff-kill-quartermaster', (db) => flag(db, 'staff-kill-quartermaster'), 'staff-kill-quartermaster'],
    ['staff-kill-all', (db) => flag(db, 'staff-kill-all'), 'staff-kill-all'],
    ['staff-off-quartermaster', (db) => flag(db, 'staff-off-quartermaster'), 'staff-off-quartermaster'],
    ['status paused', (db) => db.prepare("UPDATE staff_agents SET status='paused' WHERE name='quartermaster'").run(), 'status paused'],
  ]) {
    await t.test(label, async (tt) => {
      const o = await openDb(); if (!o) return tt.skip('node:sqlite unavailable');
      const { db, DB } = o;
      setup(db);
      const r = await send(DB, 'are you there?');
      assert.equal(r.status, 201, JSON.stringify(r.body));
      assert.equal(r.body.stopped, true);
      assert.equal(r.body.stopped_by, want);
      assert.equal(r.body.message.state, 'held');
      const stored = row(db, r.body.message.id);
      assert.equal(stored.state, 'held');
      assert.equal(stored.stopped_by, want);
      const g = await thread(DB, 'agent=quartermaster');
      assert.equal(g.body.stopped, true);
      assert.equal(g.body.stopped_by, want);
      assert.equal(g.body.messages[0].state, 'held');
    });
  }
});

test('W3 not held: no flag, an inactive flag, another agent\'s flag, a near name', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const check = async (label) => {
    const r = await send(DB, `probe ${label}`);
    assert.equal(r.status, 201, JSON.stringify(r.body));
    assert.equal(r.body.message.state, 'pending', label);
    assert.equal(r.body.stopped, false, label);
    assert.equal(row(db, r.body.message.id).stopped_by, null, label);
  };
  await check('no flag');
  flag(db, 'staff-kill-quartermaster', 0);
  await check('active=0');
  flag(db, 'staff-kill-watchman');
  await check('another agent');
  flag(db, 'staff-kill-allx');
  await check('near name');
  // A note sent BEFORE a kill stays pending; the GET still says stopped.
  flag(db, 'staff-kill-quartermaster', 1);
  const g = await thread(DB, 'agent=quartermaster');
  assert.equal(g.body.stopped, true);
  assert.equal(g.body.messages[0].state, 'pending');
});

test('W4 take: held and pending in id order up to limit; the lease keeps a taken note; another agent stays', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const p1 = (await send(DB, 'first')).body.message.id;
  flag(db, 'staff-kill-quartermaster');
  const h = (await send(DB, 'second, sent while killed')).body.message.id;
  flag(db, 'staff-kill-quartermaster', 0);
  const p3 = (await send(DB, 'third')).body.message.id;
  const other = (await send(DB, 'for watchman', 'watchman')).body.message.id;
  assert.equal(row(db, h).state, 'held');
  const a = await take(DB, TK, { limit: 2 });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.deepEqual(a.body.notes.map((n) => n.id), [p1, h], 'id order, held included, capped at limit');
  assert.equal(a.body.notes[1].text, 'second, sent while killed');
  assert.ok(a.body.notes[0].at, 'each note carries its send time');
  assert.deepEqual(a.body.failed, []);
  for (const id of [p1, h]) {
    const r = row(db, id);
    assert.equal(r.state, 'taken');
    assert.equal(r.tick_key, TK);
    assert.equal(r.attempts, 1);
  }
  assert.equal(row(db, p3).state, 'pending');
  const b = await take(DB, TK2);
  assert.deepEqual(b.body.notes.map((n) => n.id), [p3], 'inside the lease the taken notes stay with their tick');
  const c = await take(DB, 'quartermaster-20261010t003000z-103');
  assert.deepEqual(c.body.notes, []);
  db.prepare("UPDATE staff_chat SET updated_at='2026-01-01T00:00:00Z' WHERE id=?").run(p1);
  const d = await take(DB, 'quartermaster-20261010t004500z-104');
  assert.deepEqual(d.body.notes.map((n) => n.id), [p1], 'past the lease the note is taken again');
  assert.equal(row(db, p1).attempts, 2);
  assert.equal(row(db, p1).tick_key, 'quartermaster-20261010t004500z-104');
  assert.equal(row(db, other).state, 'pending', 'another agent\'s note is never taken');
});

test('W5 settle: reply row + read; GET shows it; a second settle is a no-op; unanswered and release', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const n1 = (await send(DB, 'what did you check last run?')).body.message.id;
  const n2 = (await send(DB, 'and the one before?')).body.message.id;
  const n3 = (await send(DB, 'anything odd?')).body.message.id;
  await take(DB, TK);
  const s = await settle(DB, { tick_key: TK, replies: [{ id: n1, text: '  I read 4 cost rows.  ' }], unanswered: [n2], release: [n3] });
  assert.equal(s.status, 200, JSON.stringify(s.body));
  assert.equal(s.body.replied, 1);
  assert.equal(s.body.unanswered, 1);
  assert.equal(s.body.released, 1);
  assert.equal(s.body.skipped, 0);
  assert.equal(row(db, n1).state, 'read');
  assert.equal(row(db, n2).state, 'unanswered');
  assert.equal(row(db, n3).state, 'pending');
  const replies = db.prepare("SELECT * FROM staff_chat WHERE role='agent'").all();
  assert.equal(replies.length, 1);
  assert.equal(replies[0].reply_to, n1);
  assert.equal(replies[0].tick_key, TK);
  assert.equal(replies[0].text, 'I read 4 cost rows.');
  assert.equal(replies[0].actor, 'quartermaster');
  assert.equal(replies[0].state, 'sent');
  const g = await thread(DB, 'agent=quartermaster');
  const rep = g.body.messages.find((m) => m.role === 'agent');
  assert.equal(rep.reply_to, n1);
  assert.equal(rep.tick_key, TK);
  assert.equal(rep.text, 'I read 4 cost rows.');
  // A second settle of the same note: nothing moves, nothing is added.
  const again = await settle(DB, { tick_key: TK, replies: [{ id: n1, text: 'second answer' }] });
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.replied, 0);
  assert.equal(again.body.skipped, 1);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM staff_chat WHERE role='agent'").get().n, 1);
  // A note taken by ANOTHER tick is not touched by this tick's settle.
  await take(DB, TK2);
  assert.equal(row(db, n3).tick_key, TK2);
  const foreign = await settle(DB, { tick_key: TK, replies: [{ id: n3, text: 'not mine' }], unanswered: [], release: [] });
  assert.equal(foreign.body.replied, 0);
  assert.equal(foreign.body.skipped, 1);
  assert.equal(row(db, n3).state, 'taken');
  const foreign2 = await settle(DB, { tick_key: TK, unanswered: [n3] });
  assert.equal(foreign2.body.unanswered, 0);
  const foreign3 = await settle(DB, { tick_key: TK, release: [n3] });
  assert.equal(foreign3.body.released, 0);
  assert.equal(row(db, n3).state, 'taken');
  // Another agent's settle never touches quartermaster's note.
  const wrongAgent = await settle(DB, { agent: 'watchman', tick_key: TK2, release: [n3] });
  assert.equal(wrongAgent.body.released, 0);
  assert.equal(row(db, n3).state, 'taken');
  // The right tick releases it.
  const mine = await settle(DB, { tick_key: TK2, release: [n3] });
  assert.equal(mine.body.released, 1);
  assert.equal(row(db, n3).state, 'pending');
});

test('W6 attempts cap: a note at staff.chat.attempts_max is failed by the next take and not returned', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const n = (await send(DB, 'keeps failing')).body.message.id;
  const ok = (await send(DB, 'fresh note')).body.message.id;
  await take(DB, TK);
  await settle(DB, { tick_key: TK, release: [n, ok] });
  await take(DB, TK2);
  await settle(DB, { tick_key: TK2, release: [n, ok] });
  assert.equal(row(db, n).attempts, 2);
  assert.equal(row(db, n).state, 'pending');
  db.prepare("UPDATE staff_chat SET attempts=1 WHERE id=?").run(ok);
  const r = await take(DB, 'quartermaster-20261010t003000z-103');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.notes.map((x) => x.id), [ok]);
  assert.deepEqual(r.body.failed.map((x) => x.id), [n]);
  assert.equal(row(db, n).state, 'failed');
  assert.equal(row(db, n).attempts, 2, 'a failed note is not counted again');
  // A taken note at the cap whose lease ran out is failed too, not retaken.
  db.prepare("UPDATE staff_chat SET attempts=2, updated_at='2026-01-01T00:00:00Z' WHERE id=?").run(ok);
  const r2 = await take(DB, 'quartermaster-20261010t004500z-104');
  assert.deepEqual(r2.body.notes, []);
  assert.deepEqual(r2.body.failed.map((x) => x.id), [ok]);
  assert.equal(row(db, ok).state, 'failed');
});

test('W7 404 for archie and unknown names; 400 for bad input; tick_id from staff_ticks', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  for (const agent of ['archie', 'nobody-fixture']) {
    assert.equal((await send(DB, 'hi', agent)).status, 404, agent);
    assert.equal((await thread(DB, `agent=${agent}`)).status, 404, agent);
    assert.equal((await take(DB, TK, { agent })).status, 404, agent);
    assert.equal((await settle(DB, { agent, tick_key: TK, release: [1] })).status, 404, agent);
  }
  const bad = async (label, p) => { const r = await p; assert.equal(r.status, 400, `${label}: ${JSON.stringify(r.body)}`); };
  await bad('bad agent', send(DB, 'hi', '1bad'));
  await bad('blank text', send(DB, '   '));
  await bad('text over 4000', send(DB, 'x'.repeat(4001)));
  assert.equal((await send(DB, 'x'.repeat(4000))).status, 201, '4000 is the edge, accepted');
  await bad('no actor', call(DB, '/api/staff/chat', { method: 'POST', body: { agent: 'quartermaster', text: 'hi' } }));
  await bad('GET no agent', thread(DB, 'limit=5'));
  await bad('limit=0', thread(DB, 'agent=quartermaster&limit=0'));
  await bad('limit=101', thread(DB, 'agent=quartermaster&limit=101'));
  await bad('limit=abc', thread(DB, 'agent=quartermaster&limit=abc'));
  await bad('before=0', thread(DB, 'agent=quartermaster&before=0'));
  await bad('before=-3', thread(DB, 'agent=quartermaster&before=-3'));
  await bad('bad tick_key', take(DB, 'Bad Key!'));
  await bad('take limit=0', take(DB, TK, { limit: 0 }));
  await bad('take limit=21', take(DB, TK, { limit: 21 }));
  await bad('settle bad tick_key', settle(DB, { tick_key: '', release: [1] }));
  await bad('settle bad id', settle(DB, { tick_key: TK, release: [0] }));
  await bad('settle reply no text', settle(DB, { tick_key: TK, replies: [{ id: 1, text: '  ' }] }));
  await bad('settle id in two lists', settle(DB, { tick_key: TK, unanswered: [1], release: [1] }));
  await bad('settle nothing', settle(DB, { tick_key: TK }));
  // The reply's tick_id is the staff_ticks row with the same key.
  const n = (await send(DB, 'link my tick')).body.message.id;
  await take(DB, TK);
  await settle(DB, { tick_key: TK, replies: [{ id: n, text: 'linked' }] });
  let rep = (await thread(DB, 'agent=quartermaster')).body.messages.find((m) => m.role === 'agent');
  assert.equal(rep.tick_id, null, 'no tick row yet: no id');
  const tickId = Number(db.prepare(`INSERT INTO staff_ticks (tick_key, agent, started_at, ended_at, duration_s, phase, created_at)
    VALUES (?, 'quartermaster', '2026-10-10T00:00:00Z', '2026-10-10T00:01:00Z', 60, 'done', '2026-10-10T00:01:00Z')`).run(TK).lastInsertRowid);
  db.prepare(`INSERT INTO staff_ticks (tick_key, agent, started_at, ended_at, duration_s, phase, created_at)
    VALUES (?, 'quartermaster', '2026-10-10T00:15:00Z', '2026-10-10T00:16:00Z', 60, 'done', '2026-10-10T00:16:00Z')`).run(TK2);
  rep = (await thread(DB, 'agent=quartermaster')).body.messages.find((m) => m.role === 'agent');
  assert.equal(rep.tick_id, tickId);
});

// A proxy over the D1 binding records each SQL text at prepare() and its binds
// at bind() (the staff-activity A8 recorder).
function recorder(DB) {
  const seen = new Map();
  const wrapStmt = (sql, st) => new Proxy(st, {
    get(target, k) {
      if (k === 'bind') return (...a) => { seen.set(sql, a); return wrapStmt(sql, target.bind(...a)); };
      const v = target[k];
      return typeof v === 'function' ? v.bind(target) : v;
    },
  });
  const db = new Proxy(DB, {
    get(target, k) {
      if (k === 'prepare') return (sql) => { if (!seen.has(sql)) seen.set(sql, []); return wrapStmt(sql, target.prepare(sql)); };
      const v = target[k];
      return typeof v === 'function' ? v.bind(target) : v;
    },
  });
  return { db, seen };
}
const scans = (lines) => lines.filter((l) => /^SCAN \w+/.test(l) && !/USING (INDEX|PRIMARY KEY|INTEGER PRIMARY KEY|COVERING INDEX)/.test(l)
  && !/^SCAN json_each\b/.test(l));

function seedVolume(db) {
  const agents = ['quartermaster', 'watchman', 'clerk', 'inspector', 'archivist'];
  const states = ['read', 'unanswered', 'failed', 'pending', 'held'];
  const ts = (i) => new Date(Date.UTC(2026, 0, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  db.exec('BEGIN');
  const note = db.prepare(`INSERT INTO staff_chat (agent, role, text, actor, state, tick_key, attempts, created_at, updated_at)
    VALUES (?, 'operator', 'seed note', 'operator-fixture@example.com', ?, ?, 1, ?, ?)`);
  const reply = db.prepare(`INSERT INTO staff_chat (agent, role, text, actor, state, reply_to, tick_key, created_at, updated_at)
    VALUES (?, 'agent', 'seed reply', ?, 'sent', ?, ?, ?, ?)`);
  const tick = db.prepare(`INSERT INTO staff_ticks (tick_key, agent, started_at, ended_at, duration_s, phase, created_at) VALUES (?, ?, ?, ?, 1, 'done', ?)`);
  let n = 0;
  for (let i = 0; n < 5000; i++) {
    const agent = agents[i % agents.length];
    const state = states[i % states.length];
    const key = `seed-${i}`;
    const id = Number(note.run(agent, state, key, ts(i), ts(i)).lastInsertRowid); n += 1;
    if (state === 'read') { reply.run(agent, agent, id, key, ts(i), ts(i)); n += 1; tick.run(key, agent, ts(i), ts(i), ts(i)); }
  }
  db.exec('COMMIT');
}

test('W8 every staff_chat statement reads through an index, on 5,000 seeded rows', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db: sql, DB } = o;
  seedVolume(sql);
  assert.ok(sql.prepare('SELECT COUNT(*) n FROM staff_chat').get().n >= 5000);
  const { db, seen } = recorder(DB);
  const first = await thread(db, 'agent=quartermaster&limit=50');
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal(first.body.messages.length, 50);
  assert.ok(first.body.messages.some((m) => m.tick_id), 'the page joined a tick');
  await thread(db, `agent=quartermaster&limit=50&before=${first.body.next}`);
  const s = await send(db, 'volume probe');
  await take(db, TK);
  await settle(db, { tick_key: TK, replies: [{ id: s.body.message.id, text: 'ok' }], unanswered: [], release: [] });
  const stmts = [...seen.entries()].filter(([q]) => /\bstaff_chat\b/.test(q) && !/^\s*CREATE\b/i.test(q));
  assert.ok(stmts.length >= 5, `the routes reached only ${stmts.length} staff_chat statements`);
  const want = { get: false, take: false };
  for (const [q, binds] of stmts) {
    const lines = sql.prepare(`EXPLAIN QUERY PLAN ${q}`).all(...binds).map((x) => x.detail);
    assert.deepEqual(scans(lines), [], `${q.replace(/\s+/g, ' ').slice(0, 160)}: ${lines.join(' | ')}`);
    if (/ORDER BY c\.id DESC/.test(q)) { want.get = true; assert.ok(lines.some((l) => l.includes('idx_staff_chat_agent_id')), `GET: ${lines.join(' | ')}`); }
    if (/state='taken', tick_key=/.test(q)) { want.take = true; assert.ok(lines.some((l) => l.includes('idx_staff_chat_agent_state')), `take: ${lines.join(' | ')}`); }
  }
  assert.ok(want.get && want.take, `reached: ${JSON.stringify(want)}`);
  // The retention rule's three statements.
  const { RULES } = await import('../src/routes/retention.js');
  const r = RULES.find((x) => x.rule === 'staff_chat.age');
  assert.ok(r, 'retention rule staff_chat.age');
  const plan = (q, ...b) => sql.prepare(`EXPLAIN QUERY PLAN ${q}`).all(...b).map((x) => x.detail);
  const ids = plan(r.ids, '2026-01-02T00:00:00Z', 500);
  assert.deepEqual(scans(ids), [], ids.join(' | '));
  assert.ok(ids.some((l) => l.includes('idx_staff_chat_role_created')), ids.join(' | '));
  for (const q of [...(r.pre || []), r.del]) {
    const lines = plan(q, '[1,2,3]');
    assert.deepEqual(scans(lines), [], `${q}: ${lines.join(' | ')}`);
  }
  assert.ok(plan(r.pre[0], '[1,2,3]').some((l) => l.includes('idx_staff_chat_reply_to')), 'the reply delete uses idx_staff_chat_reply_to');
});

test('W9 settings rows are seeded; a bad value falls back to the code default', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const val = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(val('staff.chat.attempts_max'), '2');
  assert.equal(val('staff.chat.take_lease_s'), '1200');
  assert.equal(val('retention.staff_chat.days'), '365');
  const n = (await send(DB, 'cap probe')).body.message.id;
  db.prepare('UPDATE staff_chat SET attempts=2 WHERE id=?').run(n);
  // A raised cap lets the note be taken a third time.
  db.prepare("UPDATE settings SET value='3' WHERE key='staff.chat.attempts_max'").run();
  assert.deepEqual((await take(DB, TK)).body.notes.map((x) => x.id), [n]);
  await settle(DB, { tick_key: TK, release: [n] });
  db.prepare('UPDATE staff_chat SET attempts=2 WHERE id=?').run(n);
  // A bad value is the code default (2): the note is failed, not taken.
  db.prepare("UPDATE settings SET value='lots' WHERE key='staff.chat.attempts_max'").run();
  const r = await take(DB, TK2);
  assert.deepEqual(r.body.notes, []);
  assert.deepEqual(r.body.failed.map((x) => x.id), [n]);
  // The lease: a 600 s old taken note stays with its tick under the 1200 s
  // default even when the row is bad, and is retaken under a 300 s row.
  const m = (await send(DB, 'lease probe')).body.message.id;
  await take(DB, 'quartermaster-20261010t003000z-103');
  const old = new Date(Date.parse(row(db, m).updated_at) - 600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  db.prepare('UPDATE staff_chat SET updated_at=? WHERE id=?').run(old, m);
  db.prepare("UPDATE settings SET value='0' WHERE key='staff.chat.take_lease_s'").run();
  assert.deepEqual((await take(DB, 'quartermaster-20261010t004500z-104')).body.notes, [], 'a bad lease row is the 1200 s default');
  db.prepare("UPDATE settings SET value='300' WHERE key='staff.chat.take_lease_s'").run();
  assert.deepEqual((await take(DB, 'quartermaster-20261010t010000z-105')).body.notes.map((x) => x.id), [m]);
});

test('W10 retention staff_chat.age: an old read note and its reply go; open notes stay', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const NOW = Date.now();  // determinism: ok the retention route cuts at its own clock; every seeded time is an offset from it
  const ago = (d) => new Date(NOW - d * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ins = db.prepare(`INSERT INTO staff_chat (agent, role, text, actor, state, reply_to, tick_key, created_at, updated_at)
    VALUES ('quartermaster', ?, ?, 'fixture', ?, ?, ?, ?, ?)`);
  const add = (role, state, days, replyTo = null) => Number(ins.run(role, `${role} ${state} ${days}`, state, replyTo, replyTo ? 'k' : null, ago(days), ago(days)).lastInsertRowid);
  const oldRead = add('operator', 'read', 10);
  const oldReply = add('agent', 'sent', 10, oldRead);
  const keep = ['pending', 'held', 'taken'].map((s) => add('operator', s, 10));
  const newRead = add('operator', 'read', 0);
  add('agent', 'sent', 0, newRead);
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  db.prepare("UPDATE settings SET value='1' WHERE key='retention.staff_chat.days'").run();
  const r = await call(DB, '/api/retention/run', { method: 'POST', body: {} });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const out = r.body.rules.find((x) => x.rule === 'staff_chat.age');
  assert.equal(out.removed, 1, JSON.stringify(out));
  assert.equal(out.error, null);
  const left = db.prepare('SELECT id FROM staff_chat ORDER BY id').all().map((x) => x.id);
  assert.ok(!left.includes(oldRead) && !left.includes(oldReply), 'the old note and its reply went');
  for (const id of [...keep, newRead]) assert.ok(left.includes(id), `row ${id} stays`);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM retention_runs WHERE rule='staff_chat.age'").get().n, 1);
});

// W11 (lead review of #7155, perf): count D1 round trips per route call. A
// statement's first/all/run is one trip; one batch() is one trip, however many
// statements it holds. The table creates are memoised per binding, so a
// warm-up call of each route runs first and only the second call is counted.
function tripCounter(DB) {
  // A statement run by batch() itself is part of that batch's one trip.
  const c = { trips: 0, batches: 0, inBatch: 0 };
  const wrapStmt = (st) => new Proxy(st, {
    get(target, k) {
      if (k === 'bind') return (...a) => wrapStmt(target.bind(...a));
      if (k === 'first' || k === 'all' || k === 'run') return (...a) => { if (!c.inBatch) c.trips += 1; return target[k](...a); };
      const v = target[k];
      return typeof v === 'function' ? v.bind(target) : v;
    },
  });
  const db = new Proxy(DB, {
    get(target, k) {
      if (k === 'prepare') return (sql) => wrapStmt(target.prepare(sql));
      if (k === 'batch') {
        return async (stmts) => {
          c.trips += 1; c.batches += 1; c.inBatch += 1;
          try { return await target.batch(stmts); } finally { c.inBatch -= 1; }
        };
      }
      const v = target[k];
      return typeof v === 'function' ? v.bind(target) : v;
    },
  });
  return { db, c };
}

test('W11 round trips: GET thread 1, POST send 2 (reads batched), take 3 (reads batched)', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db: raw, DB } = o;
  const { db, c } = tripCounter(DB);
  const count = async (fn) => { const before = c.trips; const r = await fn(); return { r, n: c.trips - before }; };
  // warm-up: every route once, so the memoised table creates are done
  const w = await send(db, 'warm-up');
  assert.equal(w.status, 201, JSON.stringify(w.body));
  await thread(db, 'agent=quartermaster');
  await take(db, TK);
  // the counted calls
  const g = await count(() => thread(db, 'agent=quartermaster'));
  assert.equal(g.r.status, 200, JSON.stringify(g.r.body));
  assert.equal(g.n, 1, `GET /api/staff/chat made ${g.n} round trips (roster, page and flags must be one batch)`);
  const s = await count(() => send(db, 'counted'));
  assert.equal(s.r.status, 201, JSON.stringify(s.r.body));
  assert.equal(s.n, 2, `POST /api/staff/chat made ${s.n} round trips (one read batch, one insert)`);
  const k = await count(() => take(db, TK2));
  assert.equal(k.r.status, 200, JSON.stringify(k.r.body));
  assert.equal(k.n, 3, `POST /api/staff/chat/take made ${k.n} round trips (one read batch, the sweep, the claim)`);
  // the batched reads still decide the same things
  flag(raw, 'staff-kill-quartermaster');
  const held = await send(db, 'while stopped');
  assert.equal(held.body.stopped, true);
  assert.equal(held.body.stopped_by, 'staff-kill-quartermaster');
  assert.equal(held.body.message.state, 'held');
  const gs = await thread(db, 'agent=quartermaster');
  assert.equal(gs.body.stopped_by, 'staff-kill-quartermaster');
  assert.equal((await thread(db, 'agent=archie')).status, 404);
  assert.equal((await thread(db, 'agent=nobody')).status, 404);
  assert.equal((await send(db, 'x', 'nobody')).status, 404);
});
