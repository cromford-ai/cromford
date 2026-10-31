// BH-7260 (BH-7244.2): the PM flesh-out ledger (src/routes/pm.js), the
// pm-agent idea source, and the pm_runs retention rule.
//
// Every case drives the REAL worker.fetch and route table (D2) over the
// composed jobs schema in node:sqlite (test/lib/d1-sqlite.bh-1030.js). The
// clock is pinned (D60). Each case seeds its own project and ids.
//
// R1  POST /api/roadmap/ideas with source pm-agent is 201; pm-agentx is 400 field source
// R2  a second claim of one (project, idea_id, input_hash) is already:true, 1 row
// R3  another project: GET runs is 0 runs and latest null; a result POST is 404
//     and changes nothing
// R4  claim, then answered, then done, then GET with idea_id round-trips
//     result, result_ref, draft and cost_usd; the list carries no result column
// R5  force re-claims a failed row and never a done or answered row; a move
//     that is not allowed is 409; a result over pm.flesh_result_max_chars is 413
// R6  EXPLAIN QUERY PLAN on 50,000 rows: each hot read uses its index, no SCAN pm_runs
// R7  retention: dry run counts 3 and removes 0; a real run with the archive
//     bound archives 3 and keeps 2; one retention_runs row per run; unbound deletes 0
// R8  the knob seeds and their values
// R9  the schema fragment creates only pm_runs (no ideas table)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

const P = await import('../src/routes/pm.js').catch(() => ({}));
const { RULES } = await import('../src/routes/retention.js');

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-30T06:00:00Z');
const NOW = '2026-10-30T06:00:00Z';
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const FRAG_NAME = '202610301916-bh-7260-pm-runs.sql';
const SCHEMA_FRAGMENT = new URL(`../schema.d/${FRAG_NAME}`, import.meta.url);
// The canned seven-section answer tests/pm-flesh.bh-7260-test.sh also drives.
const ANSWER = readFileSync(new URL('./fixtures/pm-flesh-answer.bh-7260.md', import.meta.url), 'utf8');
const HASH = (c) => c.repeat(64);

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return o;
}
async function call(env, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { ...env, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const claim = (o, b) => call(o, 'POST', '/api/pm/claim', { model: 'model-fixture', ...b });
const result = (o, b) => call(o, 'POST', '/api/pm/result', b);
const runs = (o, project, idea_id) =>
  call(o, 'GET', `/api/pm/runs?${new URLSearchParams({ project, ...(idea_id ? { idea_id } : {}) })}`);
const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const knob = (db, k, v) => db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'','test',?)`).run(k, v, NOW);
const project = (db, p) => db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?,?,0,?,?)`)
  .run(p, `o/${p}-fixture`, NOW, NOW);
const SEVEN = ANSWER.slice(ANSWER.indexOf('## ')).replace(/\nPM_FLESH_DONE\s*$/, '').trimEnd();

test('R1 pm-agent is an accepted idea source; pm-agentx is not', async (t) => {
  const o = await open(t); if (!o) return;
  project(o.db, 'pr1');
  const ok = await call(o, 'POST', '/api/roadmap/ideas', { project: 'pr1', title: 'Landed by the PM agent', source: 'pm-agent', idem_key: 'pm-slug-r1', actor: 'pm-agent' });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  assert.equal(ok.body.idea.source, 'pm-agent');
  assert.equal(ok.body.idea.lane, 'ideas');
  const bad = await call(o, 'POST', '/api/roadmap/ideas', { project: 'pr1', title: 'Near miss', source: 'pm-agentx', actor: 'pm-agent' });
  assert.equal(bad.status, 400, JSON.stringify(bad.body));
  assert.equal(bad.body.field, 'source');
  assert.equal(count(o.db, 'roadmap_ideas'), 1);
});

test('R2 a second claim is already:true and the table holds 1 row', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await claim(o, { project: 'pr2', idea_id: 'i-r2', input_hash: HASH('a') });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.claimed, true);
  assert.equal(a.body.already, false);
  assert.equal(a.body.run.status, 'claimed');
  assert.equal(a.body.run.model, 'model-fixture');
  const b = await claim(o, { project: 'pr2', idea_id: 'i-r2', input_hash: HASH('a') });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.claimed, false);
  assert.equal(b.body.already, true);
  assert.equal(b.body.run.id, a.body.run.id);
  assert.equal(count(o.db, 'pm_runs'), 1);
  // Another hash for the same idea is a new claim.
  const c = await claim(o, { project: 'pr2', idea_id: 'i-r2', input_hash: HASH('b') });
  assert.equal(c.body.claimed, true);
  assert.equal(count(o.db, 'pm_runs'), 2);
  // Validation runs before any write.
  for (const [body, field] of [
    [{ project: 'pr2', idea_id: 'i-r2', input_hash: 'abc' }, 'input_hash'],
    [{ project: 'pr2', idea_id: 'i-r2', input_hash: HASH('A') }, 'input_hash'],
    [{ project: 'pr2', idea_id: '', input_hash: HASH('c') }, 'idea_id'],
    [{ project: 'pr2', idea_id: 'x'.repeat(81), input_hash: HASH('c') }, 'idea_id'],
    [{ project: '../x', idea_id: 'i', input_hash: HASH('c') }, 'project'],
    [{ project: 'pr2', idea_id: 'i', input_hash: HASH('c'), model: 'm'.repeat(201) }, 'model'],
  ]) {
    const r = await claim(o, body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.equal(r.body.field, field, JSON.stringify(body));
  }
  assert.equal(count(o.db, 'pm_runs'), 2);
});

test('R3 another project reads 0 rows and cannot write a result', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await claim(o, { project: 'pr3a', idea_id: 'i-r3', input_hash: HASH('a') });
  const ans = await result(o, { project: 'pr3a', id: a.body.run.id, status: 'answered', result: SEVEN });
  assert.equal(ans.status, 200, JSON.stringify(ans.body));
  const done = await result(o, { project: 'pr3a', id: a.body.run.id, status: 'done', draft: 'ok', cost_usd: 0.5 });
  assert.equal(done.status, 200, JSON.stringify(done.body));
  const g = await runs(o, 'pr3b', 'i-r3');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.deepEqual(g.body.runs, []);
  assert.equal(g.body.latest, null);
  const all = await runs(o, 'pr3b');
  assert.deepEqual(all.body.runs, []);
  const second = await claim(o, { project: 'pr3a', idea_id: 'i-r3b', input_hash: HASH('b') });
  const before = { ...o.db.prepare('SELECT * FROM pm_runs WHERE id = ?').get(second.body.run.id) };
  const w = await result(o, { project: 'pr3b', id: second.body.run.id, status: 'failed', error: 'wrong project' });
  assert.equal(w.status, 404, JSON.stringify(w.body));
  assert.deepEqual({ ...o.db.prepare('SELECT * FROM pm_runs WHERE id = ?').get(second.body.run.id) }, before);
  // The owner still reads its own runs.
  const own = await runs(o, 'pr3a', 'i-r3');
  assert.equal(own.body.runs.length, 1);
  assert.equal(own.body.latest.id, a.body.run.id);
});

test('R4 claim, then answered, then done, then runs round-trips the fields', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await claim(o, { project: 'pr4', idea_id: 'i-r4', input_hash: HASH('d') });
  assert.equal(a.body.run.result, null, 'a claimed run carries no result');
  const ref = 'https://console.example.pages.dev/roadmap/pr4/idea/i-r4#pm-flesh';
  const ans = await result(o, { project: 'pr4', id: a.body.run.id, status: 'answered', result: SEVEN });
  assert.equal(ans.status, 200, JSON.stringify(ans.body));
  assert.equal(ans.body.run.status, 'answered');
  // An answered run is already the newest result of the idea.
  const mid = await runs(o, 'pr4', 'i-r4');
  assert.equal(mid.body.latest.id, a.body.run.id);
  assert.equal(mid.body.latest.result, SEVEN);
  // done with no result keeps the stored one.
  const r = await result(o, { project: 'pr4', id: a.body.run.id, status: 'done', result_ref: ref, draft: 'ok', prd: '# PRD\n\nkept', cost_usd: 1.25 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.run.status, 'done');
  const g = await runs(o, 'pr4', 'i-r4');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.project, 'pr4');
  assert.equal(g.body.as_of, NOW);
  const l = g.body.latest;
  assert.equal(l.id, a.body.run.id);
  assert.equal(l.result, SEVEN);
  assert.equal(l.result_ref, ref);
  assert.equal(l.draft, 'ok');
  assert.equal(l.prd, '# PRD\n\nkept', 'latest carries the drafted PRD');
  assert.equal('prd' in g.body.runs[0], false, 'the list carries no prd column');
  assert.equal(l.cost_usd, 1.25);
  assert.equal(l.status, 'done');
  assert.equal(l.input_hash, HASH('d'));
  assert.equal(g.body.runs.length, 1);
  assert.equal('result' in g.body.runs[0], false, 'the list carries no result column');
  assert.equal(g.body.runs[0].cost_usd, 1.25);
  assert.equal(g.body.runs[0].draft, 'ok');
  // The project list, without idea_id, has no latest and no result.
  const p = await runs(o, 'pr4');
  assert.equal(p.body.runs.length, 1);
  assert.equal(p.body.latest, null);
  assert.equal('result' in p.body.runs[0], false);
  // A done claim answers the stored result (the D2 "already done" read).
  const again = await claim(o, { project: 'pr4', idea_id: 'i-r4', input_hash: HASH('d') });
  assert.equal(again.body.already, true);
  assert.equal(again.body.run.result, SEVEN);
  // A failed newer run does not replace latest.
  const b = await claim(o, { project: 'pr4', idea_id: 'i-r4', input_hash: HASH('e') });
  assert.equal((await result(o, { project: 'pr4', id: b.body.run.id, status: 'failed', error: 'bad answer' })).status, 200);
  const g2 = await runs(o, 'pr4', 'i-r4');
  assert.equal(g2.body.runs.length, 2);
  assert.equal(g2.body.latest.id, a.body.run.id);
});

test('R5 force and the allowed moves; 409 on any other move; 413 over pm.flesh_result_max_chars', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await claim(o, { project: 'pr5', idea_id: 'i-r5', input_hash: HASH('f') });
  // claimed -> done is not a move: done needs a stored result first.
  const early = await result(o, { project: 'pr5', id: a.body.run.id, status: 'done', draft: 'ok' });
  assert.equal(early.status, 409, JSON.stringify(early.body));
  assert.equal(early.body.run.status, 'claimed');
  const f = await result(o, { project: 'pr5', id: a.body.run.id, status: 'failed', error: 'agent-call rc=1' });
  assert.equal(f.status, 200, JSON.stringify(f.body));
  assert.equal(f.body.run.status, 'failed');
  assert.equal(f.body.run.error, 'agent-call rc=1');
  // No force: a failed row is billed.
  assert.equal((await claim(o, { project: 'pr5', idea_id: 'i-r5', input_hash: HASH('f') })).body.claimed, false);
  const forced = await claim(o, { project: 'pr5', idea_id: 'i-r5', input_hash: HASH('f'), force: true });
  assert.equal(forced.body.claimed, true);
  assert.equal(forced.body.already, false);
  assert.equal(forced.body.run.status, 'claimed');
  assert.equal(forced.body.run.error, null);
  // force on a claimed row claims it again too (a person's retry of a lost call).
  const forced2 = await claim(o, { project: 'pr5', idea_id: 'i-r5', input_hash: HASH('f'), force: true });
  assert.equal(forced2.body.claimed, true);
  // answered needs a result.
  const noResult = await result(o, { project: 'pr5', id: a.body.run.id, status: 'answered' });
  assert.equal(noResult.status, 400, JSON.stringify(noResult.body));
  assert.equal(noResult.body.field, 'result');
  knob(o.db, 'pm.flesh_result_max_chars', '1024');
  const big = await result(o, { project: 'pr5', id: a.body.run.id, status: 'answered', result: 'x'.repeat(1025) });
  assert.equal(big.status, 413, JSON.stringify(big.body));
  assert.equal(o.db.prepare('SELECT status FROM pm_runs WHERE id = ?').get(a.body.run.id).status, 'claimed');
  const ans = await result(o, { project: 'pr5', id: a.body.run.id, status: 'answered', result: SEVEN });
  assert.equal(ans.status, 200, JSON.stringify(ans.body));
  // force never re-opens an answered row.
  const onAnswered = await claim(o, { project: 'pr5', idea_id: 'i-r5', input_hash: HASH('f'), force: true });
  assert.equal(onAnswered.body.claimed, false);
  assert.equal(onAnswered.body.run.status, 'answered');
  assert.equal(onAnswered.body.run.result, SEVEN, 'an answered claim carries the stored result');
  const d = await result(o, { project: 'pr5', id: a.body.run.id, status: 'done', draft: 'unknown', cost_usd: 0 });
  assert.equal(d.status, 200, JSON.stringify(d.body));
  assert.equal(d.body.run.cost_usd, 0);
  assert.equal(d.body.run.result, SEVEN);
  // force never re-opens a done row.
  const again = await claim(o, { project: 'pr5', idea_id: 'i-r5', input_hash: HASH('f'), force: true });
  assert.equal(again.body.claimed, false);
  assert.equal(again.body.already, true);
  assert.equal(again.body.run.status, 'done');
  for (const st of ['failed', 'answered', 'done']) {
    const late = await result(o, { project: 'pr5', id: a.body.run.id, status: st, result: SEVEN, error: 'late' });
    assert.equal(late.status, 409, `done -> ${st}: ${JSON.stringify(late.body)}`);
    assert.equal(late.body.run.status, 'done');
  }
  // answered -> failed is a move.
  const b = await claim(o, { project: 'pr5', idea_id: 'i-r5b', input_hash: HASH('8') });
  await result(o, { project: 'pr5', id: b.body.run.id, status: 'answered', result: SEVEN });
  assert.equal((await result(o, { project: 'pr5', id: b.body.run.id, status: 'failed', error: 'draft lost' })).status, 200);
  // Field checks.
  for (const [body, field] of [
    [{ status: 'maybe' }, 'status'],
    [{ status: 'claimed' }, 'status'],
    [{ status: 'failed', cost_usd: -1 }, 'cost_usd'],
    [{ status: 'failed', cost_usd: 'NaN' }, 'cost_usd'],
    [{ status: 'failed', result_ref: 'ftp://x' }, 'result_ref'],
    [{ status: 'failed', draft: 'maybe' }, 'draft'],
  ]) {
    const r = await result(o, { project: 'pr5', id: a.body.run.id, ...body });
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.equal(r.body.field, field, JSON.stringify(body));
  }
  // A prd over pm.flesh_prd_max_chars is 413; a string is required.
  knob(o.db, 'pm.flesh_prd_max_chars', '1024');
  const pc = await claim(o, { project: 'pr5', idea_id: 'i-r5p', input_hash: HASH('8') });
  assert.equal((await result(o, { project: 'pr5', id: pc.body.run.id, status: 'answered', result: SEVEN })).status, 200);
  const bigPrd = await result(o, { project: 'pr5', id: pc.body.run.id, status: 'done', prd: 'x'.repeat(1025) });
  assert.equal(bigPrd.status, 413, JSON.stringify(bigPrd.body));
  assert.equal(bigPrd.body.field, 'prd');
  const notStr = await result(o, { project: 'pr5', id: pc.body.run.id, status: 'done', prd: 5 });
  assert.equal(notStr.status, 400);
  assert.equal(notStr.body.field, 'prd');
  const fits = await result(o, { project: 'pr5', id: pc.body.run.id, status: 'done', prd: 'x'.repeat(1024) });
  assert.equal(fits.status, 200, JSON.stringify(fits.body));
  assert.equal(fits.body.run.prd.length, 1024);
  // The error text is cut to pm.error_max_chars.
  knob(o.db, 'pm.error_max_chars', '5');
  const c = await claim(o, { project: 'pr5', idea_id: 'i-r5c', input_hash: HASH('9') });
  const cut = await result(o, { project: 'pr5', id: c.body.run.id, status: 'failed', error: 'too long text' });
  assert.equal(cut.status, 200, JSON.stringify(cut.body));
  assert.equal(cut.body.run.error, 'too l');
});

test('R6 EXPLAIN QUERY PLAN on 50,000 rows: every hot read uses its index', async (t) => {
  const o = await open(t); if (!o) return;
  const { db } = o;
  assert.equal(typeof P.KEY_ROW_SQL, 'string', 'pm.js exports KEY_ROW_SQL');
  const ins = db.prepare(`INSERT INTO pm_runs (id, project, idea_id, input_hash, status, result, draft, created_at, updated_at)
                          VALUES (?, ?, ?, ?, ?, ?, 'ok', ?, ?)`);
  db.exec('BEGIN');
  for (let i = 0; i < 50000; i++) {
    const at = iso(NOW_MS - (i % 400) * DAY);
    ins.run(`run-${i}`, `proj-${i % 20}`, `idea-${i % 500}`, String(i).padStart(64, '0'), ['done', 'answered', 'failed'][i % 3], 'r', at, at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(count(db, 'pm_runs'), 50000);
  const plan = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join('\n');
  const rule = RULES.find((x) => x.rule === 'pm_runs.age');
  assert.ok(rule, 'RULES has pm_runs.age');
  const want = [
    ['claim read by key', P.KEY_ROW_SQL, ['proj-3', 'idea-3', '0'.repeat(64)], 'ux_pm_runs_key'],
    ['force CAS by key', P.FORCE_SQL, ['proj-3', 'idea-3', '0'.repeat(64), 'm', NOW], 'ux_pm_runs_key'],
    ['row by id', P.ROW_SQL, ['run-3', 'proj-3'], 'sqlite_autoindex_pm_runs_1'],
    ['result CAS by id', P.RESULT_SQL, ['run-3', 'proj-3', 'done', null, null, 'ok', 0, null, NOW, '["answered"]', null], 'sqlite_autoindex_pm_runs_1'],
    ['project list', P.LIST_PROJECT_SQL, ['proj-3', 50], 'idx_pm_runs_project_created'],
    ['idea list', P.LIST_IDEA_SQL, ['proj-3', 'idea-3', 50], 'idx_pm_runs_idea_created'],
    ['newest result', P.LATEST_SQL, ['proj-3', 'idea-3'], 'idx_pm_runs_idea_created'],
    ['retention ids', rule.ids, [NOW, 500], 'idx_pm_runs_created'],
  ];
  for (const [name, sql, binds, index] of want) {
    assert.equal(typeof sql, 'string', `${name} SQL is exported`);
    const text = plan(sql, binds);
    assert.ok(!/SCAN pm_runs\b/.test(text), `${name} scans pm_runs:\n${text}`);
    assert.ok(text.includes(index), `${name} does not use ${index}:\n${text}`);
    assert.ok(!/USE TEMP B-TREE/.test(text), `${name} sorts in a temp b-tree:\n${text}`);
  }
});

test('R7 retention: dry run counts, a bound archive keeps the money rows, unbound deletes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  const seed = (id, days) => {
    const at = iso(NOW_MS - days * DAY);
    o.db.prepare(`INSERT INTO pm_runs (id, project, idea_id, input_hash, status, cost_usd, draft, created_at, updated_at)
                  VALUES (?, 'pr7', ?, ?, 'done', 0.75, 'ok', ?, ?)`).run(id, id, HASH('7'), at, at);
  };
  for (const id of ['old-1', 'old-2', 'old-3']) seed(id, 181);
  for (const id of ['young-1', 'young-2']) seed(id, 179);
  const audit = () => o.db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule = 'pm_runs.age'").get().n;
  const rr = (r) => r.body.rules.find((x) => x.rule === 'pm_runs.age');

  const dry = await call({ DB: o.DB, ARCHIVE: d1(adb) }, 'POST', '/api/retention/run', { dry_run: true });
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.equal(rr(dry).counted, 3);
  assert.equal(rr(dry).removed, 0);
  assert.equal(count(o.db, 'pm_runs'), 5);
  assert.equal(audit(), 1);

  knob(o.db, 'retention.dry_run', '0');
  const unbound = await call({ DB: o.DB }, 'POST', '/api/retention/run', {});
  assert.equal(unbound.status, 200, JSON.stringify(unbound.body));
  assert.equal(rr(unbound).removed, 0);
  assert.equal(count(o.db, 'pm_runs'), 5);
  assert.equal(audit(), 2);

  const real = await call({ DB: o.DB, ARCHIVE: d1(adb) }, 'POST', '/api/retention/run', {});
  assert.equal(real.status, 200, JSON.stringify(real.body));
  assert.equal(rr(real).removed, 3);
  assert.equal(rr(real).error, null);
  assert.deepEqual(o.db.prepare('SELECT id FROM pm_runs ORDER BY id').all().map((x) => x.id), ['young-1', 'young-2']);
  assert.deepEqual(adb.prepare('SELECT id, cost_usd FROM pm_runs ORDER BY id').all().map((x) => [x.id, x.cost_usd]),
    [['old-1', 0.75], ['old-2', 0.75], ['old-3', 0.75]]);
  assert.equal(audit(), 3, 'one retention_runs row per run');
});

test('R8 the knob seeds hold the planned values', async (t) => {
  const o = await open(t); if (!o) return;
  const got = Object.fromEntries(o.db.prepare(
    "SELECT key, value FROM settings WHERE key IN ('pm.retention_days','pm.runs_shown','pm.flesh_result_max_chars','pm.flesh_timeout_s','pm.land_max')"
  ).all().map((r) => [r.key, r.value]));
  const want = [['pm.retention_days', '180'], ['pm.runs_shown', '50'], ['pm.flesh_result_max_chars', '32768'],
    ['pm.flesh_timeout_s', '900'], ['pm.land_max', '20']];
  for (const [k, v] of want) assert.equal(got[k], v, k);
  // pm.runs_shown caps the list.
  knob(o.db, 'pm.runs_shown', '2');
  for (const c of ['1', '2', '3']) await claim(o, { project: 'pr8', idea_id: 'i-r8', input_hash: HASH(c) });
  assert.equal((await runs(o, 'pr8', 'i-r8')).body.runs.length, 2);
  assert.equal((await runs(o, 'pr8')).body.runs.length, 2);
  knob(o.db, 'pm.runs_shown', 'abc'); // not an integer: the fallback 50
  assert.equal((await runs(o, 'pr8')).body.runs.length, 3);
});

test('R9 the schema fragment creates only pm_runs', () => {
  const sql = readFileSync(SCHEMA_FRAGMENT, 'utf8');
  const tables = [...sql.matchAll(/CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+(\w+)/gi)].map((m) => m[1]);
  assert.deepEqual(tables, ['pm_runs']);
  const names = readdirSync(new URL('../schema.d/', import.meta.url)).filter((f) => /bh-7260/.test(f));
  assert.deepEqual(names, [FRAG_NAME]);
  // A semicolon in a comment would split a statement in the apply.
  for (const line of sql.split('\n').filter((l) => l.trim().startsWith('--'))) assert.ok(!line.includes(';'), line);
});
