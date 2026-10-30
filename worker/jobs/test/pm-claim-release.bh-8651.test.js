// BH-8651: POST /api/pm/briefs/claim releases a crashed `claimed` row after
// the settings-row timeout lane.pm-groom[.<project>].pm_claim_timeout_min, and
// writes one stage_events CLAIM_RELEASED row per release.
//
// Every case drives the REAL worker.fetch (D2) over the composed jobs schema in
// node:sqlite (test/lib/d1-sqlite.bh-1030.js). The clock is pinned. Each case
// seeds its own project slug.
//
// R1 a claimed row 121 min old (fallback 120) is released to the caller, with
//    one audit row; the create then answers 201
// R2 5 min old and exactly 120 min old: not released, row unchanged, no audit
// R3 a project row 30 wins; a lane row 0 is off; 15, abc, 20000 are the fallback
// R4 a lost race: the CAS changes nothing, claimed:false, still 1 audit row
// R5 failed, ready, force, an unparseable updated_at, another project's row
// R6 the composed schema seeds lane.pm-groom.pm_claim_timeout_min = '120'
// R7 the catalog fragment matches CLAIM_TIMEOUT_MIN and the seed
// R8 EXPLAIN QUERY PLAN over 500 briefs: no SCAN pm_briefs, no SCAN settings
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const P = await import('../src/routes/pm-brief.js');

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-19T11:05:00Z');
const NOW = '2026-10-19T11:05:00Z';
const MIN = 60e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (min) => iso(NOW_MS - min * MIN);
const WEEK = '2026-W43';
const LANE_KEY = 'lane.pm-groom.pm_claim_timeout_min';
const FRAGMENT = new URL('../../../catalog/lanes.d/pm-groom.knobs.d/PM_CLAIM_TIMEOUT_MIN.json', import.meta.url);

async function open(t, hooks) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return o;
}
async function call(env, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: JSON.stringify(body) };
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { ...env, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const claim = (o, b) => call(o, 'POST', '/api/pm/briefs/claim', { input_fp: 'fp-new', model: 'model-new', ...b });

function seedBrief(db, project, { status = 'claimed', updated_at, week = WEEK, sent_tg = 0, body = null } = {}) {
  const id = `b-${project}-${week}`;
  db.prepare(`INSERT INTO pm_briefs (id, project, week, status, input_fp, model, body, sent_mc, sent_tg, error, created_at, updated_at)
              VALUES (?, ?, ?, ?, 'fp-old', 'model-old', ?, ?, ?, ?, ?, ?)`)
    .run(id, project, week, status, body, status === 'ready' ? 1 : 0, sent_tg, status === 'failed' ? 'boom' : null, updated_at, updated_at);
  return id;
}
const briefRow = (db, project, week = WEEK) => ({ ...db.prepare('SELECT * FROM pm_briefs WHERE project = ? AND week = ?').get(project, week) });
const audits = (db, project, week = WEEK) =>
  db.prepare("SELECT * FROM stage_events WHERE verdict = 'CLAIM_RELEASED' AND job_id = ?").all(`pm-brief:${project}:${week}`).map((r) => ({ ...r }));
const allAudits = (db) => db.prepare("SELECT COUNT(*) AS n FROM stage_events WHERE verdict = 'CLAIM_RELEASED'").get().n;
const setKnob = (db, key, value) =>
  db.prepare("INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, 'fixture', 'test', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(key, value, NOW);

test('R1 a claimed row older than the fallback timeout is released to this caller, with one audit row', async (t) => {
  const o = await open(t); if (!o) return;
  o.db.prepare('DELETE FROM settings WHERE key = ?').run(LANE_KEY); // the code fallback 120
  const prior = ago(121);
  const id = seedBrief(o.db, 'pr1', { updated_at: prior });
  const r = await claim(o, { project: 'pr1', week: WEEK });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.claimed, true);
  assert.equal(r.body.released, true);
  assert.equal(r.body.brief.id, id);
  assert.equal(r.body.brief.status, 'claimed');
  const row = briefRow(o.db, 'pr1');
  assert.equal(row.updated_at, NOW);
  assert.equal(row.input_fp, 'fp-new');
  assert.equal(row.model, 'model-new');
  assert.equal(row.error, null);
  const a = audits(o.db, 'pr1');
  assert.equal(a.length, 1);
  assert.equal(allAudits(o.db), 1);
  assert.equal(a[0].stage, 'pm-groom');
  assert.equal(a[0].actor, 'pm-brief');
  assert.equal(a[0].created_at, NOW);
  assert.deepEqual(JSON.parse(a[0].detail), {
    brief_id: id, project: 'pr1', week: WEEK, prior_updated_at: prior,
    prior_input_fp: 'fp-old', prior_model: 'model-old', timeout_min: 120,
  });
  // The next run picks the work up: the create on the released row lands.
  const c = await call(o, 'POST', '/api/pm/briefs', {
    project: 'pr1', week: WEEK, moves: [],
    body: { summary: 's', stale: [], stale_partial: false, scores: [], now: [], next_wave: [], snapshot_hash: 'h' },
  });
  assert.equal(c.status, 201, JSON.stringify(c.body));
  assert.equal(c.body.brief.status, 'ready');
  // A second claim on the now-fresh claim answers false: one release, one call.
  const again = await claim(o, { project: 'pr1', week: WEEK });
  assert.equal(again.body.claimed, false);
  assert.equal(again.body.released, false);
  // A row 3 days old (a crash earlier in the week) is released too.
  seedBrief(o.db, 'pr1c', { updated_at: ago(3 * 1440) });
  const old = await claim(o, { project: 'pr1c', week: WEEK });
  assert.equal(old.body.claimed, true);
  assert.equal(old.body.released, true);
  // A new week is the INSERT path: released:false.
  const fresh = await claim(o, { project: 'pr1n', week: WEEK });
  assert.equal(fresh.body.claimed, true);
  assert.equal(fresh.body.released, false);
});

test('R2 a fresh claimed row and one at exactly the timeout are not released', async (t) => {
  const o = await open(t); if (!o) return;
  for (const [project, min] of [['pr2a', 5], ['pr2b', 120]]) {
    seedBrief(o.db, project, { updated_at: ago(min) });
    const before = briefRow(o.db, project);
    const r = await claim(o, { project, week: WEEK });
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, false, `${min} min`);
    assert.equal(r.body.released, false, `${min} min`);
    assert.deepEqual(briefRow(o.db, project), before);
    assert.equal(audits(o.db, project).length, 0);
  }
  assert.equal(allAudits(o.db), 0);
});

test('R3 the knob: a project row wins, 0 is off, out-of-range or non-integer is the fallback', async (t) => {
  const o = await open(t); if (!o) return;
  // A project row of 30 releases a 31-min-old row.
  setKnob(o.db, 'lane.pm-groom.pr3a.pm_claim_timeout_min', '30');
  seedBrief(o.db, 'pr3a', { updated_at: ago(31) });
  const a = await claim(o, { project: 'pr3a', week: WEEK });
  assert.equal(a.body.released, true);
  assert.equal(JSON.parse(audits(o.db, 'pr3a')[0].detail).timeout_min, 30);
  // The lane row 0 is off: a 7-day-old row stays.
  setKnob(o.db, LANE_KEY, '0');
  seedBrief(o.db, 'pr3b', { updated_at: ago(7 * 1440) });
  const b = await claim(o, { project: 'pr3b', week: WEEK });
  assert.equal(b.body.claimed, false);
  assert.equal(b.body.released, false);
  // The project row still wins over the lane's 0.
  seedBrief(o.db, 'pr3a', { updated_at: ago(45), week: '2026-W44' });
  assert.equal((await claim(o, { project: 'pr3a', week: '2026-W44' })).body.released, true);
  // A lane row 60 releases a 61-min-old row (the seed value is not hard-wired).
  setKnob(o.db, LANE_KEY, '60');
  seedBrief(o.db, 'pr3c', { updated_at: ago(61) });
  assert.equal((await claim(o, { project: 'pr3c', week: WEEK })).body.released, true);
  // Bad project values fall to the lane row; a bad lane row falls to 120.
  setKnob(o.db, LANE_KEY, '120');
  for (const [i, v] of ['15', 'abc', '20000', '-5', '1.5'].entries()) {
    const project = `pr3d${i}`;
    setKnob(o.db, `lane.pm-groom.${project}.pm_claim_timeout_min`, v);
    seedBrief(o.db, project, { updated_at: ago(60) });
    const r = await claim(o, { project, week: WEEK });
    assert.equal(r.body.released, false, `value ${v}`);
  }
  for (const [i, v] of ['15', 'abc', '20000'].entries()) {
    setKnob(o.db, LANE_KEY, v);
    const project = `pr3e${i}`;
    seedBrief(o.db, project, { updated_at: ago(60) });
    assert.equal((await claim(o, { project, week: WEEK })).body.released, false, `lane value ${v}`);
    seedBrief(o.db, project, { updated_at: ago(121), week: '2026-W45' });
    const r = await claim(o, { project, week: '2026-W45' });
    assert.equal(r.body.released, true, `lane value ${v} at 121 min`);
    assert.equal(JSON.parse(audits(o.db, project, '2026-W45')[0].detail).timeout_min, 120);
  }
});

test('R4 two callers on one stale row: one wins the CAS, one audit row', async (t) => {
  let raced = false;
  let o;
  // Right before this caller's CAS runs, another caller's release lands first.
  o = await open(t, {
    beforeRun(sql, binds) {
      if (raced || sql !== P.CLAIM_RELEASE_SQL) return;
      raced = true;
      o.db.prepare(P.CLAIM_RELEASE_SQL).run(binds[0], binds[1], 'fp-rival', 'model-rival', iso(NOW_MS), binds[5]);
      o.db.prepare(P.CLAIM_RELEASE_AUDIT_SQL).run('pm-brief:pr4:' + WEEK, '{"rival":true}', NOW);
    },
  });
  if (!o) return;
  seedBrief(o.db, 'pr4', { updated_at: ago(200) });
  const r = await claim(o, { project: 'pr4', week: WEEK });
  assert.ok(raced, 'the hook ran on the release statement');
  assert.equal(r.status, 200);
  assert.equal(r.body.claimed, false);
  assert.equal(r.body.released, false);
  assert.equal(r.body.brief.input_fp, 'fp-rival');
  assert.equal(audits(o.db, 'pr4').length, 1);
  assert.equal(JSON.parse(audits(o.db, 'pr4')[0].detail).rival, true);

  // Two concurrent real claims: exactly one true, one audit row.
  seedBrief(o.db, 'pr4b', { updated_at: ago(200) });
  const both = await Promise.all([claim(o, { project: 'pr4b', week: WEEK }), claim(o, { project: 'pr4b', week: WEEK })]);
  assert.equal(both.filter((x) => x.body.claimed === true).length, 1);
  assert.equal(both.filter((x) => x.body.released === true).length, 1);
  assert.equal(audits(o.db, 'pr4b').length, 1);
});

test('R5 failed, ready, force, an unparseable stamp and another project are never released', async (t) => {
  const o = await open(t); if (!o) return;
  const old = ago(3 * 1440);
  for (const [project, over] of [['pr5f', { status: 'failed' }], ['pr5r', { status: 'ready', body: '{"summary":"s"}' }], ['pr5u', { updated_at: 'not-a-date' }]]) {
    seedBrief(o.db, project, { updated_at: old, ...over });
    const before = briefRow(o.db, project);
    const r = await claim(o, { project, week: WEEK });
    assert.equal(r.body.claimed, false, project);
    assert.equal(r.body.released, false, project);
    assert.deepEqual(briefRow(o.db, project), before, project);
  }
  // force keeps its own path: re-claimed, released:false, no audit row.
  seedBrief(o.db, 'pr5x', { updated_at: old });
  const f = await claim(o, { project: 'pr5x', week: WEEK, force: true });
  assert.equal(f.body.claimed, true);
  assert.equal(f.body.released, false);
  // Another project's stale row is not touched by this project's claim.
  seedBrief(o.db, 'pm-other', { updated_at: old });
  const otherBefore = briefRow(o.db, 'pm-other');
  seedBrief(o.db, 'pr5o', { updated_at: ago(5) });
  assert.equal((await claim(o, { project: 'pr5o', week: WEEK })).body.released, false);
  assert.deepEqual(briefRow(o.db, 'pm-other'), otherBefore);
  assert.equal(allAudits(o.db), 0);
});

test('R6 the composed schema seeds the lane row at 120', async (t) => {
  const o = await open(t); if (!o) return;
  const r = o.db.prepare('SELECT value, actor FROM settings WHERE key = ?').get(LANE_KEY);
  assert.ok(r, 'seed row present');
  assert.equal(r.value, '120');
  assert.equal(r.actor, 'seed');
});

test('R7 the catalog fragment matches the code fallback and the seed', () => {
  const k = JSON.parse(readFileSync(FRAGMENT, 'utf8'));
  assert.equal(k.env, 'PM_CLAIM_TIMEOUT_MIN');
  assert.equal(k.type, 'int');
  assert.equal(k.default, 120);
  assert.equal(k.default, P.CLAIM_TIMEOUT_MIN[2]);
  assert.equal(k.max, P.CLAIM_TIMEOUT_MIN[1]);
  assert.equal(k.zero_means, 'off');
  assert.equal(k.settable, true);
  const seed = readFileSync(new URL('../schema.d/202610301846-bh-8651-pm-claim-timeout.sql', import.meta.url), 'utf8');
  assert.match(seed, new RegExp(`'${LANE_KEY.replace(/[.]/g, '\\.')}','${k.default}'`));
});

test('R8 EXPLAIN QUERY PLAN over 500 briefs: the knob and the release read by index', async (t) => {
  const o = await open(t); if (!o) return;
  const ins = o.db.prepare(`INSERT INTO pm_briefs (id, project, week, status, created_at, updated_at) VALUES (?, ?, ?, 'claimed', ?, ?)`);
  for (let p = 0; p < 10; p++) for (let w = 0; w < 50; w++) {
    ins.run(`b-${p}-${w}`, `proj-${p}`, `2025-W${String(w + 1).padStart(2, '0')}`, NOW, NOW);
  }
  for (let i = 0; i < 300; i++) setKnob(o.db, `lane.fixture-${i}.knob`, '1');
  o.db.exec('ANALYZE');
  const plan = (sql, binds) => o.db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join('\n');
  const k = plan(P.CLAIM_TIMEOUT_SQL, ['lane.pm-groom.proj-3.pm_claim_timeout_min']);
  assert.doesNotMatch(k, /SCAN settings/, k);
  assert.match(k, /SEARCH settings/, k);
  const rel = plan(P.CLAIM_RELEASE_SQL, ['b-3-10', 'proj-3', 'fp', 'm', NOW, NOW]);
  assert.doesNotMatch(rel, /SCAN pm_briefs/, rel);
  assert.match(rel, /SEARCH pm_briefs/, rel);
  const aud = plan(P.CLAIM_RELEASE_AUDIT_SQL, ['pm-brief:proj-3:2025-W10', '{}', NOW]);
  assert.doesNotMatch(aud, /SCAN (pm_briefs|settings|stage_events)/, aud);
});
