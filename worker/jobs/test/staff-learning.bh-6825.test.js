// BH-6825 (Staff in Mission Control 4/4): the learning view's three routes,
// driven through the REAL worker.fetch against the composed schema (the
// node:sqlite D1 shim). The clock is pinned: `new Date()` and Date.now() answer
// NOW for the whole file, so the route's own server time (nowIso) is NOW too
// and every window cutoff is exact.
//   L1-L6  GET /api/staff/learning: the window counts, precision and noise,
//          absent is null (never 0), the window boundary, the settings rows,
//          the pending promotion with its capped evidence, the newest decisions
//   P1-P4  GET /api/staff/learning/outcomes: one count's rows, the cursor pages
//          (no gap, no overlap), strict params, a removed finding, 404
//   D1-D9  POST /api/staff/promotions/decide: approve raises the agent and
//          applies the promotion with the reason; replay; agent approver;
//          stale level, above cap, paused agent; bad bodies; void; the loop
//          voided it first. Every refusal writes nothing.
//   R1     retention: a decision row goes with its void promotion
//   X1     EXPLAIN QUERY PLAN of every statement the three routes run, on
//          seeded volume: no full scan of a staff table
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { windowCutoff } from '../src/routes/staff-learning.js';

const NOW_ISO = '2026-10-16T00:00:00Z';
const NOW = Date.parse(NOW_ISO);
const RealDate = Date;
class FixedDate extends RealDate {
  constructor(...a) { if (a.length) super(...a); else super(NOW); }
  static now() { return NOW; }
}
globalThis.Date = FixedDate;

const SECRET = 'test-secret';
const call = (DB, method, path, body) => {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const get = (DB, path) => call(DB, 'GET', path);
const decide = (DB, body) => call(DB, 'POST', '/api/staff/promotions/decide', body);

const iso = (ms) => new RealDate(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days, secs = 0) => iso(NOW - days * 86400e3 - secs * 1000);
const FP = (i) => String(i).padStart(64, '0');
const VERDICT = { merged: 'agree', rejected: 'overrule', noise: 'overrule' };

// One finding and its outcome, in the shape POST /api/staff/outcomes writes.
let seq = 0;
function seedOutcome(db, agent, outcome, resolvedAt, { applied = 1, withFinding = true } = {}) {
  seq += 1;
  const fp = FP(seq);
  if (withFinding) {
    db.prepare(`INSERT INTO staff_findings (fingerprint, agent, title, source_kind, source_url, source_labels, observed_at, status, ticket_url, claimed_at, updated_at)
                VALUES (?, ?, ?, 'alert', 'https://example.com/a', '[]', ?, ?, ?, ?, ?)`)
      .run(fp, agent, `Fixture finding ${seq}`, resolvedAt, outcome, `https://github.com/o/r/issues/${seq}`, resolvedAt, resolvedAt);
  }
  const r = db.prepare(`INSERT INTO staff_outcomes (fingerprint, agent, class, family, outcome, verdict, ticket_url, resolved_at, applied)
              VALUES (?, ?, 'leak', ?, ?, ?, ?, ?, ?)`)
    .run(fp, agent, 'f'.repeat(64), outcome, VERDICT[outcome], `https://github.com/o/r/issues/${seq}`, resolvedAt, applied);
  const f = withFinding ? db.prepare('SELECT id FROM staff_findings WHERE fingerprint=?').get(fp) : null;
  return { outcomeId: Number(r.lastInsertRowid), findingId: f ? f.id : null, fp };
}
const setSetting = (db, key, value) =>
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','test',?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, value, NOW_ISO);
const agentRow = (db, a) => db.prepare('SELECT * FROM staff_agents WHERE name=?').get(a);
const promo = (db, id) => db.prepare('SELECT * FROM staff_promotions WHERE id=?').get(id);
const decisions = (db) => db.prepare('SELECT * FROM staff_promotion_decisions ORDER BY id').all();
function seedPromotion(db, agent, { from = 'automation', to = 'augmentation', status = 'pending', createdAt = ago(1), decidedAt = null } = {}) {
  const r = db.prepare(`INSERT INTO staff_promotions (agent, from_level, to_level, agreements, status, created_at, decided_at)
                        VALUES (?, ?, ?, 5, ?, ?, ?)`).run(agent, from, to, status, createdAt, decidedAt);
  return Number(r.lastInsertRowid);
}

// A pending promotion made by the REAL loop: claim, record filed, merged.
let item = 0;
async function proposeThroughLoop(DB, db, agent = 'watchman') {
  setSetting(db, 'staff.delegate_after', '1');
  const f = await fileOne(DB, agent);
  const r = await call(DB, 'POST', '/api/staff/outcomes', { ...f, outcome: 'merged' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.proposals.promotion_id, `the loop proposed: ${JSON.stringify(r.body)}`);
  return r.body.proposals.promotion_id;
}
async function fileOne(DB, agent) {
  item += 1;
  const c = await call(DB, 'POST', '/api/staff/findings/claim', {
    agent, item: { id: `bh6825-item-${item}` }, title: `Fixture finding L${item}`, class: 'leak',
    source: { kind: 'alert', url: `https://example.com/alerts/bh6825-${item}`, labels: [] }, observedAt: NOW_ISO,
  });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  const url = `https://github.com/example-org/cromford/issues/${9000 + item}`;
  const r = await call(DB, 'POST', '/api/staff/findings/record', {
    agent, fingerprint: c.body.fingerprint, outcome: 'filed', mode: 'ask', ticket_url: url, class: 'leak',
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { agent, fingerprint: c.body.fingerprint, ticket_url: url };
}

const open = async (t) => {
  const o = await openDb();
  if (o === null) { t.skip('node:sqlite unavailable in this runtime'); return null; }
  return o;
};

// ── GET /api/staff/learning ──────────────────────────────────────────────────
test('L1 the two windows: counts, precision and noise rate of one agent; applied=0, older and other agents are out', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  seedOutcome(db, 'watchman', 'merged', ago(2));
  seedOutcome(db, 'watchman', 'noise', ago(3));
  seedOutcome(db, 'watchman', 'rejected', ago(10));
  seedOutcome(db, 'watchman', 'merged', ago(20));
  seedOutcome(db, 'watchman', 'merged', ago(40));
  seedOutcome(db, 'watchman', 'merged', ago(1), { applied: 0 });
  seedOutcome(db, 'inspector', 'noise', ago(1));
  const r = await get(DB, '/api/staff/learning?agent=watchman');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const [s, l] = r.body.windows;
  assert.equal(s.days, 7); assert.equal(s.source, 'settings');
  assert.equal(s.total, 2); assert.equal(s.merged, 1); assert.equal(s.noise, 1); assert.equal(s.rejected, 0);
  assert.equal(s.agree, 1); assert.equal(s.overrule, 1);
  assert.equal(s.precision, 0.5); assert.equal(s.noise_rate, 0.5);
  assert.equal(l.days, 30);
  assert.equal(l.total, 4); assert.equal(l.merged, 2); assert.equal(l.rejected, 1); assert.equal(l.noise, 1);
  assert.equal(l.precision, 0.5); assert.equal(l.noise_rate, 0.25);
  assert.equal(r.body.agent.name, 'watchman');
  assert.equal(r.body.agent.autonomy, 'automation');
});

test('L2 an agent with no outcomes: totals 0, precision and noise rate null (never 0), no proposal, no decisions', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await get(o.DB, '/api/staff/learning?agent=clerk');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  for (const w of r.body.windows) {
    assert.equal(w.total, 0);
    assert.equal(w.precision, null);
    assert.equal(w.noise_rate, null);
  }
  assert.equal(r.body.promotion, null);
  assert.deepEqual(r.body.decisions, []);
});

test('L3 windowCutoff, and the boundary: a row at the cutoff counts, one second earlier does not', async (t) => {
  assert.equal(windowCutoff('2026-10-16T00:00:00Z', 7), '2026-10-09T00:00:00Z');
  assert.equal(windowCutoff('2026-03-01T12:30:05Z', 1), '2026-02-28T12:30:05Z');
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  setSetting(db, 'staff.learning.short_days', '7');
  seedOutcome(db, 'watchman', 'merged', '2026-10-09T00:00:00Z');
  seedOutcome(db, 'watchman', 'merged', '2026-10-08T23:59:59Z');
  const r = await get(DB, '/api/staff/learning?agent=watchman');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.windows[0].total, 1, JSON.stringify(r.body.windows[0]));
  assert.equal(r.body.windows[1].total, 2);
});

test('L4 the window settings: junk or 0 is the default 7, named "default"; 14 is used, named "settings"', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  for (const junk of ['abc', '0', '366', '']) {
    setSetting(db, 'staff.learning.short_days', junk);
    const r = await get(DB, '/api/staff/learning?agent=watchman');
    assert.equal(r.body.windows[0].days, 7, junk);
    assert.equal(r.body.windows[0].source, 'default', junk);
  }
  setSetting(db, 'staff.learning.short_days', '14');
  setSetting(db, 'staff.learning.long_days', '60');
  const r = await get(DB, '/api/staff/learning?agent=watchman');
  assert.equal(r.body.windows[0].days, 14);
  assert.equal(r.body.windows[0].source, 'settings');
  assert.equal(r.body.windows[1].days, 60);
  db.prepare("DELETE FROM settings WHERE key='staff.learning.long_days'").run();
  const r2 = await get(DB, '/api/staff/learning?agent=watchman');
  assert.equal(r2.body.windows[1].days, 30);
  assert.equal(r2.body.windows[1].source, 'default');
  assert.equal(r2.body.retention_days.value, 180);
});

test('L5 the pending promotion: evidence since the last level change, newest 20 of 25, real finding ids; stale after a level change', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  db.prepare("UPDATE staff_agents SET updated_at=? WHERE name='watchman'").run(ago(28));
  for (let i = 0; i < 3; i++) seedOutcome(db, 'watchman', 'merged', ago(35 + i));
  const since = [];
  for (let i = 0; i < 25; i++) since.push(seedOutcome(db, 'watchman', 'merged', ago(25 - i)));
  seedOutcome(db, 'watchman', 'merged', ago(0, 30), { applied: 0 });
  const id = seedPromotion(db, 'watchman');
  const r = await get(DB, '/api/staff/learning?agent=watchman');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const p = r.body.promotion;
  assert.equal(p.id, id);
  assert.equal(p.from_level, 'automation'); assert.equal(p.to_level, 'augmentation');
  assert.equal(p.stale, false);
  assert.equal(p.evidence.rows.length, 20);
  assert.equal(p.evidence.total, 25);
  assert.equal(p.evidence.truncated, true);
  const newest = since.slice().reverse().slice(0, 20);
  assert.deepEqual(p.evidence.rows.map((x) => x.id), newest.map((x) => x.outcomeId));
  assert.deepEqual(p.evidence.rows.map((x) => x.finding_id), newest.map((x) => x.findingId));
  db.prepare("UPDATE staff_agents SET autonomy='augmentation' WHERE name='watchman'").run();
  const r2 = await get(DB, '/api/staff/learning?agent=watchman');
  assert.equal(r2.body.promotion.stale, true);
});

test('L6 the newest 5 decisions, newest first, with a more flag; 404 unknown; 400 a bad name; the name is case-folded', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  for (let i = 0; i < 7; i++) {
    const pid = seedPromotion(db, 'watchman', { status: 'void', decidedAt: ago(10 - i) });
    db.prepare(`INSERT INTO staff_promotion_decisions (promotion_id, agent, decision, from_level, to_level, reason, actor, decided_at)
                VALUES (?, 'watchman', 'void', 'automation', 'augmentation', ?, 'operator@example.com', ?)`).run(pid, `reason ${i}`, ago(10 - i));
  }
  const r = await get(DB, '/api/staff/learning?agent=%20WATCHMAN%20');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.decisions.map((d) => d.reason), ['reason 6', 'reason 5', 'reason 4', 'reason 3', 'reason 2']);
  assert.equal(r.body.decisions_more, true);
  assert.equal((await get(DB, '/api/staff/learning?agent=nobody')).status, 404);
  const bad = await get(DB, '/api/staff/learning?agent=Bad%20Name');
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error, 'agent');
  assert.equal((await get(DB, '/api/staff/learning')).status, 400);
});

// ── GET /api/staff/learning/outcomes ─────────────────────────────────────────
test('P1 one count\'s rows: only that agent, that outcome, that window, newest first, with the finding id', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const a = seedOutcome(db, 'watchman', 'noise', ago(3));
  seedOutcome(db, 'watchman', 'merged', ago(2));
  const b = seedOutcome(db, 'watchman', 'noise', ago(1));
  seedOutcome(db, 'watchman', 'noise', ago(31));
  seedOutcome(db, 'inspector', 'noise', ago(1));
  const r = await get(DB, '/api/staff/learning/outcomes?agent=watchman&days=30&outcome=noise');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.id), [b.outcomeId, a.outcomeId]);
  assert.deepEqual(r.body.rows.map((x) => x.finding_id), [b.findingId, a.findingId]);
  assert.ok(r.body.rows.every((x) => x.outcome === 'noise' && x.ticket_url && x.resolved_at && x.class === 'leak'));
  assert.equal(r.body.truncated, false);
  assert.equal(r.body.next_before, null);
  const all = await get(DB, '/api/staff/learning/outcomes?agent=watchman&days=30');
  assert.equal(all.body.rows.length, 3);
});

test('P2 250 rows paged by 100: no gap, no overlap, ties on resolved_at broken by id; bad params are 400, never clamped', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const ids = [];
  for (let i = 0; i < 250; i++) ids.push(seedOutcome(db, 'quartermaster', 'merged', ago(1 + (i % 10))).outcomeId);
  const base = '/api/staff/learning/outcomes?agent=quartermaster&days=30&limit=100';
  const p1 = await get(DB, base);
  assert.equal(p1.status, 200, JSON.stringify(p1.body));
  assert.equal(p1.body.rows.length, 100); assert.equal(p1.body.truncated, true);
  assert.match(p1.body.next_before, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\|\d+$/);
  const p2 = await get(DB, `${base}&before=${encodeURIComponent(p1.body.next_before)}`);
  assert.equal(p2.body.rows.length, 100); assert.equal(p2.body.truncated, true);
  const p3 = await get(DB, `${base}&before=${encodeURIComponent(p2.body.next_before)}`);
  assert.equal(p3.body.rows.length, 50); assert.equal(p3.body.truncated, false); assert.equal(p3.body.next_before, null);
  const got = [...p1.body.rows, ...p2.body.rows, ...p3.body.rows];
  assert.equal(new Set(got.map((x) => x.id)).size, 250, 'no overlap');
  assert.deepEqual(got.map((x) => x.id).sort((x, y) => x - y), ids.slice().sort((x, y) => x - y), 'no gap');
  for (let i = 1; i < got.length; i++) {
    const [x, y] = [got[i - 1], got[i]];
    assert.ok(x.resolved_at > y.resolved_at || (x.resolved_at === y.resolved_at && x.id > y.id), `order at ${i}`);
  }
  // The default page is the settings row page_max.
  setSetting(db, 'staff.learning.page_max', '40');
  const d = await get(DB, '/api/staff/learning/outcomes?agent=quartermaster&days=30');
  assert.equal(d.body.rows.length, 40);
  assert.equal((await get(DB, `${base.replace('limit=100', 'limit=41')}`)).status, 400, 'over page_max');
  for (const [q, field] of [
    ['limit=0', 'limit'], ['limit=201', 'limit'], ['limit=abc', 'limit'], ['days=0', 'days'], ['days=366', 'days'],
    ['days=7.5', 'days'], ['outcome=x', 'outcome'], ['before=junk', 'before'], ['before=2026-10-01T00:00:00Z', 'before'],
    ['before=2026-13-01T00:00:00Z%7C5', 'before'],
  ]) {
    const u = `/api/staff/learning/outcomes?agent=quartermaster&days=30&${q}`.replace('days=30&days', 'days');
    const r = await get(DB, u);
    assert.equal(r.status, 400, `${q}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, field, q);
  }
  assert.equal((await get(DB, '/api/staff/learning/outcomes?agent=quartermaster')).body.error, 'days', 'days is required');
});

test('P3 a row whose finding retention removed has finding_id null', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  seedOutcome(db, 'watchman', 'rejected', ago(2), { withFinding: false });
  const r = await get(DB, '/api/staff/learning/outcomes?agent=watchman&days=7');
  assert.equal(r.body.rows.length, 1);
  assert.equal(r.body.rows[0].finding_id, null);
});

test('P4 an unknown agent is 404, a bad name 400', async (t) => {
  const o = await open(t); if (!o) return;
  assert.equal((await get(o.DB, '/api/staff/learning/outcomes?agent=nobody&days=7')).status, 404);
  assert.equal((await get(o.DB, '/api/staff/learning/outcomes?agent=Bad%20Name&days=7')).body.error, 'agent');
});

// ── POST /api/staff/promotions/decide ────────────────────────────────────────
const snapshot = (db, pid) => JSON.stringify({ a: agentRow(db, 'watchman'), p: promo(db, pid), d: decisions(db) });

test('D1 approve: the agent rises, the promotion is applied, the reason is recorded; the read-back and the GET agree', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  const r = await decide(DB, { id: pid, decision: 'approve', reason: ' earned it ', actor: 'operator@example.com' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.existing, undefined);
  assert.equal(r.body.promotion.status, 'applied');
  assert.equal(r.body.promotion.decided_at, NOW_ISO);
  assert.equal(r.body.decision.decision, 'approve');
  assert.equal(r.body.decision.reason, 'earned it');
  assert.equal(r.body.decision.actor, 'operator@example.com');
  assert.equal(r.body.agent.autonomy, 'augmentation');
  const a = agentRow(db, 'watchman');
  assert.equal(a.autonomy, 'augmentation');
  assert.equal(a.updated_at, NOW_ISO);
  assert.equal(a.note, `autonomy augmentation by operator@example.com (promotion #${pid})`);
  assert.equal(promo(db, pid).status, 'applied');
  assert.equal(decisions(db).length, 1);
  const g = await get(DB, '/api/staff/learning?agent=watchman');
  assert.equal(g.body.promotion, null);
  assert.equal(g.body.decisions[0].promotion_id, pid);
  assert.equal(g.body.decisions[0].reason, 'earned it');
  assert.equal(g.body.decisions[0].actor, 'operator@example.com');
});

test('D2 a replay of the same decision is 200 existing and writes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  assert.equal((await decide(DB, { id: pid, decision: 'approve', reason: 'earned it', actor: 'operator@example.com' })).status, 200);
  const before = snapshot(db, pid);
  const r = await decide(DB, { id: pid, decision: 'approve', reason: 'again', actor: 'operator@example.com' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.existing, true);
  assert.equal(r.body.decision.reason, 'earned it');
  assert.equal(snapshot(db, pid), before);
  const v = await decide(DB, { id: pid, decision: 'void', reason: 'changed my mind', actor: 'operator@example.com' });
  assert.equal(v.status, 409);
  assert.equal(v.body.error, 'not_pending');
  assert.equal(v.body.status, 'applied');
});

test('D3 archie or a staff agent as the actor is 403 agent_approver, for approve and void; nothing written', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  const before = snapshot(db, pid);
  for (const actor of ['archie', 'Archie ', 'WATCHMAN', ' watchman ', 'inspector']) {
    for (const decision of ['approve', 'void']) {
      const r = await decide(DB, { id: pid, decision, reason: 'self', actor });
      assert.equal(r.status, 403, `${actor} ${decision}`);
      assert.equal(r.body.error, 'agent_approver');
    }
  }
  assert.equal(snapshot(db, pid), before);
});

test('D4 the level moved by hand after the proposal: 409 stale_level; still pending, no decision row', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  db.prepare("UPDATE staff_agents SET autonomy='augmentation', updated_at=? WHERE name='watchman'").run(ago(0, 5));
  const before = snapshot(db, pid);
  const r = await decide(DB, { id: pid, decision: 'approve', reason: 'late', actor: 'operator@example.com' });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'stale_level');
  assert.equal(r.body.autonomy, 'augmentation');
  assert.equal(snapshot(db, pid), before);
  assert.equal(promo(db, pid).status, 'pending');
});

test('D5 the cap lowered below the target after the proposal: 409 above_cap; nothing written', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  db.prepare("UPDATE staff_agents SET cap='automation' WHERE name='watchman'").run();
  const before = snapshot(db, pid);
  const r = await decide(DB, { id: pid, decision: 'approve', reason: 'cap', actor: 'operator@example.com' });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'above_cap');
  assert.equal(r.body.cap, 'automation');
  assert.equal(snapshot(db, pid), before);
});

test('D6 a paused agent: 409 agent_not_active; nothing written', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  db.prepare("UPDATE staff_agents SET status='paused' WHERE name='watchman'").run();
  const before = snapshot(db, pid);
  const r = await decide(DB, { id: pid, decision: 'approve', reason: 'paused', actor: 'operator@example.com' });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'agent_not_active');
  assert.equal(r.body.status, 'paused');
  assert.equal(snapshot(db, pid), before);
});

test('D7 bad bodies are 400 naming the field; an unknown id is 404; nothing written', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  const before = snapshot(db, pid);
  const good = { id: pid, decision: 'approve', reason: 'ok', actor: 'operator@example.com' };
  for (const [over, field] of [
    [{ reason: '   ' }, 'reason'], [{ reason: 'x'.repeat(501) }, 'reason'], [{ reason: 7 }, 'reason'],
    [{ id: String(pid) }, 'id'], [{ id: 0 }, 'id'], [{ id: 1.5 }, 'id'],
    [{ decision: 'applied' }, 'decision'], [{ actor: '' }, 'actor'], [{ actor: undefined }, 'actor'],
  ]) {
    const r = await decide(DB, { ...good, ...over });
    assert.equal(r.status, 400, JSON.stringify(over));
    assert.equal(r.body.error, field, JSON.stringify(over));
  }
  const nf = await decide(DB, { ...good, id: 99999 });
  assert.equal(nf.status, 404);
  assert.equal(snapshot(db, pid), before);
  assert.equal((await decide(DB, { ...good, reason: 'x'.repeat(500) })).status, 200, '500 characters is the edge, allowed');
});

test('D8 void: the promotion is void with the reason, the level does not move; approve after it is 409 not_pending', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  const r = await decide(DB, { id: pid, decision: 'void', reason: 'too early', actor: 'operator@example.com' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.promotion.status, 'void');
  assert.equal(r.body.decision.decision, 'void');
  assert.equal(r.body.decision.reason, 'too early');
  assert.equal(r.body.agent.autonomy, 'automation');
  assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
  assert.equal(promo(db, pid).status, 'void');
  assert.equal(promo(db, pid).decided_at, NOW_ISO);
  const replay = await decide(DB, { id: pid, decision: 'void', reason: 'again', actor: 'operator@example.com' });
  assert.equal(replay.status, 200);
  assert.equal(replay.body.existing, true);
  const a = await decide(DB, { id: pid, decision: 'approve', reason: 'now', actor: 'operator@example.com' });
  assert.equal(a.status, 409);
  assert.equal(a.body.error, 'not_pending');
  assert.equal(a.body.status, 'void');
  assert.equal(decisions(db).length, 1);
});

test('D9 an overrule outcome voids the proposal first: approve is 409 not_pending, no decision row', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  const pid = await proposeThroughLoop(DB, db);
  const f = await fileOne(DB, 'watchman');
  const ov = await call(DB, 'POST', '/api/staff/outcomes', { ...f, outcome: 'rejected' });
  assert.equal(ov.status, 200, JSON.stringify(ov.body));
  assert.equal(promo(db, pid).status, 'void');
  const r = await decide(DB, { id: pid, decision: 'approve', reason: 'late', actor: 'operator@example.com' });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'not_pending');
  assert.equal(decisions(db).length, 0);
  assert.equal(agentRow(db, 'watchman').autonomy, 'automation');
});

// ── retention ────────────────────────────────────────────────────────────────
test('R1 retention: a void promotion past void_days goes with its decision row; a recent one keeps its row', async (t) => {
  const o = await open(t); if (!o) return;
  const { db, DB } = o;
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  const addDecision = (pid, at) => db.prepare(`INSERT INTO staff_promotion_decisions (promotion_id, agent, decision, from_level, to_level, reason, actor, decided_at)
              VALUES (?, 'watchman', 'void', 'automation', 'augmentation', 'r', 'operator@example.com', ?)`).run(pid, at);
  const old = seedPromotion(db, 'watchman', { status: 'void', decidedAt: ago(40), createdAt: ago(41) });
  addDecision(old, ago(40));
  const recent = seedPromotion(db, 'watchman', { status: 'void', decidedAt: ago(5), createdAt: ago(6) });
  addDecision(recent, ago(5));
  const oldApplied = seedPromotion(db, 'inspector', { status: 'applied', decidedAt: ago(200), createdAt: ago(201) });
  db.prepare(`INSERT INTO staff_promotion_decisions (promotion_id, agent, decision, from_level, to_level, reason, actor, decided_at)
              VALUES (?, 'inspector', 'approve', 'automation', 'augmentation', 'r', 'operator@example.com', ?)`).run(oldApplied, ago(200));
  const r = await call(DB, 'POST', '/api/retention/run', {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(decisions(db).map((d) => d.promotion_id), [recent]);
  assert.equal(promo(db, old), undefined);
  assert.equal(promo(db, oldApplied), undefined);
  assert.ok(promo(db, recent));
});

// ── X1: EXPLAIN on seeded volume ─────────────────────────────────────────────
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
const scans = (lines) => lines.filter((l) => /^SCAN (staff_\w+|[a-z])\b/.test(l) && !/USING (INDEX|PRIMARY KEY|INTEGER PRIMARY KEY|COVERING INDEX)/.test(l));

test('X1 every statement of the three routes uses an index on 20,000 outcomes, 2,000 findings, 500 promotions and 500 decisions', async (t) => {
  const o = await open(t); if (!o) return;
  const { db: sql, DB } = o;
  const agents = ['quartermaster', 'watchman', 'dispatcher', 'inspector', 'millwright', 'clerk', 'archivist', 'scout'];
  sql.prepare(`INSERT OR IGNORE INTO staff_agents (name, role, accountable, soul_path, updated_at) VALUES ('scout','r','operator','staff/x.md',?)`).run(ago(90));
  sql.exec('BEGIN');
  const words = ['merged', 'rejected', 'noise'];
  for (let i = 0; i < 20000; i++) {
    const fp = 'e' + String(i).padStart(63, '0');
    const a = agents[i % 8];
    const at = ago((i % 170) + 1, i % 3600);
    if (i < 2000) {
      sql.prepare(`INSERT INTO staff_findings (fingerprint, agent, title, source_kind, source_url, source_labels, observed_at, status, ticket_url, claimed_at, updated_at)
                   VALUES (?, ?, 't', 'alert', 'https://example.com/x', '[]', ?, 'merged', 'https://github.com/o/r/issues/1', ?, ?)`).run(fp, a, at, at, at);
    }
    sql.prepare(`INSERT INTO staff_outcomes (fingerprint, agent, class, family, outcome, verdict, ticket_url, resolved_at, applied)
                 VALUES (?, ?, 'c', ?, ?, ?, 'https://github.com/o/r/issues/1', ?, 1)`)
      .run(fp, a, 'f'.repeat(64), words[i % 3], VERDICT[words[i % 3]], at);
  }
  for (let i = 0; i < 500; i++) {
    const a = agents[i % 8];
    const r = sql.prepare(`INSERT INTO staff_promotions (agent, from_level, to_level, agreements, status, created_at, decided_at)
                           VALUES (?, 'automation', 'augmentation', 5, 'void', ?, ?)`).run(a, ago(i % 100 + 1), ago(i % 100));
    sql.prepare(`INSERT INTO staff_promotion_decisions (promotion_id, agent, decision, from_level, to_level, reason, actor, decided_at)
                 VALUES (?, ?, 'void', 'automation', 'augmentation', 'r', 'operator@example.com', ?)`).run(Number(r.lastInsertRowid), a, ago(i % 100));
  }
  sql.exec('COMMIT');
  sql.prepare("UPDATE staff_agents SET updated_at=? WHERE name='watchman'").run(ago(20));
  const pid = seedPromotion(sql, 'watchman');
  const { db, seen } = recorder(DB);
  assert.equal((await get(db, '/api/staff/learning?agent=watchman')).status, 200);
  const p1 = await get(db, '/api/staff/learning/outcomes?agent=watchman&days=30&outcome=noise&limit=50');
  assert.equal(p1.status, 200);
  assert.equal((await get(db, `/api/staff/learning/outcomes?agent=watchman&days=30&before=${encodeURIComponent(p1.body.next_before)}`)).status, 200);
  assert.equal((await decide(db, { id: pid, decision: 'approve', reason: 'x1', actor: 'operator@example.com' })).status, 200);
  assert.equal((await decide(db, { id: pid, decision: 'approve', reason: 'x1', actor: 'operator@example.com' })).status, 200);
  const pid2 = seedPromotion(sql, 'clerk');
  assert.equal((await decide(db, { id: pid2, decision: 'void', reason: 'x1', actor: 'operator@example.com' })).status, 200);
  const pid3 = seedPromotion(sql, 'inspector');
  sql.prepare("UPDATE staff_agents SET status='paused' WHERE name='inspector'").run();
  assert.equal((await decide(db, { id: pid3, decision: 'approve', reason: 'x1', actor: 'operator@example.com' })).status, 409);

  const staffSql = [...seen.entries()].filter(([q]) => /\bstaff_\w+/.test(q));
  assert.ok(staffSql.length >= 12, `the flows reached only ${staffSql.length} staff statements`);
  let windowRead = 0;
  for (const [q, binds] of staffSql) {
    const lines = sql.prepare(`EXPLAIN QUERY PLAN ${q}`).all(...binds).map((x) => x.detail);
    assert.deepEqual(scans(lines), [], `${q.replace(/\s+/g, ' ').slice(0, 200)}: ${lines.join(' | ')}`);
    if (/FROM staff_outcomes/.test(q) && /resolved_at >=/.test(q)) {
      windowRead += 1;
      assert.ok(lines.some((l) => l.includes('idx_staff_outcomes_agent_resolved')), `${q.replace(/\s+/g, ' ').slice(0, 160)}: ${lines.join(' | ')}`);
    }
  }
  assert.ok(windowRead >= 3, `window/list/evidence reads reached: ${windowRead}`);
});
