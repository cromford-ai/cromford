// BH-5563 (BH-6730 iron law): the staff learning-loop tables have retention
// rules in the BH-6750 job, POST /api/retention/run. Driven through the REAL
// worker.fetch on node:sqlite with the composed jobs schema.
//
//   S1 staff_outcomes.age: an applied outcome past retention.staff_outcomes.days
//      and older than its agent's last change goes; one inside the window, one
//      since the agent's last change, and one not yet applied stay
//   S2 staff_promotions: a void proposal past void_days goes, an applied one
//      past applied_days goes; a recent void, a recent applied and an old
//      pending one stay
//   S3 the seeded windows are 180 / 30 / 180 days, and the seeded dry run
//      removes nothing
//   S4 every id read and delete of the staff rules uses an index
//   S5 staff_findings.done: a finished finding past 365 d goes; a recent one,
//      and an old claimed or filed one, stay
//   S5b parent and children (lead BLOCK 4): an agent whose level never changes,
//      a 400-day-old finding with its outcome and its decision: after one run
//      all three are gone; a 30-day-old one keeps all three; no outcome or
//      'staff:' decision is ever left without its finding
//   S6 staff_suppressions: an old revoked one and one long expired go; a
//      pending one, a live active one and a recent revoked one stay
//   S7 EXPLAIN QUERY PLAN for every statement the staff routes REALLY run: the
//      test drives claim, record, every outcome path, pending, precision and
//      decide through the real worker, records each SQL text and its binds at
//      D1 prepare(), and asserts each staff_* statement reads through an index
//      (the work list through idx_staff_findings_status_id), never a full scan,
//      with one named exception (the unfiltered precision read, see below)
//   S8 every staff_* table this PR writes and that grows has a retention rule
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const FP = (i) => String(i).padStart(64, '0');
const FAM = 'f'.repeat(64);

async function run(DB, body = {}) {
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const live = (db) => db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
function agent(db, name, updatedDaysAgo) {
  db.prepare(`INSERT INTO staff_agents (name, role, accountable, soul_path, updated_at) VALUES (?, 'r', 'operator', 'staff/x.md', ?)
              ON CONFLICT(name) DO UPDATE SET updated_at=excluded.updated_at`)  // the schema seeds some agents
    .run(name, ago(updatedDaysAgo));
}
function outcome(db, i, name, resolvedDaysAgo, applied = 1) {
  db.prepare(`INSERT INTO staff_outcomes (fingerprint, agent, class, family, outcome, verdict, ticket_url, resolved_at, applied)
              VALUES (?, ?, 'c', ?, 'merged', 'agree', 'https://github.com/o/r/issues/1', ?, ?)`)
    .run(FP(i), name, FAM, ago(resolvedDaysAgo), applied);
}
function promotion(db, name, status, decidedDaysAgo) {
  db.prepare(`INSERT INTO staff_promotions (agent, from_level, to_level, agreements, status, created_at, decided_at)
              VALUES (?, 'automation', 'augmentation', 5, ?, ?, ?)`)
    .run(name, status, ago(decidedDaysAgo + 1), status === 'pending' ? null : ago(decidedDaysAgo));
}
const fps = (db) => db.prepare('SELECT fingerprint FROM staff_outcomes ORDER BY id').all().map((x) => Number(x.fingerprint));

test('S1 staff_outcomes: an old applied outcome before the agent\'s last change goes; the rest stay', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  agent(db, 'clerk', 100);     // last change 100 d ago
  agent(db, 'scout', 300);     // last change 300 d ago
  outcome(db, 1, 'clerk', 200);     // past 180 d, before clerk's change: goes
  outcome(db, 2, 'clerk', 10);      // inside the window: stays
  outcome(db, 3, 'scout', 250);     // past 180 d, but since scout's change (300 d): stays
  outcome(db, 4, 'clerk', 200, 0);  // not applied (mid-batch): stays
  outcome(db, 5, 'gone', 200);      // no agent row: goes
  const r = await run(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const rule = r.body.rules.find((x) => x.rule === 'staff_outcomes.age');
  assert.equal(rule.removed, 2, JSON.stringify(rule));
  assert.deepEqual(fps(db), [2, 3, 4]);
});

test('S2 staff_promotions: old void and old applied go; recent and pending stay', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  promotion(db, 'a1', 'void', 40);      // past 30 d: goes
  promotion(db, 'a2', 'void', 5);       // stays
  promotion(db, 'a3', 'applied', 200);  // past 180 d: goes
  promotion(db, 'a4', 'applied', 40);   // stays (applied keeps 180 d)
  promotion(db, 'a5', 'pending', 400);  // pending: never removed
  const r = await run(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT agent FROM staff_promotions ORDER BY agent').all().map((x) => x.agent), ['a2', 'a4', 'a5']);
});

test('S3 the seeded windows, and the seeded dry run removes nothing', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const val = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(val('retention.staff_outcomes.days'), '180');
  assert.equal(val('retention.staff_promotions.void_days'), '30');
  assert.equal(val('retention.staff_promotions.applied_days'), '180');
  outcome(db, 1, 'gone', 400); promotion(db, 'a1', 'void', 400);
  const r = await run(DB);
  assert.equal(r.body.dry_run, true);
  assert.equal(r.body.rules.find((x) => x.rule === 'staff_outcomes.age').counted, 1);
  assert.equal(r.body.rules.find((x) => x.rule === 'staff_promotions.void').counted, 1);
  assert.deepEqual(fps(db), [1]);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM staff_promotions').get().n, 1);
});

test('S4 every id read and delete of the staff rules uses an index', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  const { RULES } = await import('../src/routes/retention.js');
  const staff = RULES.filter((r) => r.table.startsWith('staff_'));
  // TEST-CHANGE (merge BH-6822 + BH-6824): staff_ticks.age and staff_autonomy_changes.age
  // are the seventh and eighth staff_* rules.
  assert.equal(staff.length, 8);
  for (const r of staff) {
    for (const sql of [r.ids, ...(r.pre || []), r.del]) {
      const lines = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...(sql === r.ids ? [ago(30), 10] : ['[1]'])).map((x) => x.detail);
      const bad = lines.filter((l) => /^SCAN (staff_\w+|o|a)\b/.test(l) && !/USING (INDEX|PRIMARY KEY|INTEGER PRIMARY KEY|COVERING INDEX)/.test(l));
      assert.deepEqual(bad, [], `${r.rule}: ${lines.join(' | ')}`);
    }
  }
});

function finding(db, i, status, updatedDaysAgo, agentName = 'watchman') {
  db.prepare(`INSERT INTO staff_findings (fingerprint, agent, title, source_kind, source_url, source_labels, observed_at, status, ticket_url, claimed_at, updated_at)
              VALUES (?, ?, 't', 'issue', 'https://x', '[]', ?, ?, ?, ?, ?)`)
    .run(FP(i), agentName, ago(updatedDaysAgo + 1), status, status === 'claimed' ? null : 'https://github.com/o/r/issues/' + i,
      ago(updatedDaysAgo + 1), ago(updatedDaysAgo));
}
function decision(db, i, agentName = 'watchman') {
  db.prepare(`INSERT INTO staff_decisions (agent, escalation_key, class, recommendation, mode, choice, counted, created_at)
              VALUES (?, ?, 'c', 'r', 'ask', 'approve', 1, ?)`).run(agentName, 'staff:' + FP(i), ago(400));
}
function suppression(db, i, status, createdDaysAgo, expiresDaysAgo) {
  db.prepare(`INSERT INTO staff_suppressions (fingerprint, reason, approver, expires_at, status, created_at) VALUES (?, 'r', ?, ?, ?, ?)`)
    .run(FP(i), status === 'pending' ? null : 'operator', ago(expiresDaysAgo), status, ago(createdDaysAgo));
}
const dangling = (db) => ({
  outcomes: db.prepare('SELECT COUNT(*) n FROM staff_outcomes o WHERE NOT EXISTS (SELECT 1 FROM staff_findings f WHERE f.fingerprint = o.fingerprint)').get().n,
  decisions: db.prepare(`SELECT COUNT(*) n FROM staff_decisions d WHERE d.escalation_key LIKE 'staff:%'
                          AND NOT EXISTS (SELECT 1 FROM staff_findings f WHERE 'staff:' || f.fingerprint = d.escalation_key)`).get().n,
});

test('S5 staff_findings: a finished finding past 365 d goes; recent, claimed and filed stay', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  finding(db, 1, 'merged', 400);     // goes
  finding(db, 2, 'noise', 400);      // goes
  finding(db, 3, 'rejected', 30);    // recent: stays
  finding(db, 4, 'claimed', 400);    // live work: stays
  finding(db, 5, 'filed', 400);      // live work: stays
  finding(db, 6, 'digested', 400);   // finished without a ticket: goes
  finding(db, 7, 'failed', 400);     // goes
  const r = await run(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT fingerprint FROM staff_findings ORDER BY id').all().map((x) => Number(x.fingerprint)), [3, 4, 5]);
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='retention.staff_findings.done_days'").get().value, '365');
});

test('S5b a stable agent: a 400-day-old finding goes with its outcome and decision; a 30-day-old one keeps all three', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  agent(db, 'steady', 900);                         // level never changed since 900 d ago
  finding(db, 1, 'merged', 400, 'steady'); outcome(db, 1, 'steady', 400); decision(db, 1, 'steady');
  finding(db, 2, 'merged', 30, 'steady'); outcome(db, 2, 'steady', 30); decision(db, 2, 'steady');
  const r = await run(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT fingerprint FROM staff_findings').all().map((x) => Number(x.fingerprint)), [2]);
  assert.deepEqual(fps(db), [2], 'the outcome went with its finding, the recent one stayed');
  assert.deepEqual(db.prepare("SELECT escalation_key FROM staff_decisions WHERE escalation_key LIKE 'staff:%'").all().map((x) => x.escalation_key), ['staff:' + FP(2)]);
  assert.deepEqual(dangling(db), { outcomes: 0, decisions: 0 });
  // A second run, and an outcome rule that already took an outcome alone: still none dangling.
  outcome(db, 3, 'steady', 10); finding(db, 3, 'merged', 10, 'steady');
  await run(DB);
  assert.deepEqual(dangling(db), { outcomes: 0, decisions: 0 });
});

test('S6 staff_suppressions: old revoked and long-expired go; pending, live and recent stay', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  suppression(db, 1, 'revoked', 200, 150);   // revoked, created 200 d ago: goes
  suppression(db, 2, 'revoked', 10, -20);    // revoked recently: stays
  suppression(db, 3, 'active', 300, 200);    // expired 200 d ago: goes
  suppression(db, 4, 'active', 300, -30);    // still active: stays
  suppression(db, 5, 'active', 100, 10);     // expired 10 d ago: stays
  suppression(db, 6, 'pending', 400, 300);   // a noise proposal: never goes
  const r = await run(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT fingerprint FROM staff_suppressions ORDER BY id').all().map((x) => Number(x.fingerprint)), [2, 4, 5, 6]);
});

// ── S7: record what the routes really prepare ────────────────────────────────
// A proxy over the D1 binding records each SQL text at prepare() and its binds
// at bind(). The flows below reach every staff statement BH-5563 adds or
// changes; the recorded statements are then EXPLAINed as run.
function recorder(DB) {
  const seen = new Map();   // sql -> last binds
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
const callAs = (DB, method, path, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
let item = 0;
async function fileOne(DB, cls = 'leak', agentName = 'watchman') {
  item += 1;
  const c = await callAs(DB, 'POST', '/api/staff/findings/claim', {
    agent: agentName, item: { id: `s7-item-${item}` }, title: `S7 finding ${item}`, class: cls,
    source: { kind: 'alert', url: `https://example.com/s7-${item}`, labels: [] }, observedAt: ago(0),
  });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  const url = `https://github.com/o/r/issues/${7000 + item}`;
  const r = await callAs(DB, 'POST', '/api/staff/findings/record', { agent: agentName, fingerprint: c.body.fingerprint, outcome: 'filed', mode: 'ask', ticket_url: url, class: cls });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { agent: agentName, fingerprint: c.body.fingerprint, ticket_url: url };
}
// The one accepted scan (lead review 2026-10-15, NOTE): GET /api/staff/precision
// with no agent reads every applied outcome. Only a person calls the route; an
// index on applied=1 would not be selective. The /staff screen follow-up must
// give it a summary table.
const ACCEPTED_SCAN = /^SELECT agent, class, verdict FROM staff_outcomes WHERE applied=1\s+ORDER BY id$/;
const scans = (lines) => lines.filter((l) => /^SCAN (staff_\w+|[a-z])\b/.test(l) && !/USING (INDEX|PRIMARY KEY|INTEGER PRIMARY KEY|COVERING INDEX)/.test(l));

test('S7 every staff_* statement the routes really run uses an index', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db: sql, DB } = o;
  const { db, seen } = recorder(DB);
  sql.prepare("UPDATE staff_agents SET cap='autonomy' WHERE name='watchman'").run();
  sql.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('staff.delegate_after','1','','t',?) ON CONFLICT(key) DO UPDATE SET value='1'").run(ago(0));
  // agree (promotion proposal, then apply on the next agree after a level raise)
  const a = await fileOne(db); assert.equal((await callAs(db, 'POST', '/api/staff/outcomes', { ...a, outcome: 'merged' })).status, 200);
  sql.prepare("UPDATE staff_agents SET autonomy='augmentation' WHERE name='watchman'").run();
  const b = await fileOne(db); await callAs(db, 'POST', '/api/staff/outcomes', { ...b, outcome: 'merged' });
  // overrule (demotion, void)
  const c = await fileOne(db); await callAs(db, 'POST', '/api/staff/outcomes', { ...c, outcome: 'rejected' });
  // noise x3 in one family: window, marker, proposal; then the pending decide
  for (let i = 0; i < 4; i++) { const n = await fileOne(db, 'noisy'); await callAs(db, 'POST', '/api/staff/outcomes', { ...n, outcome: 'noise' }); }
  // a replay (prior row read)
  await callAs(db, 'POST', '/api/staff/outcomes', { ...a, outcome: 'merged' });
  await callAs(db, 'GET', '/api/staff/outcomes/pending?after_id=0&limit=50');
  await callAs(db, 'GET', '/api/staff/precision');
  await callAs(db, 'GET', '/api/staff/precision?agent=watchman');
  const pend = sql.prepare("SELECT id FROM staff_suppressions WHERE status='pending' ORDER BY id LIMIT 1").get();
  assert.ok(pend, 'the noise flow made a pending suppression');
  assert.equal((await callAs(db, 'POST', '/api/staff/suppressions/decide', { id: pend.id, decision: 'approve', approver: 'the operator' })).status, 200);
  const sup = await callAs(db, 'POST', '/api/staff/findings/claim', {   // a claim now meets the family suppression
    agent: 'watchman', item: { id: 's7-suppressed' }, title: 'S7 suppressed', class: 'noisy',
    source: { kind: 'alert', url: 'https://example.com/s7-suppressed', labels: [] }, observedAt: ago(0),
  });
  assert.equal(sup.body && sup.body.error, 'suppressed', JSON.stringify(sup.body));

  const staffSql = [...seen.entries()].filter(([q]) => /\bstaff_\w+/.test(q));
  assert.ok(staffSql.length >= 20, `the flows reached only ${staffSql.length} staff statements`);
  let workList = false; let accepted = 0;
  for (const [q, binds] of staffSql) {
    const lines = sql.prepare(`EXPLAIN QUERY PLAN ${q}`).all(...binds).map((x) => x.detail);
    if (ACCEPTED_SCAN.test(q.trim())) { accepted += 1; assert.equal(scans(lines).length, 1, `the accepted scan changed: ${lines.join(' | ')}`); continue; }
    assert.deepEqual(scans(lines), [], `${q.replace(/\s+/g, ' ').slice(0, 160)}: ${lines.join(' | ')}`);
    if (/status='filed' AND ticket_url IS NOT NULL AND id > \?1/.test(q)) {
      workList = true;
      assert.ok(lines.some((l) => l.includes('idx_staff_findings_status_id')), `the work list: ${lines.join(' | ')}`);
    }
  }
  assert.ok(workList, 'the work-list statement was not reached');
  assert.equal(accepted, 1, 'the unfiltered precision read was not reached');
});

test('S8 every growing staff_* table this PR writes has a retention rule', async () => {
  const { RULES } = await import('../src/routes/retention.js');
  const covered = new Set(RULES.map((r) => r.table));
  // staff_agents and staff_classes are bounded (one row per agent, per agent x
  // class). staff_decisions 'staff:<fp>' rows go with their finding (pre).
  for (const tbl of ['staff_outcomes', 'staff_promotions', 'staff_findings', 'staff_suppressions']) {
    assert.ok(covered.has(tbl), `${tbl} has no retention rule`);
  }
  const f = RULES.find((r) => r.rule === 'staff_findings.done');
  assert.ok(f.pre.some((q) => /DELETE FROM staff_outcomes/.test(q)) && f.pre.some((q) => /DELETE FROM staff_decisions/.test(q)),
    'a finding must take its outcome and decision rows with it');
});
