// BH-7263 (BH-7243.0): the roadmap tables ship with their retention rules.
//
// Driven through the REAL worker.fetch (POST /api/retention/run) over a hot
// node:sqlite D1 with the composed jobs schema and an EMPTY archive D1 (the
// worker creates its tables). The clock is pinned (D60).
//
// R1 a discarded idea at 181 d is in the archive with the same fields, then gone
// R2 discarded at 179 d, `ideas` at 400 d, `next` at 400 d and a discarded idea
//    with no discarded_at all stay
// R3 the archive unbound: nothing removed, the audit row says "archive not bound"
// R4 the seeded dry run deletes nothing and counts
// R5 rejected and failed waves at 400 d go to the archive; draft, empty, filed
//    and the other live states at 400 d and rejected at 300 d stay
// R6 an event at 731 d goes to the archive; one at 729 d stays
// R7 the delete guard: an idea moved back to `ideas` after the id read stays
// R8 the archive unbound and nothing eligible: no error and no audit error, so
//    the hourly lane raises no alert over empty tables; a dry run with a row
//    waiting counts it and says "archive not bound"
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { RULES } from '../src/routes/retention.js';

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-17T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days) => iso(NOW_MS - days * DAY);

async function stores(t, { archive = true } = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  return { db: o.db, DB: o.DB, adb, ARCHIVE: archive ? d1(adb) : undefined };
}
async function run(env, body = {}) {
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { ...env, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', ago(0));
}
function idea(db, id, lane, updatedDays, discardedDays = null) {
  db.prepare(`INSERT INTO roadmap_ideas (id, project, title, note, source, lane, version, created_by, created_at, updated_at, discarded_at)
              VALUES (?, 'cromford', ?, 'a note', 'operator', ?, 2, 'operator', ?, ?, ?)`)
    .run(id, `Idea ${id}`, lane, ago(updatedDays + 1), ago(updatedDays), discardedDays === null ? null : ago(discardedDays));
}
function wave(db, id, status, days) {
  db.prepare(`INSERT INTO roadmap_waves (id, project, status, input_fp, idea_ids, model, cost_usd, created_at, updated_at)
              VALUES (?, 'cromford', ?, ?, '[]', 'model-fixture', 0.42, ?, ?)`)
    .run(id, status, `fp-${id}`, ago(days + 1), ago(days));
}
function event(db, ideaId, days) {
  return Number(db.prepare(`INSERT INTO roadmap_idea_events (idea_id, project, kind, to_lane, actor, at)
              VALUES (?, 'cromford', 'created', 'ideas', 'operator', ?)`).run(ideaId, ago(days)).lastInsertRowid);
}
const has = (db, table, id) => !!db.prepare(`SELECT 1 FROM ${table} WHERE id = ?`).get(id);
const archived = (adb, table, id) => {
  try { return adb.prepare(`SELECT * FROM ${table} WHERE id = ?`).get(id) || null; } catch { return null; }
};
const ruleOf = (body, name) => (body.rules || []).find((x) => x.rule === name);

test('R1 a discarded idea at 181 d is copied to the archive with the same fields, then deleted', async (t) => {
  const s = await stores(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  idea(s.db, 'old', 'discarded', 181, 181);
  const before = { ...s.db.prepare('SELECT * FROM roadmap_ideas WHERE id = ?').get('old') };
  const r = await run(s);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const rr = ruleOf(r.body, 'roadmap_ideas.discarded');
  assert.ok(rr, 'the rule runs');
  assert.equal(rr.error, null);
  assert.equal(rr.removed, 1);
  assert.equal(has(s.db, 'roadmap_ideas', 'old'), false);
  const a = archived(s.adb, 'roadmap_ideas', 'old');
  assert.ok(a, 'the archive holds the row');
  for (const [k, v] of Object.entries(before)) assert.equal(a[k], v, k);
  const audit = s.db.prepare("SELECT removed, dry_run FROM retention_runs WHERE rule = 'roadmap_ideas.discarded'").get();
  assert.deepEqual({ ...audit }, { removed: 1, dry_run: 0 });
});

test('R2 a discarded idea inside its window, ideas and next of any age, and a NULL discarded_at stay', async (t) => {
  const s = await stores(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  idea(s.db, 'young', 'discarded', 179, 179);
  idea(s.db, 'live', 'ideas', 400);
  idea(s.db, 'nxt', 'next', 400);
  idea(s.db, 'nulld', 'discarded', 400, null);
  const r = await run(s);
  assert.equal(ruleOf(r.body, 'roadmap_ideas.discarded').removed, 0);
  for (const id of ['young', 'live', 'nxt', 'nulld']) {
    assert.equal(has(s.db, 'roadmap_ideas', id), true, id);
    assert.equal(archived(s.adb, 'roadmap_ideas', id), null, id);
  }
});

test('R3 the archive unbound: nothing is removed and the audit row says so', async (t) => {
  const s = await stores(t, { archive: false }); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  idea(s.db, 'old', 'discarded', 181, 181);
  wave(s.db, 'w-rej', 'rejected', 400);
  const ev = event(s.db, 'old', 800);
  const r = await run(s);
  assert.equal(r.status, 200);
  for (const name of ['roadmap_ideas.discarded', 'roadmap_waves.closed', 'roadmap_idea_events.age']) {
    const rr = ruleOf(r.body, name);
    assert.equal(rr.removed, 0, name);
    assert.equal(rr.error, 'archive not bound', name);
    const audit = s.db.prepare('SELECT removed, error FROM retention_runs WHERE rule = ?').get(name);
    assert.deepEqual({ ...audit }, { removed: 0, error: 'archive not bound' }, name);
  }
  assert.equal(has(s.db, 'roadmap_ideas', 'old'), true);
  assert.equal(has(s.db, 'roadmap_waves', 'w-rej'), true);
  assert.equal(has(s.db, 'roadmap_idea_events', ev), true);
});

test('R4 the seeded dry run deletes nothing and counts', async (t) => {
  const s = await stores(t); if (!s) return;
  idea(s.db, 'old', 'discarded', 181, 181);
  const r = await run(s);
  assert.equal(r.body.dry_run, true, 'the seed is a dry run');
  const rr = ruleOf(r.body, 'roadmap_ideas.discarded');
  assert.equal(rr.counted, 1);
  assert.equal(rr.removed, 0);
  assert.equal(has(s.db, 'roadmap_ideas', 'old'), true);
  assert.equal(archived(s.adb, 'roadmap_ideas', 'old'), null);
});

test('R5 rejected and failed waves at 400 d are archived; every other state, and rejected at 300 d, stays', async (t) => {
  const s = await stores(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  wave(s.db, 'w-rej', 'rejected', 400);
  wave(s.db, 'w-fail', 'failed', 400);
  const keep = ['requested', 'shaping', 'draft', 'empty', 'approved', 'filing', 'filed'];
  for (const st of keep) wave(s.db, `w-${st}`, st, 400);
  wave(s.db, 'w-rej-young', 'rejected', 300);
  const r = await run(s);
  assert.equal(ruleOf(r.body, 'roadmap_waves.closed').removed, 2);
  for (const id of ['w-rej', 'w-fail']) {
    assert.equal(has(s.db, 'roadmap_waves', id), false, id);
    const a = archived(s.adb, 'roadmap_waves', id);
    assert.ok(a, id);
    assert.equal(a.cost_usd, 0.42, 'the money column is archived');
  }
  for (const id of [...keep.map((x) => `w-${x}`), 'w-rej-young']) assert.equal(has(s.db, 'roadmap_waves', id), true, id);
});

test('R6 an event at 731 d is archived and deleted; one at 729 d stays', async (t) => {
  const s = await stores(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  const oldEv = event(s.db, 'i1', 731);
  const youngEv = event(s.db, 'i1', 729);
  const r = await run(s);
  assert.equal(ruleOf(r.body, 'roadmap_idea_events.age').removed, 1);
  assert.equal(has(s.db, 'roadmap_idea_events', oldEv), false);
  assert.ok(archived(s.adb, 'roadmap_idea_events', oldEv));
  assert.equal(has(s.db, 'roadmap_idea_events', youngEv), true);
});

test('R7 the delete guard: an idea restored after the id read is not deleted', async (t) => {
  const s = await stores(t); if (!s) return;
  const rule = RULES.find((x) => x.rule === 'roadmap_ideas.discarded');
  assert.ok(rule, 'the rule exists');
  idea(s.db, 'old', 'discarded', 181, 181);
  const ids = s.db.prepare(rule.ids).all(ago(180), 10).map((x) => x.id);
  assert.deepEqual(ids, ['old']);
  s.db.prepare("UPDATE roadmap_ideas SET lane = 'ideas' WHERE id = 'old'").run();
  const res = s.db.prepare(rule.del).run(JSON.stringify(ids));
  assert.equal(Number(res.changes), 0);
  assert.equal(has(s.db, 'roadmap_ideas', 'old'), true);
  const wr = RULES.find((x) => x.rule === 'roadmap_waves.closed');
  wave(s.db, 'w', 'rejected', 400);
  s.db.prepare("UPDATE roadmap_waves SET status = 'draft' WHERE id = 'w'").run();
  assert.equal(Number(s.db.prepare(wr.del).run('["w"]').changes), 0);
});

test('R8 unbound with nothing eligible is not an error; unbound with a row waiting is', async (t) => {
  const s = await stores(t, { archive: false }); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  idea(s.db, 'young', 'discarded', 10, 10);
  const names = ['roadmap_ideas.discarded', 'roadmap_idea_events.age', 'roadmap_waves.closed'];
  const r = await run(s);
  assert.equal(r.status, 200);
  for (const name of names) {
    const rr = ruleOf(r.body, name);
    assert.equal(rr.error, null, name);
    assert.equal(rr.removed, 0, name);
    assert.equal(rr.backlog, false, name);
    assert.equal(s.db.prepare('SELECT error FROM retention_runs WHERE rule = ?').get(name).error, null, name);
  }
  setting(s.db, 'retention.dry_run', '1');
  idea(s.db, 'old', 'discarded', 181, 181);
  const d = await run(s);
  const rr = ruleOf(d.body, 'roadmap_ideas.discarded');
  assert.equal(rr.error, 'archive not bound');
  assert.equal(rr.counted, 1);
  assert.equal(rr.backlog, true);
  assert.equal(has(s.db, 'roadmap_ideas', 'old'), true);
});
