// BH-9154 (Fix 3 of #9066): the lead_ticket_verdicts table behind
// POST /api/lead-ticket-verdicts and GET /api/lead-ticket-verdicts, driven
// through the REAL worker.fetch on node:sqlite with the composed jobs schema
// (worker/jobs/schema.d/).
//   V1  POST then GET round-trips one row; the key is normalized once
//       (repo lower case, ticket key upper case) at write and at read
//   V2  a second POST on the same key replaces the word (a later BLOCK wins)
//   V3  the window: a row 86399 s old is answered, 86401 s old is not
//   V4  a wrong repo, another ticket key or another fp read 0 rows
//   V5  no bearer is 401 on both verbs
//   V6  bad bodies and queries are 400 and write nothing
//   V7  EXPLAIN QUERY PLAN on 5000 rows: the upsert and the GET use the
//       primary key, the retention id read uses idx_lead_ticket_verdicts_created
//   V8  retention rule lead_ticket_verdicts.age: registered, seeded 7 days,
//       counted under dry run, deleted live, one audit row
//   V9  the route-table fragment names both routes
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh9154';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (secs) => new Date(NOW - secs * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const FP = 'v1-' + 'a'.repeat(64);
const FP2 = 'v1-' + 'b'.repeat(64);
const ROW = {
  repo: 'example-org/Demo-OS', ticket_key: 'bh-77', patch_fp: FP, pr: 301,
  head_sha: '1'.repeat(40), verdict: 'MERGE', review_mode: 'full', report_ref: 'logs/r.md', request_id: 'req-1',
};

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, path, { method = 'GET', body, bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const post = (DB, extra = {}, opts = {}) => call(DB, '/api/lead-ticket-verdicts', { method: 'POST', body: { ...ROW, ...extra }, ...opts });
const get = (DB, q = {}, opts = {}) => {
  const p = new URLSearchParams({ repo: 'example-org/demo-os', ticket_key: 'BH-77', patch_fp: FP, window_s: '86400', ...q });
  return call(DB, `/api/lead-ticket-verdicts?${p}`, opts);
};
const seed = (db, r) => db.prepare(
  `INSERT INTO lead_ticket_verdicts (repo, ticket_key, patch_fp, pr, head_sha, verdict, review_mode, report_ref, request_id, created_at)
   VALUES (?,?,?,?,?,?,?,?,?,?)`
).run(r.repo || 'example-org/demo-os', r.ticket_key || 'BH-77', r.patch_fp || FP, r.pr ?? 301, r.head_sha || '1'.repeat(40),
  r.verdict || 'MERGE', r.review_mode || 'full', null, null, r.at || ago(10));

test('V1 POST then GET round-trips the row; repo and ticket key are normalized at write and read', async (t) => {
  const o = await fresh(t); if (!o) return;
  const w = await post(o.DB);
  assert.equal(w.status, 200, JSON.stringify(w.body));
  const row = o.db.prepare('SELECT * FROM lead_ticket_verdicts').all();
  assert.equal(row.length, 1);
  assert.equal(row[0].repo, 'example-org/demo-os');
  assert.equal(row[0].ticket_key, 'BH-77');
  assert.equal(row[0].verdict, 'MERGE');
  const r = await get(o.DB, { repo: 'example-org/demo-os', ticket_key: 'bh-77' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.row.verdict, 'MERGE');
  assert.equal(r.body.row.pr, 301);
  assert.equal(r.body.row.head_sha, '1'.repeat(40));
  assert.equal(r.body.row.review_mode, 'full');
  assert.equal(typeof r.body.row.age_s, 'number');
});

test('V2 a second POST on the same key replaces the word: a later BLOCK wins', async (t) => {
  const o = await fresh(t); if (!o) return;
  await post(o.DB);
  const w = await post(o.DB, { verdict: 'BLOCK', pr: 302, head_sha: '2'.repeat(40) });
  assert.equal(w.status, 200, JSON.stringify(w.body));
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM lead_ticket_verdicts').get().n, 1);
  const r = await get(o.DB);
  assert.equal(r.body.row.verdict, 'BLOCK');
  assert.equal(r.body.row.pr, 302);
});

test('V3 the window: 86399 s old is answered, 86401 s old is not', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { patch_fp: FP, at: ago(86399) });
  seed(o.db, { patch_fp: FP2, at: ago(86401) });
  assert.equal((await get(o.DB, { patch_fp: FP })).body.row.verdict, 'MERGE');
  const old = await get(o.DB, { patch_fp: FP2 });
  assert.equal(old.status, 200);
  assert.equal(old.body.row, null);
});

test('V4 a wrong repo, another ticket key or another fp read 0 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, {});
  for (const q of [{ repo: 'example-org/other-os' }, { ticket_key: 'BH-78' }, { patch_fp: FP2 }]) {
    const r = await get(o.DB, q);
    assert.equal(r.status, 200, JSON.stringify(q));
    assert.equal(r.body.row, null, JSON.stringify(q));
  }
});

test('V5 no bearer is 401 on both verbs', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, {}, { bearer: false })).status, 401);
  assert.equal((await get(o.DB, {}, { bearer: false })).status, 401);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM lead_ticket_verdicts').get().n, 0);
});

test('V6 bad bodies and queries are 400 and write nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const b of [{ verdict: 'APPROVE' }, { verdict: '' }, { patch_fp: '' }, { patch_fp: 'not a fp' }, { ticket_key: 'nokey' },
    { repo: '' }, { head_sha: 'abc' }, { pr: 0 }, { review_mode: 'other' }]) {
    const r = await post(o.DB, b);
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM lead_ticket_verdicts').get().n, 0);
  for (const q of [{ window_s: '0' }, { window_s: 'x' }, { window_s: String(7 * 86400 + 1) }, { patch_fp: '' }, { ticket_key: '' }]) {
    assert.equal((await get(o.DB, q)).status, 400, JSON.stringify(q));
  }
});

test('V7 on 5000 rows the upsert and GET use the primary key, retention uses its index, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    seed(db, { repo: `example-org/p-${i % 20}`, ticket_key: `BH-${i % 900}`, patch_fp: 'v1-' + String(i).padStart(64, '0'), at: ago((i % 10080) * 60) });
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const log = [];
  const R = capturingD1(db, log);
  const D = {
    prepare(sql) {
      const s = R.prepare(sql);
      let binds = [];
      const api = {
        bind(...v) { binds = v; s.bind(...v); return api; },
        first: (c) => s.first(c), all: () => s.all(),
        run() { log.push({ sql, binds }); return s.run(); },
      };
      return api;
    },
    batch: (x) => R.batch(x),
  };
  const fp = 'v1-' + String(777).padStart(64, '0');
  assert.equal((await post(D, { repo: 'example-org/p-17', ticket_key: 'BH-777', patch_fp: fp })).status, 200);
  assert.equal((await get(D, { repo: 'example-org/p-17', ticket_key: 'BH-777', patch_fp: fp })).body.row.verdict, 'MERGE');
  const stmts = log.filter((r) => /lead_ticket_verdicts/.test(r.sql) && !/^\s*CREATE/i.test(r.sql));
  assert.equal(stmts.length, 2, stmts.map((r) => r.sql).join(' | '));
  for (const r of stmts) {
    const lines = plan(db, r.sql, ...r.binds);
    assert.deepEqual(fullScans(lines, ['lead_ticket_verdicts']), [], `${r.sql.slice(0, 80)}: ${lines.join(' | ')}`);
    if (/^\s*SELECT/i.test(r.sql)) {
      assert.ok(lines.some((l) => /USING (COVERING )?INDEX sqlite_autoindex_lead_ticket_verdicts_1|USING PRIMARY KEY/.test(l)), lines.join(' | '));
    }
  }
  const { RULES } = await import('../src/routes/retention.js');
  const rule = RULES.find((x) => x.rule === 'lead_ticket_verdicts.age');
  assert.ok(rule, 'the retention rule exists');
  const lines = plan(db, rule.ids, ago(7 * 86400), 500);
  assert.deepEqual(fullScans(lines, ['lead_ticket_verdicts']), [], lines.join(' | '));
  assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_lead_ticket_verdicts_created \(created_at<\?\)/.test(l)), lines.join(' | '));
});

test('V8 retention lead_ticket_verdicts.age: seeded 7 days, counted under dry run, deleted live, one audit row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { RULES } = await import('../src/routes/retention.js');
  const rule = RULES.find((x) => x.rule === 'lead_ticket_verdicts.age');
  assert.ok(rule, `the rule is registered: ${RULES.map((r) => r.rule).join(',')}`);
  assert.equal(rule.table, 'lead_ticket_verdicts');
  assert.equal(rule.key, 'retention.lead_ticket_verdicts.days');
  assert.equal(rule.def, 7);
  assert.equal(o.db.prepare("SELECT value FROM settings WHERE key='retention.lead_ticket_verdicts.days'").get().value, '7');
  seed(o.db, { patch_fp: FP, at: ago(8 * 86400) });
  seed(o.db, { patch_fp: FP2, at: ago(6 * 86400) });
  const run = (body) => call(o.DB, '/api/retention/run', { method: 'POST', body });
  const fps = () => o.db.prepare('SELECT patch_fp FROM lead_ticket_verdicts ORDER BY patch_fp').all().map((r) => r.patch_fp);
  const dry = await run({ dry_run: true });
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  const dr = dry.body.rules.find((r) => r.rule === 'lead_ticket_verdicts.age');
  assert.equal(dr.counted, 1);
  assert.equal(dr.removed, 0);
  assert.deepEqual(fps(), [FP, FP2]);
  o.db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('retention.dry_run','0','',?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run('test', ago(0));
  const audits = () => o.db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule='lead_ticket_verdicts.age'").get().n;
  const before = audits();
  const live = await run({});
  assert.equal(live.status, 200, JSON.stringify(live.body));
  assert.equal(live.body.rules.find((r) => r.rule === 'lead_ticket_verdicts.age').removed, 1);
  assert.deepEqual(fps(), [FP2]);
  assert.equal(audits() - before, 1);
});

test('V9 the route-table fragment names both routes', () => {
  const frag = readFileSync(new URL('./route-table.d/bh-9154-lead-ticket-verdicts.txt', import.meta.url), 'utf8')
    .split('\n').filter((l) => l && !l.startsWith('#'));
  assert.deepEqual(frag, ['POST /api/lead-ticket-verdicts', 'GET /api/lead-ticket-verdicts']);
});
