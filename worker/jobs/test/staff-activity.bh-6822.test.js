// BH-6822: the staff agent activity timeline, driven through the REAL
// worker.fetch on node:sqlite with the composed jobs schema.
//
//   A1  POST /api/staff/ticks: 201, then the same body is a 200 replay;
//       duration_s is ended_at - started_at
//   A2  the same tick_key with another payload is 409
//   A3  400 per bad field, 404 for an agent not on the roster
//   A4  GET /api/staff/agent/:name/activity merges ticks, finding.claimed,
//       finding.recorded, outcomes and decisions by time, newest first
//   A5  cursor paging: limit 3 over 10 events is 3+3+3+1, no gap, no duplicate,
//       with same-second events of two kinds and two same-second ticks
//   A6  archie reads archie_decisions; an unknown agent is 404; a bad limit or
//       before is 400
//   A7  a tick's cost comes from cost_rows by run_id; unpriced rows are counted
//       and never read as $0; no cost row is cost null
//   A8  EXPLAIN QUERY PLAN for every statement the activity route runs, on
//       seeded volume: each one reads through an index
//   A9  retention rule staff_ticks.age
//   A10 GET /api/staff/tick?id=: the row and its cost rows; 404; 400
//   A11 the roster's last_tick_at per agent, and the seek's plan
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

const COUNTS = { collected: 3, new_items: 2, deferred: 0, model_calls: 1, digested: 1, filed: 1, refused: 0, unsupported: 0, failed: 0, held: 0 };
const tickBody = (over = {}) => ({
  tick_key: 'watchman-20261010t000000z-101', agent: 'watchman',
  started_at: '2026-10-10T00:00:00Z', ended_at: '2026-10-10T00:01:30Z', phase: 'done',
  collector_rc: 0, collector_s: 4, model_rc: 0, ...COUNTS,
  cost_run_id: 'staff-tick:watchman-20261010t000000z-101', ...over,
});
const postTick = (DB, over) => call(DB, '/api/staff/ticks', { method: 'POST', body: tickBody(over) });
const activity = (DB, agent, q = '') => call(DB, `/api/staff/agent/${agent}/activity${q}`);

const FP = (i) => String(i).padStart(64, '0');
function finding(db, i, { agent = 'watchman', status = 'filed', claimed, updated, ticket = null }) {
  return Number(db.prepare(`INSERT INTO staff_findings (fingerprint, agent, title, source_kind, source_url, source_labels, observed_at, status, ticket_url, claimed_at, updated_at)
              VALUES (?, ?, ?, 'alert', 'https://example.com/fixture', '[]', ?, ?, ?, ?, ?)`)
    .run(FP(i), agent, `Finding ${i}`, claimed, status, ticket, claimed, updated).lastInsertRowid);
}
function outcome(db, i, resolved, agent = 'watchman') {
  return Number(db.prepare(`INSERT INTO staff_outcomes (fingerprint, agent, class, family, outcome, verdict, ticket_url, resolved_at, applied)
              VALUES (?, ?, 'c', ?, 'merged', 'agree', 'https://github.com/o/r/issues/9', ?, 1)`)
    .run(FP(i), agent, 'f'.repeat(64), resolved).lastInsertRowid);
}
function decision(db, key, created, agent = 'watchman') {
  return Number(db.prepare(`INSERT INTO staff_decisions (agent, escalation_key, class, recommendation, mode, choice, counted, created_at)
              VALUES (?, ?, 'c', 'file it', 'ask', 'approve', 1, ?)`).run(agent, key, created).lastInsertRowid);
}
const kinds = (b) => b.events.map((e) => `${e.kind}:${e.id}`);

test('A1 POST /api/staff/ticks: 201, replay 200, duration_s computed', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const a = await postTick(DB);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.tick.duration_s, 90);
  assert.equal(a.body.replay, false);
  const b = await postTick(DB);
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.replay, true);
  assert.equal(b.body.tick.id, a.body.tick.id);
  const rows = db.prepare('SELECT agent, phase, duration_s, filed, collector_s, cost_run_id FROM staff_ticks').all();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].duration_s, 90);
  assert.equal(rows[0].filed, 1);
  assert.equal(rows[0].collector_s, 4);
  // A tick with no model call carries no cost_run_id and null rcs.
  const c = await postTick(DB, { tick_key: 'watchman-20261010t001500z-102', started_at: '2026-10-10T00:15:00Z', ended_at: '2026-10-10T00:15:00Z',
    phase: 'collect', collector_rc: 3, model_rc: null, cost_run_id: null, model_calls: 0 });
  assert.equal(c.status, 201, JSON.stringify(c.body));
  assert.equal(c.body.tick.duration_s, 0);
});

test('A2 the same tick_key with another payload is 409', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { DB } = o;
  assert.equal((await postTick(DB)).status, 201);
  const r = await postTick(DB, { filed: 2 });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'tick_key_conflict');
});

test('A3 400 per bad field; 404 for an agent not on the roster', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const cases = [
    ['agent', { agent: 'Bad Agent!' }],
    ['tick_key', { tick_key: 'Has Spaces' }],
    ['started_at', { started_at: '2026-10-10 00:00:00' }],
    ['ended_at', { ended_at: '2026-10-09T23:59:59Z' }],
    ['phase', { phase: 'sleeping' }],
    ['filed', { filed: -1 }],
    ['collected', { collected: 1.5 }],
    ['held', { held: 100001 }],
    ['collector_rc', { collector_rc: 256 }],
    ['model_rc', { model_rc: 'x' }],
    ['cost_run_id', { cost_run_id: 'staff-tick:another-key' }],
  ];
  for (const [field, over] of cases) {
    const r = await postTick(DB, over);
    assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, field, field);
  }
  const missing = tickBody(); delete missing.digested;
  const m = await call(DB, '/api/staff/ticks', { method: 'POST', body: missing });
  assert.equal(m.status, 400);
  assert.equal(m.body.error, 'digested', 'an absent count is refused, never read as 0');
  const n = await postTick(DB, { agent: 'nobody', tick_key: 'nobody-1', cost_run_id: 'staff-tick:nobody-1' });
  assert.equal(n.status, 404, JSON.stringify(n.body));
  // The identity is normalized once: ' Watchman ' is watchman.
  const w = await postTick(DB, { agent: ' Watchman ' });
  assert.equal(w.status, 201, JSON.stringify(w.body));
  assert.equal(db.prepare('SELECT agent FROM staff_ticks').get().agent, 'watchman');
});

test('A4 the activity read merges every kind by time, newest first', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const t1 = (await postTick(DB, { tick_key: 'watchman-a', cost_run_id: null, started_at: '2026-10-10T01:00:00Z', ended_at: '2026-10-10T01:00:05Z' })).body.tick.id;
  const t2 = (await postTick(DB, { tick_key: 'watchman-b', cost_run_id: null, started_at: '2026-10-10T05:00:00Z', ended_at: '2026-10-10T05:00:05Z' })).body.tick.id;
  const f1 = finding(db, 1, { status: 'filed', claimed: '2026-10-10T02:00:00Z', updated: '2026-10-10T03:00:00Z', ticket: 'https://github.com/o/r/issues/9' });
  const f2 = finding(db, 2, { status: 'claimed', claimed: '2026-10-10T04:00:00Z', updated: '2026-10-10T04:00:00Z' });
  const o1 = outcome(db, 1, '2026-10-10T06:00:00Z');
  const d1 = decision(db, `staff:${FP(1)}`, '2026-10-10T03:30:00Z');
  const d2 = decision(db, 'staff:not-a-finding', '2026-10-10T00:30:00Z');
  finding(db, 3, { agent: 'clerk', status: 'filed', claimed: '2026-10-10T02:30:00Z', updated: '2026-10-10T02:30:00Z' });
  const r = await activity(DB, 'watchman');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(kinds(r.body), [
    `outcome:${o1}`, `tick:${t2}`, `finding.claimed:${f2}`, `decision:${d1}`, `finding.recorded:${f1}`,
    `finding.claimed:${f1}`, `tick:${t1}`, `decision:${d2}`,
  ]);
  const ev = (k) => r.body.events.find((e) => `${e.kind}:${e.id}` === k);
  assert.equal(ev(`decision:${d1}`).finding_id, f1, 'a staff:<fp> decision links its finding');
  assert.equal(ev(`decision:${d2}`).finding_id, null);
  assert.equal(ev(`outcome:${o1}`).finding_id, f1);
  assert.equal(ev(`outcome:${o1}`).ticket_url, 'https://github.com/o/r/issues/9');
  assert.equal(ev(`finding.recorded:${f1}`).status, 'filed');
  assert.equal(ev(`finding.claimed:${f2}`).finding_id, f2);
  assert.equal(ev(`tick:${t2}`).phase, 'done');
  assert.equal(ev(`tick:${t2}`).duration_s, 5);
  assert.equal(r.body.next, null);
  assert.equal(r.body.last_tick.id, t2);
  assert.equal(r.body.last_tick.started_at, '2026-10-10T05:00:00Z');
  assert.equal(r.body.cost_status, 'ok');
});

test('A5 cursor paging is exact across kinds and same-second events', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const same = '2026-10-10T03:00:00Z';
  for (const [k, ts] of [['a', '2026-10-10T01:00:00Z'], ['b', same], ['c', same], ['d', '2026-10-10T05:00:00Z']]) {
    assert.equal((await postTick(DB, { tick_key: `watchman-${k}`, cost_run_id: null, started_at: ts, ended_at: ts })).status, 201);
  }
  outcome(db, 1, same);
  finding(db, 1, { status: 'claimed', claimed: '2026-10-10T02:00:00Z', updated: '2026-10-10T02:00:00Z' });
  finding(db, 2, { status: 'digested', claimed: same, updated: '2026-10-10T04:00:00Z' });
  decision(db, 'k1', same);
  decision(db, 'k2', '2026-10-10T00:10:00Z');
  const full = await activity(DB, 'watchman', '?limit=200');
  assert.equal(full.body.events.length, 10, JSON.stringify(kinds(full.body)));
  const pages = [];
  const seenKeys = [];
  let before = '';
  for (let i = 0; i < 10; i++) {
    const r = await activity(DB, 'watchman', `?limit=3${before ? `&before=${encodeURIComponent(before)}` : ''}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    pages.push(r.body.events.length);
    seenKeys.push(...kinds(r.body));
    if (!r.body.next) break;
    before = r.body.next;
  }
  assert.deepEqual(pages, [3, 3, 3, 1]);
  assert.deepEqual(seenKeys, kinds(full.body), 'no gap, no duplicate, same order');
  // The total order at the shared second: kind DESC, then id DESC.
  const at = full.body.events.filter((e) => e.ts === same).map((e) => e.kind);
  assert.deepEqual(at, ['tick', 'tick', 'outcome', 'finding.claimed', 'decision']);
});

test('A6 archie reads archie_decisions; unknown agent 404; bad limit and before 400', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const id = Number(db.prepare(`INSERT INTO archie_decisions (escalation_key, initiative_id, class, recommendation, mode, created_at)
                         VALUES ('archie:1', 1, 'watch-continue', 'keep watching', 'ask', '2026-10-10T01:00:00Z')`).run().lastInsertRowid);
  const a = await activity(DB, 'archie');
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.deepEqual(kinds(a.body), [`decision:${id}`]);
  assert.equal(a.body.events[0].class, 'watch-continue');
  assert.equal(a.body.last_tick, null);
  assert.equal((await activity(DB, 'nobody')).status, 404);
  for (const q of ['?limit=0', '?limit=201', '?limit=x', '?before=garbage', '?before=2026-10-10T01:00:00Z~nope~1', '?before=2026-10-10T01:00:00Z~tick~0']) {
    const r = await activity(DB, 'watchman', q);
    assert.equal(r.status, 400, q);
  }
  assert.equal((await activity(DB, 'watchman', '?limit=0')).body.error, 'limit');
  assert.equal((await activity(DB, 'watchman', '?before=garbage')).body.error, 'before');
});

function costRow(db, n, runId, usd, session = `sess-fixture-${n}`) {
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, stage, model, rc, duration_s, cost_usd, session_id, run_id, inserted_at)
              VALUES ('hub', ?, ?, ?, 'staff-tick', 'stub-model', 0, 12, ?, ?, ?, '2026-10-10T00:02:00Z')`)
    .run(`h${n}`, n, `2026-10-10T00:01:0${n}Z`, usd, session, runId);
}

test('A7 a tick\'s cost comes from cost_rows by run_id; unpriced is counted, never $0', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  await postTick(DB);
  await postTick(DB, { tick_key: 'watchman-other', cost_run_id: 'staff-tick:watchman-other', started_at: '2026-10-10T02:00:00Z', ended_at: '2026-10-10T02:00:01Z' });
  costRow(db, 1, 'staff-tick:watchman-20261010t000000z-101', 0.01);
  costRow(db, 2, 'staff-tick:watchman-20261010t000000z-101', null);
  costRow(db, 3, 'build-dir-fixture', 5);
  const r = await activity(DB, 'watchman');
  const byKey = Object.fromEntries(r.body.events.map((e) => [e.cost_run_id, e]));
  const c = byKey['staff-tick:watchman-20261010t000000z-101'].cost;
  assert.equal(c.cost_usd, 0.01);
  assert.equal(c.rows, 2);
  assert.equal(c.unpriced, 1);
  assert.equal(byKey['staff-tick:watchman-other'].cost, null);
  assert.equal(r.body.cost_status, 'ok');
});

// A proxy over the D1 binding records each SQL text at prepare() and its binds
// at bind() (the retention-staff S7 recorder).
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
  const agents = ['watchman', 'clerk', 'inspector', 'archivist'];
  db.exec('BEGIN');
  const tk = db.prepare(`INSERT INTO staff_ticks (tick_key, agent, started_at, ended_at, duration_s, phase, cost_run_id, created_at)
                         VALUES (?, ?, ?, ?, 1, 'done', ?, ?)`);
  const ts = (i) => new Date(Date.UTC(2026, 6, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  for (let i = 0; i < 20000; i++) tk.run(`v-${i}`, agents[i % 4], ts(i), ts(i), `staff-tick:v-${i}`, ts(i));
  const fd = db.prepare(`INSERT INTO staff_findings (fingerprint, agent, title, source_kind, source_url, source_labels, observed_at, status, claimed_at, updated_at)
                         VALUES (?, ?, 't', 'alert', 'https://example.com/x', '[]', ?, ?, ?, ?)`);
  for (let i = 0; i < 5000; i++) fd.run(`v${String(i).padStart(63, '0')}`, agents[i % 4], ts(i * 4), i % 3 ? 'merged' : 'filed', ts(i * 4), ts(i * 4 + 1));
  const oc = db.prepare(`INSERT INTO staff_outcomes (fingerprint, agent, class, family, outcome, verdict, ticket_url, resolved_at, applied)
                         VALUES (?, ?, 'c', ?, 'merged', 'agree', 'https://github.com/o/r/issues/1', ?, 1)`);
  for (let i = 0; i < 2000; i++) oc.run(`v${String(i).padStart(63, '0')}`, agents[i % 4], 'f'.repeat(64), ts(i * 10 + 2));
  const dc = db.prepare(`INSERT INTO staff_decisions (agent, escalation_key, class, recommendation, mode, created_at) VALUES (?, ?, 'c', 'r', 'ask', ?)`);
  for (let i = 0; i < 2000; i++) dc.run(agents[i % 4], `staff:v${String(i).padStart(63, '0')}`, ts(i * 10 + 3));
  const ad = db.prepare(`INSERT INTO archie_decisions (escalation_key, initiative_id, class, recommendation, mode, created_at) VALUES (?, 1, 'c', 'r', 'ask', ?)`);
  for (let i = 0; i < 2000; i++) ad.run(`archie:${i}`, ts(i));
  const cr = db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, cost_usd, run_id, inserted_at) VALUES ('hub', ?, ?, ?, 0.01, ?, ?)`);
  for (let i = 0; i < 20000; i++) cr.run(`v${i}`, i, ts(i), i % 2 ? `build-${i}` : `staff-tick:v-${i}`, ts(i));
  db.exec('COMMIT');
}

test('A8 every statement the activity route runs uses an index, on seeded volume', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db: sql, DB } = o;
  seedVolume(sql);
  const { db, seen } = recorder(DB);
  const first = await activity(db, 'watchman', '?limit=50');
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal(first.body.events.length, 50);
  assert.ok(first.body.events.some((e) => e.kind === 'tick' && e.cost), 'the page joined a cost row');
  assert.ok(first.body.events.some((e) => (e.kind === 'outcome' || e.kind === 'decision') && e.finding_id), 'the page linked a finding');
  await activity(db, 'watchman', `?limit=50&before=${encodeURIComponent(first.body.next)}`);
  await activity(db, 'archie', '?limit=50');
  const stmts = [...seen.entries()].filter(([q]) => /\b(staff_\w+|archie_decisions|cost_rows)\b/.test(q));
  assert.ok(stmts.length >= 8, `the reads reached only ${stmts.length} statements`);
  let tickRead = false; let costRead = false;
  for (const [q, binds] of stmts) {
    const lines = sql.prepare(`EXPLAIN QUERY PLAN ${q}`).all(...binds).map((x) => x.detail);
    assert.deepEqual(scans(lines), [], `${q.replace(/\s+/g, ' ').slice(0, 160)}: ${lines.join(' | ')}`);
    if (/FROM staff_ticks\s+WHERE agent=\?1/.test(q) && /ORDER BY started_at DESC/.test(q)) {
      tickRead = true;
      assert.ok(lines.some((l) => l.includes('idx_staff_ticks_agent_started')), `tick read: ${lines.join(' | ')}`);
    }
    if (/FROM cost_rows/.test(q)) {
      costRead = true;
      assert.ok(lines.some((l) => l.includes('idx_cost_rows_run_id')), `cost read: ${lines.join(' | ')}`);
    }
  }
  assert.ok(tickRead && costRead, 'the tick read and the cost read were reached');
});

test('A9 retention staff_ticks.age: 100-day-old tick goes, 10-day-old stays, dry run removes nothing', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const NOW = Date.now();  // determinism: ok the retention route cuts at its own clock; every seeded time is an offset from it
  const ago = (d) => new Date(NOW - d * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ins = db.prepare(`INSERT INTO staff_ticks (tick_key, agent, started_at, ended_at, duration_s, phase, created_at) VALUES (?, 'watchman', ?, ?, 0, 'done', ?)`);
  ins.run('old', ago(100), ago(100), ago(100));
  ins.run('new', ago(10), ago(10), ago(10));
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='retention.staff_ticks.days'").get().value, '90');
  const run = () => call(DB, '/api/retention/run', { method: 'POST', body: {} });
  const dry = await run();
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.equal(dry.body.dry_run, true);
  assert.equal(dry.body.rules.find((x) => x.rule === 'staff_ticks.age').counted, 1);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM staff_ticks').get().n, 2, 'the dry run removed nothing');
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  const live = await run();
  assert.equal(live.body.rules.find((x) => x.rule === 'staff_ticks.age').removed, 1);
  assert.deepEqual(db.prepare('SELECT tick_key FROM staff_ticks').all().map((x) => x.tick_key), ['new']);
  const { RULES } = await import('../src/routes/retention.js');
  const r = RULES.find((x) => x.rule === 'staff_ticks.age');
  const lines = db.prepare(`EXPLAIN QUERY PLAN ${r.ids}`).all(ago(90), 10).map((x) => x.detail);
  assert.ok(lines.some((l) => l.includes('idx_staff_ticks_started')), lines.join(' | '));
});

test('A10 GET /api/staff/tick?id=: the row and its cost rows; 404; 400', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const id = (await postTick(DB)).body.tick.id;
  costRow(db, 1, 'staff-tick:watchman-20261010t000000z-101', 0.02, 'sess-fixture-a');
  costRow(db, 2, 'staff-tick:watchman-20261010t000000z-101', null, 'sess-fixture-b');
  const r = await call(DB, `/api/staff/tick?id=${id}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.tick.tick_key, 'watchman-20261010t000000z-101');
  assert.equal(r.body.tick.phase, 'done');
  assert.deepEqual(r.body.cost_rows.map((x) => x.session_id), ['sess-fixture-a', 'sess-fixture-b']);
  assert.equal(r.body.cost_rows[1].cost_usd, null);
  assert.equal((await call(DB, '/api/staff/tick?id=999')).status, 404);
  assert.equal((await call(DB, '/api/staff/tick?id=abc')).status, 400);
  // A tick with no model call reads no cost rows.
  const id2 = (await postTick(DB, { tick_key: 'watchman-x', cost_run_id: null, model_calls: 0 })).body.tick.id;
  assert.deepEqual((await call(DB, `/api/staff/tick?id=${id2}`)).body.cost_rows, []);
});

test('A11 the roster carries last_tick_at per agent; the seek uses idx_staff_ticks_agent_started', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db: sql, DB } = o;
  await postTick(DB, { tick_key: 'watchman-1', cost_run_id: null, started_at: '2026-10-10T01:00:00Z', ended_at: '2026-10-10T01:00:01Z' });
  await postTick(DB, { tick_key: 'watchman-2', cost_run_id: null, started_at: '2026-10-10T03:00:00Z', ended_at: '2026-10-10T03:00:01Z' });
  await postTick(DB, { tick_key: 'clerk-1', agent: 'clerk', cost_run_id: null, started_at: '2026-10-10T02:00:00Z', ended_at: '2026-10-10T02:00:01Z' });
  const { db, seen } = recorder(DB);
  const r = await call(db, '/api/staff/roster');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const by = Object.fromEntries(r.body.agents.map((a) => [a.name, a.last_tick_at]));
  assert.equal(by.watchman, '2026-10-10T03:00:00Z');
  assert.equal(by.clerk, '2026-10-10T02:00:00Z');
  assert.equal(by.archie, null);
  assert.equal(by.inspector, null);
  const seek = [...seen.entries()].find(([q]) => /FROM staff_ticks/.test(q));
  assert.ok(seek, 'the roster read staff_ticks');
  const lines = sql.prepare(`EXPLAIN QUERY PLAN ${seek[0]}`).all(...seek[1]).map((x) => x.detail);
  assert.ok(lines.some((l) => l.includes('idx_staff_ticks_agent_started')), lines.join(' | '));
  assert.deepEqual(scans(lines), []);
  // A database without staff_ticks still answers the roster, marked unread.
  sql.exec('DROP TABLE staff_ticks');
  const u = await call(DB, '/api/staff/roster');
  assert.equal(u.status, 200, JSON.stringify(u.body));
  assert.equal(u.body.sources.last_tick, 'unread');
  assert.ok(u.body.agents.every((a) => a.last_tick_at === null));
});
