// BH-9116: POST /api/waiting/state, the D1 half of the "To do (waiting)" view.
// Driven through the REAL worker.fetch over the REAL composed schema (the
// node:sqlite D1 shim). Every case opens its own database and uses its own
// project names, so no case depends on another.
//
//   W1  the settings fragment applies twice; the three knob rows exist; an
//       operator's changed value survives a re-apply
//   W2  no bearer: 401 and no rows
//   W3  bad body: 400 naming the field
//   W4  seeded triage, queue, running job + heartbeat, parked job, hard edge:
//       each comes back; positions in enqueued_at order; knobs echo the rows
//   W5  wrong tenant: rows of p-b with the same keys never come back for p-a
//   W6  EXPLAIN QUERY PLAN at seeded volume: each statement names its index
//   W7  one request = one DB.batch call of six statements
//   W8  more than waiting.max_tickets tickets: truncated, only N keys bound
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import {
  TRIAGE_SQL, QUEUE_SQL, POSITIONS_SQL, LIVE_JOBS_SQL, PARKED_JOBS_SQL, EDGES_SQL,
} from '../src/routes/waiting.js';

const SECRET = 'test-secret-fixture';
const SCHEMA_D = new URL('../schema.d/', import.meta.url);

const call = (DB, body, { bearer = SECRET } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const req = new Request('https://jobs.test/api/waiting/state', {
    method: 'POST', headers, body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

// The route reads its lookback window off the server clock, so every seeded
// time is an offset from one anchor taken from that same clock.
const NOW_MS = Date.now(); // determinism: ok — the single anchor; every seeded time is an offset from it
const isoAgoMin = (m) => new Date(NOW_MS - m * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');

function seed(db, p) {
  const tri = db.prepare(`INSERT INTO triage_state (project, ticket_key, ticket_label, input_hash, verdict, waiting_on,
    verdict_hash, triaged_at, reason, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)`);
  const q = db.prepare(`INSERT INTO build_queue (project, ticket_key, ticket_id, status, claimed_by, claimed_at,
    enqueued_at, reason, updated_at) VALUES (?,?,?,?,?,?,?,?,?)`);
  const job = db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, meta)
    VALUES (?,?,?,?,?,?,?,?,?,?)`);
  const beat = db.prepare('INSERT INTO job_heartbeats (job_id, beat_at, box) VALUES (?,?,?)');
  const edge = db.prepare(`INSERT INTO ticket_edges (project, parent, child, kind, source, at) VALUES (?,?,?,?,?,?)`);
  tri.run(p, 'K-1', 'K-1', 'h1', 'buildable', 'none', 'h1', isoAgoMin(50), 'DECISION buildable', isoAgoMin(50));
  q.run(p, 'K-2', 'id-2', 'queued', null, null, isoAgoMin(30), null, isoAgoMin(30));
  q.run(p, 'K-3', 'id-3', 'queued', null, null, isoAgoMin(90), null, isoAgoMin(90));
  q.run(p, 'K-4', 'id-4', 'claimed', 'fly-1', isoAgoMin(45), isoAgoMin(60), null, isoAgoMin(45));
  job.run(`build-${p}-K-5`, p, 'K-5', 'build', 'box', 'execute', 'running', isoAgoMin(20), isoAgoMin(10), null);
  beat.run(`build-${p}-K-5`, isoAgoMin(2), 'box');
  job.run(`build-${p}-K-6`, p, 'K-6', 'build', 'box', 'execute', 'parked', isoAgoMin(100), isoAgoMin(80),
    JSON.stringify({ reason: 'BUILD_DEFERRED OVERLAP_DEFER sibling K-1', pr_url: 'https://x.example/secret-ish', note: 'n' }));
  edge.run(p, 'K-1', 'K-7', 'hard', 'planner', isoAgoMin(5));
}

const ALL_KEYS = ['K-1', 'K-2', 'K-3', 'K-4', 'K-5', 'K-6', 'K-7'];
const tickets = (p, keys = ALL_KEYS) => keys.map((key) => ({ project: p, key }));

test('BH-9116 POST /api/waiting/state', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 the settings fragment: three rows, re-apply keeps an operator value', async () => {
    const f = readdirSync(SCHEMA_D).find((n) => /^\d{12}-bh-9116-waiting-settings\.sql$/.test(n));
    assert.ok(f, 'schema.d/<stamp>-bh-9116-waiting-settings.sql exists');
    const sql = readFileSync(new URL(f, SCHEMA_D), 'utf8');
    assert.ok(!/CREATE TABLE/i.test(sql), 'no table in the fragment');
    const { db } = await openDb();
    const s = (k) => db.prepare('SELECT value FROM settings WHERE key = ?').get(k)?.value;
    assert.equal(s('waiting.stale_claim_min'), '30');
    assert.equal(s('waiting.max_tickets'), '2000');
    assert.equal(s('waiting.defer_lookback_min'), '10080');
    assert.equal(s('waiting.reason_text_max'), '200');
    db.prepare("UPDATE settings SET value='45' WHERE key='waiting.stale_claim_min'").run();
    db.exec(sql);
    db.exec(sql);
    assert.equal(s('waiting.stale_claim_min'), '45', 'the operator value survives a re-apply');
  });

  await t.test('W2 no bearer: 401, no rows', async () => {
    const { db, DB } = await openDb();
    seed(db, 'w2-a');
    for (const bearer of [null, 'wrong-fixture']) {
      const r = await call(DB, { tickets: tickets('w2-a') }, { bearer });
      assert.equal(r.status, 401);
      assert.equal(r.body.triage, undefined);
      assert.equal(r.body.queue, undefined);
    }
  });

  await t.test('W3 bad body: 400 naming the field', async () => {
    const { DB } = await openDb();
    const cases = [
      [{}, 'tickets'],
      [{ tickets: 'K-1' }, 'tickets'],
      [{ tickets: [null] }, 'tickets[0]'],
      [{ tickets: [{ project: 'Bad Name', key: 'K-1' }] }, 'tickets[0].project'],
      [{ tickets: [{ project: 'w3', key: 'K'.repeat(65) }] }, 'tickets[0].key'],
      [{ tickets: [{ project: 'w3', key: 'K-1' }, { project: 'w3', key: 'K 2' }] }, 'tickets[1].key'],
      [{ tickets: [{ project: 'w3', key: 'K-1', id: 'a/b' }] }, 'tickets[0].id'],
    ];
    for (const [body, field] of cases) {
      const r = await call(DB, body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.equal(r.body.field, field, JSON.stringify(r.body));
    }
    const empty = await call(DB, { tickets: [] });
    assert.equal(empty.status, 200);
    assert.deepEqual(empty.body.triage, []);
    assert.deepEqual(empty.body.queue, []);
    assert.equal(empty.body.truncated, false);
  });

  await t.test('W4 seeded rows come back; positions ordered; knobs echo the rows', async () => {
    const { db, DB } = await openDb();
    seed(db, 'w4-a');
    db.prepare("UPDATE settings SET value='40' WHERE key='waiting.stale_claim_min'").run();
    const r = await call(DB, { tickets: tickets('w4-a') });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const b = r.body;
    assert.deepEqual(b.triage.map((x) => [x.ticket_key, x.verdict, x.verdict_hash, x.input_hash]), [['K-1', 'buildable', 'h1', 'h1']]);
    assert.deepEqual(b.queue.map((x) => [x.ticket_key, x.status]).sort(), [['K-2', 'queued'], ['K-3', 'queued'], ['K-4', 'claimed']]);
    assert.equal(b.queue.find((x) => x.ticket_key === 'K-4').claimed_by, 'fly-1');
    assert.deepEqual(b.positions.map((x) => x.ticket_key), ['K-3', 'K-2'], 'oldest enqueued first');
    assert.deepEqual(b.live_jobs.map((x) => [x.ticket_id, x.status, typeof x.beat_at]), [['K-5', 'running', 'string']]);
    assert.equal(b.parked_jobs.length, 1);
    assert.equal(b.parked_jobs[0].ticket_id, 'K-6');
    assert.equal(b.parked_jobs[0].reason, 'BUILD_DEFERRED OVERLAP_DEFER sibling K-1');
    assert.equal(b.parked_jobs[0].meta, undefined, 'raw meta never leaves the worker');
    assert.ok(!JSON.stringify(b.parked_jobs).includes('secret-ish'), 'no other meta field leaves the worker');
    assert.deepEqual(b.edges.map((x) => [x.parent, x.child]), [['K-1', 'K-7']]);
    assert.equal(b.knobs.stale_claim_min, 40, 'the changed row is read');
    assert.equal(b.knobs.max_tickets, 2000);
    assert.equal(b.knobs.defer_lookback_min, 10080);
    assert.equal(b.knobs.reason_text_max, 200);
    assert.equal(b.truncated, false);
    assert.equal(b.positions_truncated, false);
    assert.match(b.as_of, /^\d{4}-\d{2}-\d{2}T/);
  });

  await t.test('W4b a parked job older than the lookback is not returned; a soft edge is not', async () => {
    const { db, DB } = await openDb();
    seed(db, 'w4b');
    db.prepare("UPDATE jobs SET created_at = ? WHERE id = 'build-w4b-K-6'").run(isoAgoMin(20000));
    db.prepare(`INSERT INTO ticket_edges (project, parent, child, kind, source, at) VALUES ('w4b','K-2','K-7','soft','planner',?)`).run(isoAgoMin(1));
    const r = await call(DB, { tickets: tickets('w4b') });
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.parked_jobs, []);
    assert.deepEqual(r.body.edges.map((x) => x.parent), ['K-1']);
  });

  await t.test('W4c waiting.reason_text_max cuts the reason texts', async () => {
    const { db, DB } = await openDb();
    seed(db, 'w4c');
    db.prepare("UPDATE build_queue SET reason = 'BUILD_DEFERRED spawn cap reached on box-2' WHERE ticket_key = 'K-2'").run();
    db.prepare("UPDATE settings SET value='14' WHERE key='waiting.reason_text_max'").run();
    const r = await call(DB, { tickets: tickets('w4c') });
    assert.equal(r.status, 200);
    assert.equal(r.body.knobs.reason_text_max, 14);
    assert.equal(r.body.parked_jobs[0].reason, 'BUILD_DEFERRED');
    assert.equal(r.body.queue.find((x) => x.ticket_key === 'K-2').reason, 'BUILD_DEFERRED');
  });

  await t.test('W5 wrong tenant: rows of p-b never come back for p-a', async () => {
    const { db, DB } = await openDb();
    seed(db, 'p-b');
    const r = await call(DB, { tickets: tickets('p-a') });
    assert.equal(r.status, 200);
    for (const k of ['triage', 'queue', 'positions', 'live_jobs', 'parked_jobs', 'edges']) {
      assert.deepEqual(r.body[k], [], `${k} holds a row of another project`);
    }
    // And the mixed ask returns only the asked pairs' projects.
    seed(db, 'p-a');
    const m = await call(DB, { tickets: tickets('p-a') });
    for (const k of ['triage', 'queue', 'positions', 'live_jobs', 'parked_jobs', 'edges']) {
      assert.ok(m.body[k].every((x) => x.project === 'p-a'), `${k}: ${JSON.stringify(m.body[k])}`);
    }
  });

  await t.test('W6 EXPLAIN QUERY PLAN at seeded volume names each index', async () => {
    const { db } = await openDb();
    const projects = ['alpha', 'bravo', 'charlie', 'delta', 'echo'];
    db.exec('BEGIN');
    const tri = db.prepare(`INSERT INTO triage_state (project, ticket_key, verdict, input_hash, verdict_hash, updated_at) VALUES (?,?,?,?,?,?)`);
    const q = db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at) VALUES (?,?,?,?,?)`);
    const job = db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)`);
    const beat = db.prepare('INSERT INTO job_heartbeats (job_id, beat_at) VALUES (?,?)');
    const edge = db.prepare(`INSERT INTO ticket_edges (project, parent, child, kind, source, at) VALUES (?,?,?,?,?,?)`);
    const st = ['queued', 'claimed', 'done', 'failed'];
    const js = ['done', 'failed', 'running', 'parked', 'budget_stopped'];
    for (let i = 0; i < 10000; i++) tri.run(projects[i % 5], `T-${i}`, 'buildable', 'h', 'h', isoAgoMin(i));
    // The live shape: a row per ticket ever built, nearly all of them finished;
    // about 2% queued and 1% claimed at any one time.
    for (let i = 0; i < 20000; i++) q.run(projects[i % 5], `T-${i}`, i % 50 === 0 ? 'queued' : i % 100 === 1 ? 'claimed' : st[2 + (i % 2)], isoAgoMin(i), isoAgoMin(i));
    for (let i = 0; i < 50000; i++) {
      job.run(`j-${i}`, projects[i % 5], `T-${i % 9000}`, 'build', 'b', 'done', js[i % 5], isoAgoMin(i), isoAgoMin(i));
      if (i % 2 === 0) beat.run(`j-${i}`, isoAgoMin(i));
    }
    for (let i = 0; i < 10000; i++) edge.run(projects[i % 5], `T-${i}`, `T-${i + 1}`, i % 2 ? 'hard' : 'soft', 'planner', isoAgoMin(i));
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const P = JSON.stringify(['alpha', 'bravo']);
    const K = JSON.stringify(['T-1', 'T-2', 'T-3']);
    const planOf = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
    for (const [name, sql, binds, idx] of [
      ['S1 triage', TRIAGE_SQL, [P, K], 'sqlite_autoindex_triage_state_1'],
      ['S2 queue', QUEUE_SQL, [P, K], 'sqlite_autoindex_build_queue_1'],
      ['S3 positions', POSITIONS_SQL, [P, 2001], 'idx_build_queue_status'],
      ['S4 live jobs', LIVE_JOBS_SQL, [P, K], 'idx_jobs_project_'],
      ['S5 parked jobs', PARKED_JOBS_SQL, [P, K, isoAgoMin(10080)], 'idx_jobs_project_'],
      ['S6 edges', EDGES_SQL, [P, K], 'idx_ticket_edges_child'],
    ]) {
      const lines = planOf(sql, binds);
      assert.ok(lines.some((l) => l.includes(idx)), `${name}: ${idx} not used: ${lines.join(' | ')}`);
      assert.ok(!lines.some((l) => /SCAN (build_queue|jobs|j|triage_state|ticket_edges|job_heartbeats|h)\b/.test(l) && !/USING/.test(l)),
        `${name}: full scan: ${lines.join(' | ')}`);
      assert.ok(!lines.some((l) => /CORRELATED/.test(l)), `${name}: correlated subquery: ${lines.join(' | ')}`);
    }
    const s4 = planOf(LIVE_JOBS_SQL, [P, K]);
    assert.ok(s4.some((l) => /job_heartbeats|\bh\b/.test(l) && /PRIMARY KEY|autoindex/.test(l)), `S4 heartbeat join by PK: ${s4.join(' | ')}`);
  });

  await t.test('W7 one request = one DB.batch call of six statements', async () => {
    const opened = await openDb();
    seed(opened.db, 'w7');
    const seen = [];
    const inner = opened.DB;
    const DB = {
      prepare: (sql) => { seen.push(['prepare', sql]); return inner.prepare(sql); },
      batch: async (stmts) => { seen.push(['batch', stmts.length]); return inner.batch(stmts); },
    };
    const r = await call(DB, { tickets: tickets('w7') });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const batches = seen.filter((s) => s[0] === 'batch');
    assert.deepEqual(batches, [['batch', 6]]);
    // The prepares outside the batch are the settings snapshot read only.
    const reads = seen.filter((s) => s[0] === 'prepare').map((s) => s[1]);
    assert.equal(reads.filter((s) => !/FROM settings/.test(s)).length, 6);
  });

  await t.test('W8 more than waiting.max_tickets: truncated and only N keys bound', async () => {
    const { db, DB } = await openDb();
    seed(db, 'w8');
    db.prepare("UPDATE settings SET value='3' WHERE key='waiting.max_tickets'").run();
    const r = await call(DB, { tickets: tickets('w8') });
    assert.equal(r.status, 200);
    assert.equal(r.body.truncated, true);
    assert.equal(r.body.knobs.max_tickets, 3);
    // K-1..K-3 were kept: K-4's claimed row and K-7's edge are outside them.
    assert.deepEqual(r.body.queue.map((x) => x.ticket_key).sort(), ['K-2', 'K-3']);
    assert.deepEqual(r.body.edges, []);
    assert.deepEqual(r.body.triage.map((x) => x.ticket_key), ['K-1']);
  });
});
