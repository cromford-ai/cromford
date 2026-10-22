// BH-7801 (slice C1 of #4157): GET /api/br-attempts reads `ledgers` only on
// its PRIMARY KEY (kind, key). Seeds 50,000 ledger rows over 20 kinds (5,000
// br_attempt over 200 records), drives the REAL GET through worker.fetch with
// a recorder on DB.prepare, and runs EXPLAIN QUERY PLAN on the statement it
// ran, with the binds it ran with. A plan line that SCANs ledgers fails it.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7801-idx';

function rec(DB, log) {
  return {
    prepare(sql) {
      const s = DB.prepare(sql);
      const bind = s.bind.bind(s);
      s.bind = (...v) => { log.push({ sql, binds: v }); return bind(...v); };
      return s;
    },
    batch: (stmts) => DB.batch(stmts),
  };
}

test('BH-7801 the br-attempts read uses the ledgers primary key at 50,000 rows', async (t) => {
  const h = await openDb();
  if (h === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const { db, DB } = h;
  const ins = db.prepare('INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at) VALUES (?,?,?,?,?,?,?)');
  db.exec('BEGIN');
  for (let i = 0; i < 50000; i++) {
    const k = i % 10;
    const kind = k === 0 ? 'br_attempt' : k === 1 ? 'br_record' : `kind-${i % 18}`;
    const key = kind === 'br_attempt' ? `proj${i % 4}/rk${i % 200}#20261021${String(i).padStart(6, '0')}#${String(i).padStart(6, '0')}`
      : kind === 'br_record' ? `proj${i % 4}/rk${i}` : `key-${i}`;
    ins.run(kind, key, 'x', 'box', '{}', '2026-10-21T00:00:00Z', '2026-10-21T00:00:00Z');
  }
  db.exec('COMMIT');
  assert.ok(db.prepare('SELECT COUNT(*) AS n FROM ledgers').get().n >= 50000);
  assert.ok(db.prepare("SELECT COUNT(*) AS n FROM ledgers WHERE kind='br_attempt'").get().n >= 5000);

  const log = [];
  const env = { DB: rec(DB, log), HARNESS_SECRET: SECRET };
  const r = await worker.fetch(new Request('https://jobs.test/api/br-attempts?project=proj0&rkey=rk0', {
    headers: { authorization: `Bearer ${SECRET}` },
  }), env);
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.ok(body.attempts.length > 0, 'the fixture record has rows');

  const reads = log.filter((e) => /^\s*SELECT/i.test(e.sql) && /\bledgers\b/.test(e.sql));
  assert.equal(reads.length, 1, 'the GET ran one ledger read');
  for (const { sql, binds } of reads) {
    const lines = plan(db, sql, ...binds);
    assert.deepEqual(fullScans(lines, ['ledgers']), [], `no full scan: ${sql}\n${lines.join('\n')}`);
    assert.ok(lines.some((l) => /^SEARCH ledgers USING (INDEX sqlite_autoindex_ledgers_1|PRIMARY KEY)/.test(l)),
      `a PK search: ${sql}\n${lines.join('\n')}`);
  }
});
