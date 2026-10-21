// BH-4157 (slice C0): the ironlaw-accept routes read `ledgers` only on its
// PRIMARY KEY (kind, key). Seeds 50,000 ledger rows over 20 kinds (2,000
// ironlaw-head-accept, 2,000 mc-merge-verdict), drives the REAL GET and POST
// through worker.fetch with a recorder on DB.prepare, and runs EXPLAIN QUERY
// PLAN on every statement the routes ran, with the binds they ran with. A
// plan line that SCANs ledgers with no index fails it.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh4157-idx';
const HEAD = 'c'.repeat(40);

// rec(DB, log) — the same D1, plus {sql, binds} for every bound statement.
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

test('BH-4157 the ironlaw-accept reads use the ledgers primary key at 50,000 rows', async (t) => {
  const h = await openDb();
  if (h === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const { db, DB } = h;
  const ins = db.prepare('INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at) VALUES (?,?,?,?,?,?,?)');
  db.exec('BEGIN');
  for (let i = 0; i < 50000; i++) {
    const k = i % 25;
    const kind = k < 2 ? 'ironlaw-head-accept' : k < 4 ? 'mc-merge-verdict' : `kind-${k % 20}`;
    const key = kind === 'ironlaw-head-accept' ? `x/r${i % 40}#${i}@${String(i).padStart(40, '0')}`
      : kind === 'mc-merge-verdict' ? `x/r${i % 40}#${i}` : `key-${i}`;
    ins.run(kind, key, 'x', 'box', '{}', '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z');
  }
  db.exec('COMMIT');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM ledgers').get().n >= 50000, true);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM ledgers WHERE kind='ironlaw-head-accept'").get().n >= 2000, true);

  const log = [];
  const env = { DB: rec(DB, log), HARNESS_SECRET: SECRET };
  const go = (method, path, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), env);
  db.prepare('INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at) VALUES (?,?,?,?,?,?,?)')
    .run('mc-merge-verdict', 'o/r7#7', 'hold', 'box', `${HEAD} iron-law: 1 hit(s) on this head: a.js (window.confirm()`, '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z');
  let r = await go('GET', '/api/ironlaw-accept?repo=o%2Fr7&pr=7');
  assert.equal(r.status, 200);
  r = await go('POST', '/api/ironlaw-accept', { repo: 'o/r7', pr: 7, head: HEAD, reason: 'fixture', actor: 'ops@x' });
  assert.equal(r.status, 200);

  const reads = log.filter((e) => /^\s*SELECT/i.test(e.sql) && /\bledgers\b/.test(e.sql));
  assert.ok(reads.length >= 3, `the GET and the POST ran their ledger reads (${reads.length})`);
  for (const { sql, binds } of reads) {
    const lines = plan(db, sql, ...binds);
    assert.deepEqual(fullScans(lines, ['ledgers']), [], `no full scan: ${sql}\n${lines.join('\n')}`);
    assert.ok(lines.some((l) => /^SEARCH ledgers USING (INDEX sqlite_autoindex_ledgers_1|PRIMARY KEY)/.test(l)),
      `a PK search: ${sql}\n${lines.join('\n')}`);
  }
});
